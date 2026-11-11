defmodule SupavisorWeb.OAuthControllerTest do
  use SupavisorWeb.ConnCase, async: false

  alias Supavisor.MCP.Auth
  alias Supavisor.Repo
  alias SupavisorWeb.{AdminAccessCache, AdminAuth, AdminCredential, AdminSettings}

  setup do
    original = Application.get_env(:supavisor, Auth)
    admin_original = Application.get_env(:supavisor, AdminAuth)
    Application.put_env(:supavisor, Auth, allowed_origins: [])

    Application.put_env(:supavisor, AdminAuth,
      admin_emails: ["admin@example.com"],
      session_ttl_seconds: 28_800,
      base_url: "http://localhost:4002"
    )

    Repo.delete_all(AdminSettings)
    Repo.delete_all(AdminCredential)
    AdminAccessCache.invalidate()

    on_exit(fn ->
      if original,
        do: Application.put_env(:supavisor, Auth, original),
        else: Application.delete_env(:supavisor, Auth)

      Application.put_env(:supavisor, AdminAuth, admin_original)
      AdminAccessCache.invalidate()
    end)

    {:ok, registration} =
      Auth.register(%{
        "client_name" => "Example MCP application",
        "redirect_uris" => ["https://client.example/callback"]
      })

    request = %{
      "client_id" => registration.client_id,
      "redirect_uri" => "https://client.example/callback",
      "response_type" => "code",
      "code_challenge_method" => "S256",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier()), padding: false),
      "resource" => Auth.resource(),
      "scope" => "db:read db:create db:migrate",
      "state" => "client-state"
    }

    {:ok, request: request}
  end

  test "discovery advertises the protected resource, PKCE and OAuth endpoints", %{conn: conn} do
    metadata =
      conn
      |> get("http://localhost:4002/.well-known/oauth-authorization-server")
      |> json_response(200)

    assert metadata["code_challenge_methods_supported"] == ["S256"]
    assert metadata["authorization_endpoint"] == "http://localhost:4002/oauth/authorize"
    assert "refresh_token" in metadata["grant_types_supported"]

    metadata =
      conn
      |> get("http://localhost:4002/.well-known/oauth-protected-resource/mcp")
      |> json_response(200)

    assert metadata["resource"] == Auth.resource()
    assert metadata["authorization_servers"] == [Auth.base_url()]
  end

  test "every discovery document derives the hosted origin without MCP configuration", %{
    conn: conn
  } do
    Application.put_env(:supavisor, Auth, enabled: false, base_url: "https://obsolete.example")
    origin = "https://admin.sendvia.chat"

    metadata =
      conn |> get(origin <> "/.well-known/oauth-authorization-server") |> json_response(200)

    assert metadata["issuer"] == origin

    for {key, path} <- [
          {"authorization_endpoint", "/oauth/authorize"},
          {"token_endpoint", "/oauth/token"},
          {"registration_endpoint", "/oauth/register"},
          {"revocation_endpoint", "/oauth/revoke"}
        ] do
      assert metadata[key] == origin <> path
    end

    for path <- [
          "/.well-known/oauth-protected-resource",
          "/.well-known/oauth-protected-resource/mcp"
        ] do
      resource = local_conn() |> get(origin <> path) |> json_response(200)
      assert resource["resource"] == origin <> "/mcp"
      assert resource["authorization_servers"] == [origin]
      refute JSON.encode!(resource) =~ "localhost"
      refute JSON.encode!(resource) =~ "obsolete.example"
    end
  end

  test "the hosted origin completes consent, token exchange and MCP access without leaking access to another origin",
       %{conn: conn, request: request} do
    origin = "https://admin.sendvia.chat"
    resource = origin <> "/mcp"
    request = Map.put(request, "resource", resource)

    rejected = conn |> sign_in() |> get("https://another.example/oauth/authorize", request)
    assert json_response(rejected, 400) == %{"error" => "invalid_request"}

    consent_conn = local_conn() |> sign_in() |> get(origin <> "/oauth/authorize", request)

    params =
      consent_params(html_response(consent_conn, 200))
      |> Map.merge(%{"decision" => "approve", "scopes" => ["db:read"]})

    approved = consent_conn |> recycle() |> post(origin <> "/oauth/authorize", params)

    callback =
      approved |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    exchange = %{
      "grant_type" => "authorization_code",
      "client_id" => request["client_id"],
      "redirect_uri" => request["redirect_uri"],
      "resource" => resource,
      "code" => callback["code"],
      "code_verifier" => verifier()
    }

    wrong_origin =
      local_conn() |> post("https://another.example/oauth/token", exchange) |> json_response(400)

    assert wrong_origin == %{"error" => "invalid_grant"}
    tokens = local_conn() |> post(origin <> "/oauth/token", exchange) |> json_response(200)
    assert {:ok, grant} = Auth.authorize(tokens["access_token"], resource)
    assert grant.resource == resource

    authorized_conn =
      local_conn()
      |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
      |> put_req_header("content-type", "application/json")

    body = JSON.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"})
    assert json_response(post(authorized_conn, origin <> "/mcp", body), 200)["result"] == %{}

    assert json_response(post(authorized_conn, "https://another.example/mcp", body), 401)["error"] ==
             "invalid_token"

    refresh = %{
      "grant_type" => "refresh_token",
      "client_id" => request["client_id"],
      "resource" => resource,
      "refresh_token" => tokens["refresh_token"]
    }

    assert json_response(post(local_conn(), "https://another.example/oauth/token", refresh), 400) ==
             %{"error" => "invalid_grant"}

    assert {:ok, _} = Auth.authorize(tokens["access_token"], resource)
  end

  test "registration returns a public client and enforces redirect safety", %{conn: conn} do
    response =
      conn
      |> post("http://localhost:4002/oauth/register", %{
        "client_name" => "Client",
        "redirect_uris" => ["https://client.example/cb"]
      })
      |> json_response(201)

    assert response["token_endpoint_auth_method"] == "none"
    refute response["client_secret"]

    assert %{"error" => "invalid_client_metadata"} =
             conn
             |> post("http://localhost:4002/oauth/register", %{
               "redirect_uris" => ["http://remote.example/cb"]
             })
             |> json_response(400)
  end

  test "unauthenticated authorization preserves a validated login return", %{
    conn: conn,
    request: request
  } do
    conn = get(conn, "http://localhost:4002/oauth/authorize", request)
    assert redirected_to(conn) == "/admin/login"
    assert String.starts_with?(get_session(conn, :admin_return_to), "/oauth/authorize?")
    assert get_session(conn, :admin_return_to) =~ "client_id="
    invalid = Map.put(request, "redirect_uri", "https://attacker.example/cb")

    assert %{"error" => "invalid_request"} =
             local_conn()
             |> get("http://localhost:4002/oauth/authorize", invalid)
             |> json_response(400)
  end

  test "consent defaults to reading and requires explicit approval before token creation", %{
    conn: conn,
    request: request
  } do
    consent_conn = conn |> sign_in() |> get("http://localhost:4002/oauth/authorize", request)
    body = html_response(consent_conn, 200)
    assert body =~ "Example MCP application"
    assert body =~ ~s(value="db:read" checked)
    refute body =~ ~s(value="db:create" checked)
    refute body =~ ~s(value="db:migrate" checked)
    refute body =~ ~s(name="all_databases" value="true" checked)

    params =
      consent_params(body) |> Map.merge(%{"decision" => "approve", "scopes" => ["db:read"]})

    approved = consent_conn |> recycle() |> post("http://localhost:4002/oauth/authorize", params)
    uri = URI.parse(redirected_to(approved))
    assert uri.host == "client.example"
    response = URI.decode_query(uri.query)
    assert response["state"] == "client-state"
    assert is_binary(response["code"])

    token_conn =
      local_conn()
      |> post("http://localhost:4002/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => request["client_id"],
        "redirect_uri" => request["redirect_uri"],
        "resource" => Auth.resource(),
        "code" => response["code"],
        "code_verifier" => verifier()
      })

    tokens = json_response(token_conn, 200)
    assert get_resp_header(token_conn, "cache-control") == ["no-store"]
    assert {:ok, grant} = Auth.authorize(tokens["access_token"])
    assert grant.scopes == ["db:read"]
    assert grant.tenant_ids == []
    replay = consent_conn |> recycle() |> post("http://localhost:4002/oauth/authorize", params)
    assert json_response(replay, 400) == %{"error" => "invalid_request"}
  end

  test "denial returns state without issuing a code", %{conn: conn, request: request} do
    conn = conn |> sign_in() |> get("http://localhost:4002/oauth/authorize", request)
    params = consent_params(html_response(conn, 200)) |> Map.put("decision", "deny")
    result = conn |> recycle() |> post("http://localhost:4002/oauth/authorize", params)

    response =
      result |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert response == %{"error" => "access_denied", "state" => "client-state"}
  end

  test "forged consent cannot add scopes beyond the authorization request", %{
    conn: conn,
    request: request
  } do
    conn =
      conn
      |> sign_in()
      |> get("http://localhost:4002/oauth/authorize", Map.put(request, "scope", "db:read"))

    params =
      consent_params(html_response(conn, 200))
      |> Map.merge(%{"decision" => "approve", "scopes" => ["db:migrate"]})

    assert %{"error" => "invalid_request"} =
             conn
             |> recycle()
             |> post("http://localhost:4002/oauth/authorize", params)
             |> json_response(400)
  end

  test "a tenant named star cannot silently grant every database", %{conn: conn, request: request} do
    Repo.insert!(%Supavisor.Tenants.Tenant{
      external_id: "*",
      db_host: "localhost",
      db_port: 6432,
      db_database: "legacy_star",
      require_user: true,
      default_parameter_status: %{}
    })

    conn = conn |> sign_in() |> get("http://localhost:4002/oauth/authorize", request)
    body = html_response(conn, 200)
    refute body =~ ~s(name="tenant_ids[]" value="*")

    params =
      consent_params(body)
      |> Map.merge(%{"decision" => "approve", "scopes" => ["db:read"], "tenant_ids" => ["*"]})

    assert %{"error" => "invalid_request"} =
             conn
             |> recycle()
             |> post("http://localhost:4002/oauth/authorize", params)
             |> json_response(400)
  end

  test "approval is protected against CSRF", %{conn: conn, request: request} do
    conn = conn |> sign_in() |> get("http://localhost:4002/oauth/authorize", request)

    params =
      consent_params(html_response(conn, 200))
      |> Map.delete("_csrf_token")
      |> Map.merge(%{"decision" => "approve", "scopes" => ["db:read"]})

    assert_error_sent(403, fn ->
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("http://localhost:4002/oauth/authorize", params)
    end)
  end

  test "OAuth discovery remains available without enabling flags or a configured base URL", %{
    conn: conn
  } do
    Application.put_env(:supavisor, Auth, enabled: false, base_url: "https://obsolete.example")

    metadata =
      conn
      |> get("http://localhost:4002/.well-known/oauth-authorization-server")
      |> json_response(200)

    assert metadata["issuer"] == "http://localhost:4002"
    conn = local_conn() |> SupavisorWeb.MCPOrigin.call([]) |> SupavisorWeb.MCPAuth.call([])
    assert conn.status == 401
    assert conn.halted
  end

  test "missing bearer token includes resource discovery challenge" do
    conn = local_conn() |> SupavisorWeb.MCPOrigin.call([]) |> SupavisorWeb.MCPAuth.call([])
    assert conn.status == 401
    assert [header] = get_resp_header(conn, "www-authenticate")

    assert header =~
             ~s(resource_metadata="http://localhost:4002/.well-known/oauth-protected-resource/mcp")
  end

  defp verifier, do: String.duplicate("a", 43)

  defp sign_in(conn),
    do: conn |> init_test_session(%{}) |> AdminAuth.log_in_admin("admin@example.com")

  defp consent_params(body) do
    [_, consent] = Regex.run(~r/name="consent" value="([^"]+)"/, body)
    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, body)
    %{"consent" => consent, "_csrf_token" => csrf}
  end

  defp local_conn, do: %{build_conn() | host: "localhost", port: 4002}
end
