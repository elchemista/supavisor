defmodule SupavisorWeb.AdminDashboardLiveTest do
  use SupavisorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Supavisor.TenantsFixtures

  alias Supavisor.Tenants

  setup %{conn: conn} do
    conn =
      init_test_session(conn, %{
        "admin_email" => "admin@example.com",
        "admin_authenticated_at" => System.system_time(:second)
      })

    {:ok, conn: conn}
  end

  test "unauthenticated admin redirects to login" do
    conn = build_conn() |> get(~p"/admin")
    assert redirected_to(conn) == ~p"/admin/login"
  end

  test "authenticated admin can list connection profiles", %{conn: conn} do
    tenant_fixture(%{external_id: "admin_list_tenant"})

    {:ok, view, html} = live(conn, ~p"/admin")

    assert html =~ "Connections"
    assert has_element?(view, "h1", "Connections")
    assert has_element?(view, "nav.sidebar-navigation a[href='/admin']", "Connections")
    assert has_element?(view, "a[href='/admin/tenants/new']", "Connect database")
    assert has_element?(view, "a[href='/admin/provision']", "Create database")

    view |> form("form[phx-change='search']", search: "admin_list_tenant") |> render_change()
    assert has_element?(view, "#tenant-rows tr", "admin_list_tenant")
  end

  test "authenticated admin can render provisioning form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/provision")

    assert html =~ "Create database"
    assert html =~ "Database name"
  end

  test "server overview shows databases and PostgreSQL roles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/postgres")
    render_async(view)
    database = Supavisor.Repo.config()[:database]

    view |> form("form[phx-change='search']", search: database) |> render_change()
    assert has_element?(view, "#postgres-databases tr", database)
    assert has_element?(view, "a[aria-label='Connect #{database}']")

    view |> element("button[phx-value-tab='roles']") |> render_click()
    view |> form("form[phx-change='search']", search: "postgres") |> render_change()
    assert has_element?(view, "#postgres-roles tr", "postgres")
  end

  test "existing database selection uses the configured server", %{conn: conn} do
    database = Supavisor.Repo.config()[:database]

    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/tenants/new?#{%{db_database: database, db_host: "db.internal", db_port: 5440}}"
      )

    render_async(view)

    assert has_element?(
             view,
             "select[name='tenant[db_database]'] option[value='#{database}'][selected]"
           )

    assert has_element?(view, "input[name='tenant[db_host]'][value='localhost']")
    assert has_element?(view, "input[name='tenant[db_port]'][value='6432']")
  end

  test "invalid pool values produce an error without crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/tenants/new")
    render_async(view)
    params = tenant_params("invalid_pool", "stored_users") |> Map.put("default_pool_size", "")
    html = view |> form("#tenant-form", tenant: params) |> render_submit()
    assert html =~ "Enter a number from 1"
    refute Tenants.get_tenant_by_external_id("invalid_pool")
  end

  test "authenticated admin can create stored-user tenant", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/tenants/new")
    render_async(view)

    params = tenant_params("stored_dashboard_tenant", "stored_users")

    view
    |> form("#tenant-form", tenant: params)
    |> render_submit()

    assert has_element?(view, "#tenant-connected")
    assert has_element?(view, "#connected-database-url")

    tenant = Tenants.get_tenant_by_external_id("stored_dashboard_tenant")
    assert tenant.require_user == true
    assert [%{db_user: "postgres"}] = tenant.users
  end

  test "authenticated admin can create auth-query tenant", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/tenants/new")
    render_async(view)

    view |> form("#tenant-form", tenant: %{"auth_mode" => "auth_query"}) |> render_change()

    params =
      "auth_query_dashboard_tenant"
      |> tenant_params("auth_query")
      |> put_in(["users", "0", "is_manager"], "true")

    view
    |> form("#tenant-form", tenant: params)
    |> render_submit()

    assert has_element?(view, "#tenant-connected")
    refute has_element?(view, "#connected-database-url")

    tenant = Tenants.get_tenant_by_external_id("auth_query_dashboard_tenant")
    assert tenant.require_user == false
    assert tenant.auth_query =~ "pg_authid"
    assert [%{is_manager: true}] = tenant.users
  end

  test "authenticated admin can edit tenant without replacing password", %{conn: conn} do
    tenant =
      tenant_fixture(%{
        external_id: "admin_edit_tenant",
        users: [
          %{
            "db_user" => "postgres",
            "db_password" => "postgres",
            "pool_size" => 3,
            "mode_type" => "transaction"
          }
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/admin/tenants/#{tenant.external_id}/edit")
    render_async(view)

    params =
      "admin_edit_tenant"
      |> tenant_params("stored_users")
      |> Map.put("default_pool_size", "21")
      |> put_in(["users", "0", "id"], hd(tenant.users).id)
      |> put_in(["users", "0", "db_password"], "")

    view
    |> form("#tenant-form", tenant: params)
    |> render_submit()

    assert_redirected(view, ~p"/admin")

    updated = Tenants.get_tenant_by_external_id("admin_edit_tenant")
    assert updated.db_database == Supavisor.Repo.config()[:database]
    assert updated.default_pool_size == 21
    assert hd(updated.users).db_password == "postgres"
  end

  test "authenticated admin can remove a connection profile without deleting its database", %{
    conn: conn
  } do
    tenant_fixture(%{external_id: "admin_delete_tenant"})
    {:ok, view, _html} = live(conn, ~p"/admin")
    view |> form("form[phx-change='search']", search: "admin_delete_tenant") |> render_change()

    html =
      view
      |> element(
        "button[phx-value-external-id='admin_delete_tenant'][aria-label='Remove connection admin_delete_tenant']"
      )
      |> render_click()

    assert html =~ "Connection profile removed"
    assert html =~ "The PostgreSQL database and its data were kept"

    refute Tenants.get_tenant_by_external_id("admin_delete_tenant")
  end

  defp tenant_params(external_id, auth_mode) do
    params = %{
      "external_id" => external_id,
      "db_host" => "localhost",
      "db_port" => "6432",
      "db_database" => "supavisor_test",
      "auth_mode" => auth_mode,
      "auth_query" => "SELECT rolname, rolpassword FROM pg_authid WHERE rolname=$1",
      "default_parameter_status" => ~s({"server_version":"15.0"}),
      "ip_version" => "auto",
      "upstream_ssl" => "false",
      "upstream_verify" => "none",
      "enforce_ssl" => "false",
      "default_pool_size" => "15",
      "sni_hostname" => "",
      "default_max_clients" => "1000",
      "client_idle_timeout" => "0",
      "client_heartbeat_interval" => "60",
      "allow_list" => "0.0.0.0/0\n::/0",
      "availability_zone" => "",
      "feature_flags" => "{}",
      "use_jit" => "false",
      "jit_api_url" => "",
      "users" => %{
        "0" => %{
          "db_user" => "postgres",
          "db_user_alias" => "postgres",
          "db_password" => "postgres",
          "is_manager" => "false",
          "mode_type" => "transaction",
          "pool_size" => "15",
          "pool_checkout_timeout" => "60000",
          "max_clients" => ""
        }
      }
    }

    if auth_mode == "stored_users", do: Map.delete(params, "auth_query"), else: params
  end
end
