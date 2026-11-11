defmodule SupavisorWeb.AdminProvisionSimpleLiveTest do
  use SupavisorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Supavisor.{Repo, Tenants}
  alias SupavisorWeb.{AdminAccessCache, AdminCredential, AdminProvisioning, AdminProvisioningForm}

  setup %{conn: conn} do
    original = Application.fetch_env!(:supavisor, AdminProvisioning)
    {host, port} = AdminProvisioning.default_target()

    Application.put_env(
      :supavisor,
      AdminProvisioning,
      Keyword.put(original, :allowed_targets, [{host, port}])
    )

    AdminAccessCache.invalidate()

    conn =
      init_test_session(conn, %{
        "admin_email" => "admin@example.com",
        "admin_authenticated_at" => System.system_time(:second),
        "admin_session_version" => AdminCredential.session_version("admin@example.com")
      })

    on_exit(fn ->
      Application.put_env(:supavisor, AdminProvisioning, original)
      AdminAccessCache.invalidate()
    end)

    {:ok, conn: conn, host: host, port: port}
  end

  test "creation needs only a database name and uses the configured server", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/provision")
    assert html =~ "Choose a name"
    assert has_element?(view, "#provision-form input[name='provision[database_name]'][required]")
    refute has_element?(view, "#provision-form input[name='provision[external_id]'][required]")
    refute has_element?(view, "#provision-form input[name='provision[role_name]'][required]")
    refute has_element?(view, "#provision-form [name='provision[target_host]']")
    refute has_element?(view, "#provision-form [name='provision[target_port]']")
    refute has_element?(view, "#provision-form [name='provision[server]']")
    refute has_element?(view, "#provision-advanced[open]")
  end

  test "one field creates a real database, owner and ready connection", %{
    conn: conn,
    host: host,
    port: port
  } do
    id = "simple_create_#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup_database(id, host, port) end)
    {:ok, view, _} = live(conn, "/admin/provision")

    view |> form("#provision-form", provision: %{database_name: id}) |> render_submit()

    assert has_element?(view, "#provision-success", "Database is ready")

    assert has_element?(
             view,
             "button[data-copy-target='#provision-connection-url']",
             "Copy connection URL"
           )

    assert has_element?(view, "#provision-connection-url[value^='postgresql://#{id}.#{id}:']")
    refute has_element?(view, "#provision-form")

    tenant = Tenants.get_tenant_by_external_id(id)
    assert tenant.db_database == id
    assert tenant.db_host == to_string(host)
    assert tenant.db_port == port
    assert [%{db_user: ^id, db_password: password}] = tenant.users
    assert byte_size(password) >= 32

    {:ok, database} =
      Postgrex.start_link(
        hostname: host,
        port: port,
        database: id,
        username: id,
        password: password
      )

    assert %{rows: [[^id, ^id]]} =
             Postgrex.query!(database, "SELECT current_database(), current_user", [])

    GenServer.stop(database)
  end

  test "invalid names show validation without creating a connection", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/provision")

    html =
      view
      |> form("#provision-form", provision: %{database_name: "Invalid-Name"})
      |> render_submit()

    assert html =~ "lowercase Postgres identifier"
    refute Tenants.get_tenant_by_external_id("Invalid-Name")
    assert has_element?(view, "#provision-form")
  end

  test "console defaults keep explicit advanced names and ignore forged host fields", %{
    host: host,
    port: port
  } do
    assert {:ok, attrs} =
             AdminProvisioningForm.console_attrs(%{
               "database_name" => "simple_defaults",
               "target_host" => "untrusted.example.com",
               "target_port" => "9999"
             })

    assert attrs.external_id == "simple_defaults"
    assert attrs.role_name == "simple_defaults"
    assert attrs.host == to_string(host)
    assert attrs.port == port

    assert {:ok, custom} =
             AdminProvisioningForm.console_attrs(%{
               "database_name" => "simple_defaults",
               "external_id" => "custom_connection",
               "role_name" => "custom_owner"
             })

    assert custom.external_id == "custom_connection"
    assert custom.role_name == "custom_owner"
  end

  test "multiple configured servers are selectable without entering addresses", %{
    conn: conn,
    host: host,
    port: port
  } do
    config = Application.fetch_env!(:supavisor, AdminProvisioning)

    Application.put_env(
      :supavisor,
      AdminProvisioning,
      Keyword.put(config, :allowed_targets, [{host, port}, {"second.internal", 5439}])
    )

    {:ok, view, _} = live(conn, "/admin/provision")
    assert has_element?(view, "select[name='provision[server]'] option[value='1']")
    refute has_element?(view, "input[name='provision[target_host]']")

    assert {:ok, attrs} =
             AdminProvisioningForm.console_attrs(%{
               "database_name" => "second_database",
               "server" => "1"
             })

    assert attrs.host == "second.internal"
    assert attrs.port == 5439

    assert {:error, %{"server" => [_]}, _} =
             AdminProvisioningForm.console_attrs(%{
               "database_name" => "invalid_server",
               "server" => "99"
             })
  end

  test "unavailable creation explains the server setup without asking for a host", %{conn: conn} do
    Application.put_env(:supavisor, AdminProvisioning, enabled: false)
    {:ok, view, html} = live(conn, "/admin/provision")
    assert html =~ "Database creation is unavailable"
    assert html =~ "server administrator"
    refute has_element?(view, "#provision-form")
    assert has_element?(view, "a[href='/admin/tenants/new']", "Connect an existing database")
  end

  defp cleanup_database(id, host, port) do
    config = Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: host,
        port: port,
        database: "postgres",
        username: config[:username],
        password: config[:password]
      )

    Postgrex.query!(conn, ~s|DROP DATABASE IF EXISTS "#{id}" WITH (FORCE)|, [])
    Postgrex.query!(conn, ~s(DROP ROLE IF EXISTS "#{id}"), [])
    GenServer.stop(conn)
  end
end
