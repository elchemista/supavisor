defmodule SupavisorWeb.AdminMCPLiveTest do
  use SupavisorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Supavisor.MCP.Auth
  alias SupavisorWeb.{AdminAccessCache, AdminAuth}

  setup %{conn: conn} do
    previous = Application.get_env(:supavisor, Auth)

    Application.put_env(:supavisor, Auth, allowed_origins: [])

    AdminAccessCache.invalidate()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:supavisor, Auth, previous),
        else: Application.delete_env(:supavisor, Auth)

      AdminAccessCache.invalidate()
    end)

    conn = conn |> init_test_session(%{}) |> AdminAuth.log_in_admin("admin@example.com")
    {:ok, conn: conn}
  end

  test "MCP settings require an authenticated administrator" do
    conn = get(local_conn(), "/admin/mcp")
    assert redirected_to(conn) == "/admin/login"
  end

  test "MCP is always active and its endpoint follows the page origin", %{
    conn: conn
  } do
    config = Application.fetch_env!(:supavisor, Auth)
    Application.put_env(:supavisor, Auth, Keyword.put(config, :enabled, false))
    {:ok, view, html} = live(conn, "http://localhost:4002/admin/mcp")

    refute html =~ "MCP is disabled"
    refute html =~ "MCP_ENABLED"
    refute html =~ "MCP_BASE_URL"
    assert html =~ "No authorized connections yet."
    assert has_element?(view, "#mcp-endpoint", "http://localhost:4002/mcp")
    assert has_element?(view, "nav.sidebar-navigation a[href='/admin/mcp']", "MCP")
    assert has_element?(view, "nav.sidebar-navigation a[href='/admin/postgres']", "PostgreSQL")

    for path <- ~w(mailer embedding stt tts ai-model api) do
      refute has_element?(view, "nav.sidebar-navigation a[href='/admin/#{path}']")
    end
  end

  test "the hosted settings page uses its own domain without a configured MCP URL", %{conn: conn} do
    Application.put_env(:supavisor, Auth, enabled: false, base_url: "http://localhost:4000")
    {:ok, view, html} = live(conn, "https://admin.sendvia.chat/admin/mcp")
    assert has_element?(view, "#mcp-endpoint", "https://admin.sendvia.chat/mcp")
    refute html =~ "http://localhost:4000/mcp"
    refute html =~ "MCP is disabled"
  end

  test "authorized connections display permissions and database selections without any token material",
       %{conn: conn} do
    {tokens, grant} =
      grant_fixture("Claude connection", "admin@example.com", ["application_database"])

    {:ok, view, html} = live(conn, "http://localhost:4002/admin/mcp")

    assert has_element?(view, "#mcp-grant-#{grant.id}", "Claude connection")
    assert html =~ "application_database"
    assert html =~ "db:read"

    for secret <- [
          tokens.access_token,
          tokens.refresh_token,
          grant.access_hash,
          grant.refresh_hash
        ] do
      refute html =~ secret
    end
  end

  test "revoking a connection removes it from the page and immediately rejects its access token",
       %{conn: conn} do
    {tokens, grant} = grant_fixture("Connection to revoke", "admin@example.com", [])
    {:ok, view, _} = live(conn, "http://localhost:4002/admin/mcp")

    view
    |> element("#mcp-grant-#{grant.id} button[phx-click='revoke']")
    |> render_click()

    refute has_element?(view, "#mcp-grant-#{grant.id}")
    assert render(view) =~ "Connection revoked"
    assert {:error, :invalid_token} = Auth.authorize(tokens.access_token)
  end

  test "administrators can see and revoke only their own grants", %{conn: conn} do
    {_own_tokens, own_grant} = grant_fixture("Own connection", "admin@example.com", [])

    {other_tokens, other_grant} =
      grant_fixture("Other administrator connection", "admin@localhost", [])

    {:ok, view, html} = live(conn, "http://localhost:4002/admin/mcp")

    assert has_element?(view, "#mcp-grant-#{own_grant.id}")
    refute has_element?(view, "#mcp-grant-#{other_grant.id}")
    refute html =~ "Other administrator connection"

    render_hook(view, "revoke", %{"id" => other_grant.id})
    assert {:ok, _} = Auth.authorize(other_tokens.access_token)
  end

  defp grant_fixture(name, email, tenant_ids) do
    {:ok, client} =
      Auth.register(%{
        "client_name" => name,
        "redirect_uris" => ["https://client.example/callback"]
      })

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    request = %{
      "client_id" => client.client_id,
      "redirect_uri" => "https://client.example/callback",
      "response_type" => "code",
      "code_challenge_method" => "S256",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
      "scope" => "db:read",
      "resource" => Auth.resource()
    }

    {:ok, code} = Auth.issue_code(request, email, ["db:read"], tenant_ids)

    {:ok, tokens} =
      Auth.exchange(%{
        "client_id" => client.client_id,
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier,
        "redirect_uri" => "https://client.example/callback",
        "resource" => Auth.resource()
      })

    {:ok, grant} = Auth.authorize(tokens.access_token)
    {tokens, grant}
  end

  defp local_conn, do: %{build_conn() | host: "localhost", port: 4002}
end
