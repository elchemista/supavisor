defmodule Supavisor.MCP.AuthTest do
  use Supavisor.DataCase, async: false

  alias Supavisor.MCP.{Auth, AuthorizationCode, Client, Grant}
  alias SupavisorWeb.{AdminAccessCache, AdminAuth, AdminCredential, AdminSettings}

  setup do
    original = Application.get_env(:supavisor, Auth)
    admin_original = Application.get_env(:supavisor, AdminAuth)

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

    {:ok, request: authorization_request()}
  end

  test "registration accepts HTTPS and local callbacks and rejects unsafe redirects" do
    assert {:ok, %{client_id: id}} =
             Auth.register(%{
               "client_name" => "Test",
               "redirect_uris" => [
                 "https://client.example/callback",
                 "http://127.0.0.1:1234/callback"
               ]
             })

    assert %Client{auth_method: "none", secret_hash: nil} = Repo.get(Client, id)

    for callback <- [
          "http://remote.example/callback",
          "javascript:alert(1)",
          "https://client.example/callback#fragment",
          "https://user@client.example/cb",
          "https://client.example\r\n/header",
          "http://127.0.0.1:0/callback",
          "http://127.0.0.1:65536/callback"
        ] do
      assert {:error, "invalid_client_metadata"} = Auth.register(%{"redirect_uris" => [callback]})
    end
  end

  test "request origin must use HTTPS except for local development" do
    assert Auth.valid_base_url?("https://db.example.com")
    assert Auth.valid_base_url?("http://localhost:4000")
    assert Auth.base_url("https://admin.sendvia.chat/") == "https://admin.sendvia.chat"

    for url <- [
          "http://db.example.com",
          "https://example.com/mcp",
          "https://example.com?bad=1",
          "https://example.com\r\nBad:header",
          "https://user@example.com"
        ] do
      refute Auth.valid_base_url?(url)
      assert_raise ArgumentError, fn -> Auth.base_url(url) end
    end
  end

  test "MCP is always enabled and its origin never comes from retired MCP settings" do
    Application.put_env(:supavisor, Auth,
      enabled: false,
      base_url: "https://obsolete.example.com"
    )

    assert Auth.enabled?()
    assert Auth.base_url() == String.trim_trailing(SupavisorWeb.Endpoint.url(), "/")
    assert Auth.resource("https://admin.sendvia.chat") == "https://admin.sendvia.chat/mcp"

    assert %{
             issuer: "https://admin.sendvia.chat",
             token_endpoint: "https://admin.sendvia.chat/oauth/token"
           } = Auth.metadata("https://admin.sendvia.chat")

    assert %{
             resource: "https://admin.sendvia.chat/mcp",
             authorization_servers: ["https://admin.sendvia.chat"]
           } = Auth.resource_metadata("https://admin.sendvia.chat")
  end

  test "codes and tokens remain bound to their requesting domain", %{request: request} do
    resource = "https://admin.sendvia.chat/mcp"
    other_resource = "https://other.example.com/mcp"
    request = Map.put(request, "resource", resource)

    assert {:ok, _, _} = Auth.validate_authorization(request, resource)
    assert {:error, "invalid_request"} = Auth.validate_authorization(request, other_resource)

    assert {:error, "invalid_request"} =
             Auth.issue_code(request, "admin@example.com", ["db:read"], [], other_resource)

    assert {:ok, code} =
             Auth.issue_code(request, "admin@example.com", ["db:read"], [], resource)

    params = request |> token_params(code) |> Map.put("resource", resource)
    assert {:error, "invalid_grant"} = Auth.exchange(params, other_resource)

    assert {:error, "invalid_grant"} =
             Auth.exchange(Map.put(params, "resource", other_resource), other_resource)

    assert {:ok, tokens} = Auth.exchange(params, resource)
    assert {:ok, _} = Auth.authorize(tokens.access_token, resource)
    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token, other_resource)

    refresh = %{
      "grant_type" => "refresh_token",
      "client_id" => request["client_id"],
      "refresh_token" => tokens.refresh_token,
      "resource" => other_resource
    }

    assert {:error, "invalid_grant"} = Auth.exchange(refresh, other_resource)

    assert {:ok, refreshed} =
             Auth.exchange(Map.put(refresh, "resource", resource), resource)

    assert {:ok, _} = Auth.authorize(refreshed.access_token, resource)
    assert {:error, :invalid_token} = Auth.authorize(refreshed.access_token, other_resource)
  end

  test "authorization requires S256, an exact registered redirect and correct audience", %{
    request: request
  } do
    assert {:ok, _, _} = Auth.validate_authorization(request)

    for params <- [
          Map.put(request, "code_challenge_method", "plain"),
          Map.put(request, "redirect_uri", "https://client.example/callback/other"),
          Map.put(request, "resource", "https://other.example/mcp"),
          Map.put(request, "scope", "db:read admin"),
          Map.delete(request, "resource")
        ] do
      assert {:error, "invalid_request"} = Auth.validate_authorization(params)
    end
  end

  test "native clients can choose a loopback IP callback port without changing its other components" do
    for host <- ["127.0.0.1", "[::1]"] do
      registered = "http://#{host}/oauth/callback?client=codex"
      actual = "http://#{host}:51873/oauth/callback?client=codex"
      {:ok, client} = Auth.register(%{"redirect_uris" => [registered]})
      request = authorization_request(client.client_id) |> Map.put("redirect_uri", actual)
      assert {:ok, _, _} = Auth.validate_authorization(request)

      for callback <- [
            "http://#{host}:51873/other?client=codex",
            "http://#{host}:51873/oauth/callback?client=other",
            "http://localhost:51873/oauth/callback?client=codex",
            "http://127.0.0.2:51873/oauth/callback?client=codex",
            "https://#{host}:51873/oauth/callback?client=codex",
            "http://user@#{host}:51873/oauth/callback?client=codex",
            "http://#{host}:51873/oauth/callback?client=codex#fragment",
            "http://#{host}:0/oauth/callback?client=codex",
            "http://#{host}:65536/oauth/callback?client=codex"
          ] do
        assert {:error, "invalid_request"} =
                 Auth.validate_authorization(Map.put(request, "redirect_uri", callback))
      end

      assert {:ok, code} = Auth.issue_code(request, "admin@example.com", ["db:read"], [])
      params = token_params(request, code)

      # The selected port becomes part of the code binding; it cannot be changed
      # again at the token endpoint, even to the originally registered URI.
      assert {:error, "invalid_grant"} =
               Auth.exchange(Map.put(params, "redirect_uri", registered))

      assert {:ok, _} = Auth.exchange(params)
    end

    for registered <- [
          "http://localhost/oauth/callback",
          "https://client.example/oauth/callback"
        ] do
      {:ok, client} = Auth.register(%{"redirect_uris" => [registered]})
      changed = URI.parse(registered) |> Map.put(:port, 51873) |> URI.to_string()
      request = authorization_request(client.client_id) |> Map.put("redirect_uri", changed)
      assert {:error, "invalid_request"} = Auth.validate_authorization(request)
    end
  end

  test "codes require PKCE and can be exchanged only once; bearer credentials are hashed", %{
    request: request
  } do
    {:ok, code} = Auth.issue_code(request, "admin@example.com", ["db:read"], ["tenant-a"])
    params = token_params(request, code)

    assert {:error, "invalid_grant"} =
             Auth.exchange(Map.put(params, "code_verifier", String.duplicate("x", 43)))

    assert {:ok, tokens} = Auth.exchange(params)
    assert {:error, "invalid_grant"} = Auth.exchange(params)
    assert {:ok, grant} = Auth.authorize(tokens.access_token)
    assert grant.scopes == ["db:read"]
    assert grant.tenant_ids == ["tenant-a"]
    assert grant.access_hash != tokens.access_token
    assert grant.refresh_hash != tokens.refresh_token
    refute Repo.get(AuthorizationCode, code)
    assert Auth.allowed_tenant?(grant, "tenant-a")
    refute Auth.allowed_tenant?(grant, "tenant-b")
  end

  test "concurrent authorization code exchanges issue only one grant", %{request: request} do
    {:ok, code} = Auth.issue_code(request, "admin@example.com", ["db:read"], [])
    params = token_params(request, code)

    results =
      1..4
      |> Task.async_stream(fn _ -> Auth.exchange(params) end, max_concurrency: 4)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
  end

  test "refresh rotates tokens and cannot escalate scope or change resource", %{request: request} do
    {:ok, tokens} = tokens(request)

    params = %{
      "grant_type" => "refresh_token",
      "client_id" => request["client_id"],
      "refresh_token" => tokens.refresh_token,
      "resource" => Auth.resource()
    }

    assert {:error, "invalid_scope"} = Auth.exchange(Map.put(params, "scope", "db:migrate"))

    assert {:error, "invalid_grant"} =
             Auth.exchange(Map.put(params, "resource", "https://other.example/mcp"))

    assert {:ok, refreshed} = Auth.exchange(params)
    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token)
    assert {:ok, _} = Auth.authorize(refreshed.access_token)
    assert {:error, "invalid_grant"} = Auth.exchange(params)
    assert {:error, :invalid_token} = Auth.authorize(refreshed.access_token)
  end

  test "expired codes, expired access tokens and changed administrator credentials are rejected",
       %{request: request} do
    {:ok, code} = Auth.issue_code(request, "admin@example.com", ["db:read"], [])

    Repo.update_all(AuthorizationCode,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, "invalid_grant"} = Auth.exchange(token_params(request, code))
    {:ok, expired} = tokens(request)
    Repo.update_all(Grant, set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)])
    assert {:error, :invalid_token} = Auth.authorize(expired.access_token)
    {:ok, tokens} = tokens(request)
    assert {:ok, _} = Auth.authorize(tokens.access_token)

    Repo.insert!(%AdminCredential{
      email: "admin@example.com",
      password_hash: "not-used",
      session_version: Ecto.UUID.generate()
    })

    AdminAccessCache.invalidate()
    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token)

    assert {:error, "invalid_grant"} =
             Auth.exchange(%{
               "grant_type" => "refresh_token",
               "client_id" => request["client_id"],
               "refresh_token" => tokens.refresh_token,
               "resource" => Auth.resource()
             })
  end

  test "removed administrators and revoked grants lose access", %{request: request} do
    {:ok, tokens} = tokens(request)
    {:ok, grant} = Auth.authorize(tokens.access_token)
    assert :ok = Auth.revoke_grant(grant.id, "other@example.com")
    assert {:ok, _} = Auth.authorize(tokens.access_token)
    assert :ok = Auth.revoke_grant(grant.id, "admin@example.com")
    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token)
    {:ok, tokens} = tokens(request)

    Application.put_env(:supavisor, AdminAuth,
      admin_emails: [],
      session_ttl_seconds: 28_800,
      base_url: "http://localhost:4002"
    )

    AdminAccessCache.invalidate()
    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token)
  end

  test "token revocation requires its registered client", %{request: request} do
    {:ok, tokens} = tokens(request)
    other = authorization_request()
    assert :ok = Auth.revoke(%{"client_id" => other["client_id"], "token" => tokens.access_token})
    assert {:ok, _} = Auth.authorize(tokens.access_token)

    assert :ok =
             Auth.revoke(%{"client_id" => request["client_id"], "token" => tokens.refresh_token})

    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token)
  end

  test "confidential clients must authenticate with the registered method" do
    {:ok, client} =
      Auth.register(%{
        "redirect_uris" => ["https://client.example/callback"],
        "token_endpoint_auth_method" => "client_secret_post"
      })

    request = authorization_request(client.client_id)
    {:ok, code} = Auth.issue_code(request, "admin@example.com", ["db:read"], [])
    params = token_params(request, code)
    assert {:error, "invalid_client"} = Auth.exchange(params)
    assert {:error, "invalid_client"} = Auth.exchange(Map.put(params, "client_secret", "wrong"))
    assert {:ok, _} = Auth.exchange(Map.put(params, "client_secret", client.client_secret))
  end

  test "consent nonces are bound to their administrator and consumed once" do
    {:ok, nonce} = Auth.create_consent("admin@example.com")
    assert {:error, :invalid_consent} = Auth.consume_consent("other@example.com", nonce)

    results =
      1..4
      |> Task.async_stream(fn _ -> Auth.consume_consent("admin@example.com", nonce) end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert {:error, :invalid_consent} = Auth.consume_consent("admin@example.com", nonce)
  end

  test "refresh families require reauthorization after their bounded rotation lifetime", %{
    request: request
  } do
    {:ok, tokens} = tokens(request)

    Repo.update_all(Grant,
      set: [used_refresh_hashes: List.duplicate(String.duplicate("0", 64), 2_048)]
    )

    assert {:error, "invalid_grant"} =
             Auth.exchange(%{
               "grant_type" => "refresh_token",
               "client_id" => request["client_id"],
               "refresh_token" => tokens.refresh_token,
               "resource" => Auth.resource()
             })

    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token)
  end

  test "new databases extend the grant without losing earlier permissions", %{request: request} do
    {:ok, tokens} = tokens(request)
    {:ok, grant} = Auth.authorize(tokens.access_token)
    assert {:ok, _} = Auth.grant_tenant(grant, "new-db")
    assert {:ok, updated} = Auth.authorize(tokens.access_token)
    assert "new-db" in updated.tenant_ids
    assert updated.scopes == grant.scopes
  end

  defp authorization_request(client_id \\ nil) do
    client_id =
      client_id ||
        elem(Auth.register(%{"redirect_uris" => ["https://client.example/callback"]}), 1).client_id

    %{
      "client_id" => client_id,
      "redirect_uri" => "https://client.example/callback",
      "response_type" => "code",
      "code_challenge_method" => "S256",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier()), padding: false),
      "resource" => Auth.resource(),
      "scope" => "db:read db:create db:migrate",
      "state" => "opaque-client-state"
    }
  end

  defp verifier, do: String.duplicate("a", 43)

  defp token_params(request, code),
    do: %{
      "grant_type" => "authorization_code",
      "client_id" => request["client_id"],
      "redirect_uri" => request["redirect_uri"],
      "resource" => Auth.resource(),
      "code" => code,
      "code_verifier" => verifier()
    }

  defp tokens(request) do
    {:ok, code} = Auth.issue_code(request, "admin@example.com", ["db:read"], [])
    Auth.exchange(token_params(request, code))
  end
end
