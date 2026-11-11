defmodule SupavisorWeb.AdminAuthTest do
  use SupavisorWeb.ConnCase, async: false

  alias SupavisorWeb.{AdminAccessCache, AdminAuth, AdminCredential, AdminSettings}

  setup do
    original_config = Application.fetch_env!(:supavisor, AdminAuth)

    Application.put_env(:supavisor, AdminAuth,
      admin_emails: ["admin@example.com"],
      session_ttl_seconds: 28_800,
      base_url: "http://localhost:4002"
    )

    Supavisor.Repo.delete_all(AdminSettings)
    Supavisor.Repo.delete_all(AdminCredential)
    AdminAccessCache.invalidate()

    on_exit(fn ->
      Application.put_env(:supavisor, AdminAuth, original_config)
      AdminAccessCache.invalidate()
    end)

    :ok
  end

  test "allowed administrator identities are normalized" do
    assert AdminAuth.admin_email?(" Admin@Example.com ")
    refute AdminAuth.admin_email?("other@example.com")
  end

  test "authenticated sessions retain the credential version", %{conn: conn} do
    {:ok, version} =
      AdminCredential.save_password("admin@example.com", %{
        "new_password" => "a strong test password",
        "password_confirmation" => "a strong test password"
      })

    conn = conn |> init_test_session(%{}) |> AdminAuth.log_in_admin(" Admin@Example.com ")

    assert get_session(conn, "admin_session_version") == version
    assert {:ok, "admin@example.com"} = AdminAuth.authenticate_session(get_session(conn))
  end

  test "password changes invalidate existing sessions", %{conn: conn} do
    {:ok, _} =
      AdminCredential.save_password("admin@example.com", %{
        "new_password" => "a strong test password",
        "password_confirmation" => "a strong test password"
      })

    session =
      conn
      |> init_test_session(%{})
      |> AdminAuth.log_in_admin("admin@example.com")
      |> get_session()

    assert {:ok, "admin@example.com"} = AdminAuth.authenticate_session(session)

    {:ok, _} =
      AdminCredential.save_password("admin@example.com", %{
        "current_password" => "a strong test password",
        "new_password" => "another strong test password",
        "password_confirmation" => "another strong test password"
      })

    assert :error = AdminAuth.authenticate_session(session)
  end

  test "removed administrators cannot reuse an existing session", %{conn: conn} do
    session =
      conn
      |> init_test_session(%{})
      |> AdminAuth.log_in_admin("admin@example.com")
      |> get_session()

    Application.put_env(
      :supavisor,
      AdminAuth,
      Keyword.put(Application.fetch_env!(:supavisor, AdminAuth), :admin_emails, [])
    )

    AdminAccessCache.invalidate()
    assert :error = AdminAuth.authenticate_session(session)
  end

  test "admin session expires after configured ttl", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        "admin_email" => "admin@example.com",
        "admin_authenticated_at" => System.system_time(:second) - 28_801
      })
      |> get("/admin")

    assert redirected_to(conn) == "/admin/login"
  end

  test "login page offers passwords without mail links", %{conn: conn} do
    html = conn |> get("/admin/login") |> html_response(200)
    assert html =~ "current-password"
    assert html =~ "supavisor-admin-password"
    refute html =~ "magic_link"
    refute html =~ "Send sign-in link"
  end

  test "login resumes an OAuth authorization request once", %{conn: conn} do
    return_to = "/oauth/authorize?client_id=test&state=state"

    conn =
      conn
      |> init_test_session(%{"admin_return_to" => return_to})
      |> AdminAuth.redirect_after_login()

    assert redirected_to(conn) == return_to
    refute get_session(conn, :admin_return_to)
  end

  test "login ignores external or unrelated return URLs", %{conn: conn} do
    for return_to <- [
          "https://example.com/oauth/authorize?client_id=test",
          "//example.com/oauth/authorize?client_id=test",
          "/oauth/authorize/../other",
          "/admin/postgres",
          "/oauth/authorize?bad=\\example.com"
        ] do
      conn =
        conn
        |> init_test_session(%{"admin_return_to" => return_to})
        |> AdminAuth.redirect_after_login()

      assert redirected_to(conn) == "/admin"
      refute get_session(conn, :admin_return_to)
    end
  end
end
