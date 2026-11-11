defmodule SupavisorWeb.MCPControllerTest do
  use SupavisorWeb.ConnCase, async: false

  import Supavisor.TenantsFixtures
  alias Supavisor.MCP.Auth
  alias SupavisorWeb.AdminAccessCache

  setup do
    previous = Application.get_env(:supavisor, Auth)

    Application.put_env(:supavisor, Auth, allowed_origins: [])

    AdminAccessCache.invalidate()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:supavisor, Auth, previous),
        else: Application.delete_env(:supavisor, Auth)

      AdminAccessCache.invalidate()
    end)

    :ok
  end

  test "MCP remains available without enabling flags or a configured base URL" do
    Application.put_env(:supavisor, Auth, enabled: false, base_url: "https://obsolete.example")
    response = local_conn() |> post("http://localhost:4002/mcp", %{})
    assert json_response(response, 401)["error"] == "invalid_token"
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ "http://localhost:4002/.well-known/oauth-protected-resource/mcp"
  end

  test "hosted bearer challenges derive the public domain and scheme from the request" do
    response =
      local_conn()
      |> post("https://admin.sendvia.chat/mcp", %{})

    assert json_response(response, 401)["error"] == "invalid_token"
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ "https://admin.sendvia.chat/.well-known/oauth-protected-resource/mcp"
    refute challenge =~ "localhost"
  end

  test "a loopback reverse proxy can forward the public HTTPS scheme without MCP URL config" do
    for forwarded_port <- [nil, "443"] do
      conn = local_conn() |> put_req_header("x-forwarded-proto", "https")

      conn =
        if forwarded_port,
          do: put_req_header(conn, "x-forwarded-port", forwarded_port),
          else: conn

      response = post(conn, "http://admin.sendvia.chat:4000/mcp", %{})

      assert json_response(response, 401)["error"] == "invalid_token"
      assert [challenge] = get_resp_header(response, "www-authenticate")
      assert challenge =~ ~s(scope="db:read db:create db:migrate")
      assert challenge =~ "https://admin.sendvia.chat/.well-known/oauth-protected-resource/mcp"
      refute challenge =~ ":4000"
    end
  end

  test "an untrusted remote client cannot forge forwarded HTTPS on an insecure request" do
    conn = %{local_conn() | remote_ip: {203, 0, 113, 12}}

    response =
      conn
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-port", "443")
      |> post("http://admin.sendvia.chat/mcp", %{})

    assert json_response(response, 400) == %{"error" => "invalid_origin"}
    assert get_resp_header(response, "www-authenticate") == []
  end

  test "missing and invalid bearer credentials advertise protected resource discovery" do
    for conn <- [local_conn(), put_req_header(local_conn(), "authorization", "Bearer invalid")] do
      response = post(conn, "http://localhost:4002/mcp", %{})
      assert json_response(response, 401)["error"] == "invalid_token"
      assert [challenge] = get_resp_header(response, "www-authenticate")
      assert challenge =~ "http://localhost:4002/.well-known/oauth-protected-resource/mcp"
    end
  end

  test "a token revoked by its administrator stops authenticating" do
    {conn, token} = authorized()
    {:ok, grant} = Auth.authorize(token)
    assert :ok = Auth.revoke_grant(grant.id, "admin@example.com")
    assert json_response(rpc(conn, "ping"), 401)["error"] == "invalid_token"
  end

  test "initialization negotiates a version and advertises only implemented capabilities" do
    {conn, _} = authorized()

    result =
      conn
      |> rpc("initialize", %{"protocolVersion" => "2025-06-18"}, "init-1")
      |> json_response(200)

    assert result["id"] == "init-1"
    assert result["result"]["protocolVersion"] == "2025-06-18"
    assert result["result"]["serverInfo"]["name"] == "supavisor-database"
    assert result["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
  end

  test "initialization offers the current version when a client requests another version" do
    {conn, _} = authorized()

    result =
      conn
      |> rpc("initialize", %{"protocolVersion" => "1900-01-01"})
      |> json_response(200)

    assert result["result"]["protocolVersion"] == "2025-11-25"
  end

  test "unsupported protocol headers are rejected before dispatch" do
    {conn, _} = authorized()
    conn = put_req_header(conn, "mcp-protocol-version", "1900-01-01")
    assert json_response(rpc(conn, "ping"), 400)["error"] == "Unsupported MCP protocol version"
  end

  test "tools/list exposes only tools authorized by the granted scopes" do
    {conn, _} = authorized(["db:read"])
    result = conn |> rpc("tools/list") |> json_response(200)
    names = Enum.map(result["result"]["tools"], & &1["name"])

    assert Enum.sort(names) ==
             Enum.sort(["list_databases", "describe_database", "read_query", "migration_history"])

    refute "create_database" in names
    refute "apply_migration" in names
  end

  test "calling a write tool requires its scope even when the client knows its name" do
    {conn, _} = authorized(["db:read"])

    result =
      conn
      |> rpc("tools/call", %{
        "name" => "apply_migration",
        "arguments" => %{
          "tenant_id" => "unauthorized",
          "name" => "first",
          "statements" => ["SELECT 1"]
        }
      })
      |> json_response(200)

    assert result["result"]["isError"]
    assert result["result"]["structuredContent"]["error"] =~ "db:migrate"
  end

  test "database listing returns only the authorized tenant without credentials" do
    selected = tenant_fixture(%{external_id: "mcp_selected", db_database: "selected_db"})
    tenant_fixture(%{external_id: "mcp_hidden", db_database: "hidden_db"})
    {conn, _} = authorized(["db:read"], [selected.external_id])

    result =
      conn
      |> rpc("tools/call", %{"name" => "list_databases", "arguments" => %{}})
      |> json_response(200)

    assert result["result"]["isError"] == false

    assert result["result"]["structuredContent"] == %{
             "databases" => [%{"tenant_id" => "mcp_selected", "database" => "selected_db"}]
           }

    assert JSON.decode!(hd(result["result"]["content"])["text"]) ==
             result["result"]["structuredContent"]

    refute JSON.encode!(result) =~ "db_password"
    refute JSON.encode!(result) =~ "hidden_db"
  end

  test "database operations reject tenants outside the selected grant" do
    {conn, _} = authorized(["db:read"], ["one_database"])

    result =
      conn
      |> rpc("tools/call", %{
        "name" => "read_query",
        "arguments" => %{"tenant_id" => "another_database", "sql" => "SELECT 1"}
      })
      |> json_response(200)

    assert result["result"]["isError"]
    assert result["result"]["structuredContent"]["error"] =~ "authorized selection"
  end

  test "unknown tools use a JSON-RPC error and invalid tool arguments use a tool error" do
    {conn, _} = authorized()
    unknown = conn |> rpc("tools/call", %{"name" => "delete_database"}) |> json_response(200)
    assert unknown["error"]["code"] == -32602

    {conn, _} = authorized()

    invalid =
      conn
      |> rpc("tools/call", %{"name" => "list_databases", "arguments" => %{"unexpected" => true}})
      |> json_response(200)

    assert invalid["result"]["isError"]
    assert invalid["result"]["structuredContent"]["error"] == "Unknown tool argument."
  end

  test "notifications return 202 without invoking tools" do
    {conn, _} = authorized(["db:create"])

    response =
      json_post(conn, %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "create_database", "arguments" => %{}}
      })

    assert response(response, 202) == ""
  end

  test "malformed JSON-RPC envelopes, request IDs and method parameters are rejected" do
    cases = [
      {%{"method" => "ping", "id" => 1}, -32600},
      {%{"jsonrpc" => "2.0", "method" => "ping", "id" => nil}, -32600},
      {%{"jsonrpc" => "2.0", "method" => "ping", "id" => 1, "params" => []}, -32602}
    ]

    for {body, expected} <- cases do
      {conn, _} = authorized()
      assert json_response(json_post(conn, body), 200)["error"]["code"] == expected
    end
  end

  test "unknown methods return method-not-found and ping has an empty result" do
    {conn, _} = authorized()
    assert json_response(rpc(conn, "unknown/method"), 200)["error"]["code"] == -32601
    {conn, _} = authorized()
    assert json_response(rpc(conn, "ping"), 200)["result"] == %{}
  end

  test "browser origins must match the resource origin or the explicit origin allowlist" do
    {conn, _} = authorized()
    denied = conn |> put_req_header("origin", "https://untrusted.example") |> rpc("ping")
    assert json_response(denied, 403)["error"] == "Origin not allowed"

    for origin <- ["http://localhost:4002", "https://trusted.example"] do
      config = Application.fetch_env!(:supavisor, Auth)

      Application.put_env(
        :supavisor,
        Auth,
        Keyword.put(config, :allowed_origins, ["https://trusted.example"])
      )

      {conn, _} = authorized()
      accepted = conn |> put_req_header("origin", origin) |> rpc("ping")
      assert json_response(accepted, 200)["result"] == %{}
      assert get_resp_header(accepted, "cache-control") == ["no-store"]
    end
  end

  test "unsupported SSE streams and session deletion return 405" do
    for method <- [:get, :delete] do
      {conn, _} = authorized()

      conn =
        if method == :get, do: put_req_header(conn, "accept", "text/event-stream"), else: conn

      response = dispatch(conn, @endpoint, method, "http://localhost:4002/mcp", nil)
      assert response(response, 405) == ""
      assert get_resp_header(response, "allow") == ["POST"]
    end
  end

  test "authenticated requests must use JSON content type" do
    {conn, _} = authorized()

    rejected =
      conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("http://localhost:4002/mcp", "jsonrpc=2.0&method=ping&id=1")

    assert json_response(rejected, 415)["error"] == "Content-Type must be application/json"
  end

  defp json_post(conn, body), do: post(conn, "http://localhost:4002/mcp", JSON.encode!(body))

  defp rpc(conn, method, params \\ %{}, id \\ 1) do
    json_post(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp authorized(scopes \\ ["db:read"], tenant_ids \\ []) do
    {:ok, client} =
      Auth.register(%{
        "client_name" => "Protocol test",
        "redirect_uris" => ["https://client.example/callback"]
      })

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    request = %{
      "client_id" => client.client_id,
      "redirect_uri" => "https://client.example/callback",
      "response_type" => "code",
      "code_challenge_method" => "S256",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
      "scope" => Enum.join(scopes, " "),
      "resource" => Auth.resource()
    }

    {:ok, code} = Auth.issue_code(request, "admin@example.com", scopes, tenant_ids)

    {:ok, tokens} =
      Auth.exchange(%{
        "client_id" => client.client_id,
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier,
        "redirect_uri" => "https://client.example/callback",
        "resource" => Auth.resource()
      })

    conn =
      local_conn()
      |> put_req_header("authorization", "Bearer " <> tokens.access_token)
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {conn, tokens.access_token}
  end

  defp local_conn, do: %{build_conn() | host: "localhost", port: 4002}
end
