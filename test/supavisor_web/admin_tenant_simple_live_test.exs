defmodule SupavisorWeb.AdminTenantSimpleLiveTest do
  use SupavisorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Supavisor.TenantsFixtures

  alias Supavisor.Tenants
  alias SupavisorWeb.{AdminAccessCache, AdminProvisioning}

  setup %{conn: conn} do
    original = Application.fetch_env!(:supavisor, AdminProvisioning)
    target = {Supavisor.Repo.config()[:hostname], Supavisor.Repo.config()[:port]}

    Application.put_env(
      :supavisor,
      AdminProvisioning,
      Keyword.put(original, :allowed_targets, [target])
    )

    AdminAccessCache.invalidate()

    on_exit(fn ->
      Application.put_env(:supavisor, AdminProvisioning, original)
      AdminAccessCache.invalidate()
    end)

    conn =
      init_test_session(conn, %{
        "admin_email" => "admin@example.com",
        "admin_authenticated_at" => System.system_time(:second)
      })

    {:ok, conn: conn, database: Supavisor.Repo.config()[:database], target: target}
  end

  test "one configured server needs no manual address or server choice", %{conn: conn} do
    {:ok, view, _} = live(conn, "/admin/tenants/new")
    render_async(view)

    assert has_element?(view, "input[type=hidden][name='connection_server'][value='0']")
    refute has_element?(view, "select[name='connection_server']")
    assert has_element?(view, "input[type=hidden][name='tenant[db_host]']")
    assert has_element?(view, "input[type=hidden][name='tenant[db_port]']")
    refute has_element?(view, "input[name='tenant[db_host]']:not([type=hidden])")
    refute has_element?(view, "input[name='tenant[db_port]']:not([type=hidden])")
    refute render(view) =~ "Enter connection manually"
    refute has_element?(view, ".stepper")
    assert has_element?(view, "#tenant-advanced:not([open])")
    assert has_element?(view, "a[href='/admin/provision']", "Create a database")
  end

  test "database selection suggests its owner and connection name", %{
    conn: conn,
    database: database
  } do
    {:ok, view, _} = live(conn, "/admin/tenants/new")
    render_async(view)
    choose_database(view, database)

    assert has_element?(view, "input[name='tenant[external_id]'][value='#{database}']")

    assert has_element?(
             view,
             "select[name='tenant[users][0][db_user]'] option[value='postgres'][selected]"
           )

    assert has_element?(view, "input[name='tenant[users][0][db_user_alias]'][value='postgres']")
    assert has_element?(view, "input[name='tenant[users][0][db_password]'][required]")
  end

  test "connecting uses server settings even when a submitted hidden address is changed", %{
    conn: conn,
    database: database,
    target: {host, port}
  } do
    name = "simple_connect_#{System.unique_integer([:positive])}"
    {:ok, view, _} = live(conn, "/admin/tenants/new")
    render_async(view)
    choose_database(view, database)

    # Send a forged event directly: normal form helpers correctly prevent
    # changing hidden browser fields before they reach the server.
    render_submit(view, "save", %{
      "tenant" => %{
        "external_id" => name,
        "db_host" => "untrusted.example",
        "db_port" => "1",
        "users" => %{"0" => %{"db_password" => "postgres"}}
      }
    })

    assert has_element?(view, "#tenant-connected", "Copy connection URL")
    refute has_element?(view, "#tenant-form")
    assert has_element?(view, "input#connected-database-url[type=password]")
    assert has_element?(view, "button[data-copy-target='#connected-database-url']")

    [uri] =
      view
      |> element("#connected-database-url")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")

    assert URI.parse(uri).userinfo == "postgres.#{name}:postgres"
    assert URI.parse(uri).path == "/#{database}"
    refute uri =~ "PASSWORD"
    view |> element("button[phx-click='toggle-connection-url']", "Show URL") |> render_click()
    assert has_element?(view, "input#connected-database-url[type=text]")
    view |> element("button[phx-click='toggle-connection-url']", "Hide URL") |> render_click()
    assert has_element?(view, "input#connected-database-url[type=password]")

    tenant = Tenants.get_tenant_by_external_id(name)
    assert tenant.db_host == host
    assert tenant.db_port == port
    assert tenant.db_database == database
    assert tenant.require_user
    assert tenant.default_pool_size == 15

    assert [%{db_user: "postgres", db_user_alias: "postgres", db_password: "postgres"}] =
             tenant.users
  end

  test "arbitrary server query parameters cannot change the configured target", %{
    conn: conn,
    database: database,
    target: {host, port}
  } do
    query =
      URI.encode_query(%{db_host: "untrusted.example", db_port: 9999, db_database: database})

    {:ok, view, _} = live(conn, "/admin/tenants/new?" <> query)
    render_async(view)

    assert has_element?(view, "input[type=hidden][name='tenant[db_host]'][value='#{host}']")
    assert has_element?(view, "input[type=hidden][name='tenant[db_port]'][value='#{port}']")

    assert has_element?(
             view,
             "select[name='tenant[db_database]'] option[value='#{database}'][selected]"
           )
  end

  test "editing an external connection preserves its address and saved password", %{conn: conn} do
    tenant =
      tenant_fixture(%{
        external_id: "simple_external_edit",
        db_host: "existing.private",
        db_port: 5449,
        db_database: "existing_database",
        users: [
          %{
            "db_user" => "existing_role",
            "db_password" => "keep_this_password",
            "pool_size" => 3,
            "mode_type" => "transaction"
          }
        ]
      })

    {:ok, view, _} = live(conn, "/admin/tenants/#{tenant.external_id}/edit")

    assert has_element?(
             view,
             "input[type=hidden][name='tenant[db_database]'][value='existing_database']"
           )

    refute has_element?(view, "select[name='connection_server']")

    assert has_element?(
             view,
             "input[name='tenant[users][0][db_password]'][placeholder='Leave blank to keep current password']"
           )

    render_submit(view, "save", %{
      "tenant" => %{"db_host" => "forged.private", "db_port" => "1", "default_pool_size" => "22"}
    })

    assert_redirected(view, "/admin")
    updated = Tenants.get_tenant_by_external_id(tenant.external_id)
    assert updated.db_host == "existing.private"
    assert updated.db_port == 5449
    assert updated.db_database == "existing_database"
    assert updated.default_pool_size == 22
    assert hd(updated.users).db_password == "keep_this_password"
  end

  test "advanced validation errors expose their fields without losing the selected database", %{
    conn: conn,
    database: database
  } do
    {:ok, view, _} = live(conn, "/admin/tenants/new")
    render_async(view)
    choose_database(view, database)

    view
    |> form("#tenant-form",
      tenant: %{"default_pool_size" => "0", "users" => %{"0" => %{"db_password" => "postgres"}}}
    )
    |> render_submit()

    assert has_element?(view, "#tenant-advanced[open]")
    assert render(view) =~ "Enter a number from 1"

    assert has_element?(
             view,
             "select[name='tenant[db_database]'] option[value='#{database}'][selected]"
           )
  end

  defp choose_database(view, database) do
    view
    |> form("#tenant-form", tenant: %{"db_database" => database})
    |> render_change(%{"_target" => ["tenant", "db_database"]})
  end
end
