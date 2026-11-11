defmodule SupavisorWeb.AdminAccessCacheTest do
  use SupavisorWeb.ConnCase, async: false

  alias Supavisor.Repo
  alias SupavisorWeb.{AdminAccessCache, AdminAuth, AdminCredential}

  setup do
    AdminAccessCache.invalidate()
    on_exit(fn -> AdminAccessCache.invalidate() end)
    :ok
  end

  test "missing credential table returns an unavailable error without crashing the cache" do
    cache = Process.whereis(AdminAccessCache)

    without_credentials_table(fn ->
      assert {:error, :credentials_unavailable} = AdminAccessCache.credential_versions()
      assert Process.alive?(cache)
      assert Process.whereis(AdminAccessCache) == cache
    end)

    assert is_map(AdminAccessCache.credential_versions())
    assert Process.whereis(AdminAccessCache) == cache
  end

  test "a missing credential table cannot turn a nil-version session into an authenticated session" do
    session = %{
      "admin_email" => "admin@example.com",
      "admin_authenticated_at" => System.system_time(:second),
      "admin_session_version" => nil
    }

    without_credentials_table(fn ->
      assert :error = AdminAuth.authenticate_session(session)
    end)
  end

  test "login reports a recoverable service error instead of exposing SQL when migrations are missing" do
    for method <- [:get, :post] do
      without_credentials_table(fn ->
        conn = dispatch(build_conn(), @endpoint, method, "/admin/login", %{})
        body = response(conn, 503)

        refute body =~ "SELECT"
        refute body =~ "Postgrex"
        refute body =~ "admin_credentials"
        refute get_session(conn, "admin_email")
        assert Process.alive?(Process.whereis(AdminAccessCache))
      end)
    end
  end

  test "credentials recover after migrations without restarting the cache" do
    without_credentials_table(fn ->
      assert {:error, :credentials_unavailable} = AdminAccessCache.credential_versions()
    end)

    assert {:ok, version} =
             AdminCredential.save_password("admin@example.com", %{
               "new_password" => "a recovered administrator password",
               "password_confirmation" => "a recovered administrator password"
             })

    assert %{"admin@example.com" => ^version} = AdminAccessCache.credential_versions()
  end

  test "a login cannot store an unavailable version or redirect over its service error" do
    without_credentials_table(fn ->
      conn =
        build_conn()
        |> init_test_session(%{})
        |> AdminAuth.log_in_admin("admin@example.com")
        |> AdminAuth.redirect_after_login()

      assert conn.halted
      assert response(conn, 503)
      refute get_session(conn, "admin_email")
      refute get_session(conn, "admin_session_version")
      assert get_resp_header(conn, "location") == []
    end)
  end

  defp without_credentials_table(fun) do
    # A savepoint gives this test a genuinely unmigrated schema while ensuring
    # PostgreSQL's failed-transaction state is rolled back before later assertions.
    Ecto.Adapters.SQL.query!(Repo, "SAVEPOINT missing_admin_credentials", [],
      sandbox_subtransaction: false
    )

    try do
      Ecto.Adapters.SQL.query!(
        Repo,
        "ALTER TABLE _supavisor.admin_credentials RENAME TO unavailable_admin_credentials",
        []
      )

      AdminAccessCache.invalidate()
      fun.()
    after
      Ecto.Adapters.SQL.query!(Repo, "ROLLBACK TO SAVEPOINT missing_admin_credentials", [],
        sandbox_subtransaction: false
      )

      Ecto.Adapters.SQL.query!(Repo, "RELEASE SAVEPOINT missing_admin_credentials", [],
        sandbox_subtransaction: false
      )

      AdminAccessCache.invalidate()
    end
  end
end
