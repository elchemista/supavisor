defmodule Supavisor.MCP.DatabaseTest do
  use Supavisor.DataCase, async: false

  alias Supavisor.MCP.{Auth, Client, Database, Grant, Tools}
  alias Supavisor.TenantsFixtures

  setup do
    id = "mcp_db_#{System.unique_integer([:positive])}"
    password = "mcp_integration_test_password"

    cleanup_database(id)

    with_admin(fn conn ->
      Postgrex.query!(conn, ~s(CREATE ROLE "#{id}" LOGIN PASSWORD '#{password}'), [])
      Postgrex.query!(conn, ~s(CREATE DATABASE "#{id}" OWNER "#{id}"), [])
    end)

    with_owner(id, password, fn conn ->
      Postgrex.query!(
        conn,
        "CREATE TABLE accounts (id integer PRIMARY KEY, name text NOT NULL)",
        []
      )

      Postgrex.query!(conn, "INSERT INTO accounts VALUES (1, 'first'), (2, 'second')", [])
    end)

    tenant = tenant(id, id, password)

    grant = %Grant{
      admin_email: "admin@example.com",
      scopes: ["db:read", "db:create", "db:migrate"],
      tenant_ids: [tenant.external_id]
    }

    {:ok, id: id, password: password, tenant: tenant, grant: grant}
  end

  test "queries use the tenant role, parameterize values and bound results", %{
    id: id,
    grant: grant
  } do
    assert {:ok, %{rows: [[^id, ^id]]}} =
             Database.query(grant, id, "SELECT current_user, current_database()", [], 10)

    assert {:ok, %{columns: ["name"], rows: [["second"]], row_count: 1, truncated: false}} =
             Database.query(grant, id, "SELECT name FROM accounts WHERE id = $1", [2], 10)

    assert {:ok, %{rows: [[1], [2]], row_count: 2, truncated: true}} =
             Database.query(grant, id, "SELECT generate_series(1, 5)", [], 2)
  end

  test "read queries reject mutations, including writes hidden in a CTE or function", %{
    id: id,
    password: password,
    grant: grant
  } do
    assert {:error, _} =
             Database.query(grant, id, "DELETE FROM accounts RETURNING id", [], 10)

    assert {:error, _} =
             Database.query(
               grant,
               id,
               "WITH removed AS (DELETE FROM accounts RETURNING id) SELECT * FROM removed",
               [],
               10
             )

    with_owner(id, password, fn conn ->
      Postgrex.query!(
        conn,
        """
        CREATE FUNCTION attempt_write() RETURNS integer LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO accounts VALUES (3, 'hidden write');
          RETURN 3;
        END
        $$
        """,
        []
      )
    end)

    assert {:error, _} = Database.query(grant, id, "SELECT attempt_write()", [], 10)

    assert {:ok, %{rows: [[2]]}} =
             Database.query(grant, id, "SELECT count(*) FROM accounts", [], 10)
  end

  test "invalid SQL parameter encodings return a tool error without crashing", %{
    id: id,
    grant: grant
  } do
    assert {:error, _} = Database.query(grant, id, "SELECT $1::integer", ["not an integer"], 10)

    assert {:error, _} =
             Tools.call(grant, "read_query", %{
               "tenant_id" => id,
               "sql" => "SELECT 1",
               "limit" => "invalid"
             })

    assert {:error, _} =
             Tools.call(grant, "create_database", %{
               "external_id" => 123,
               "database_name" => "invalid",
               "role_name" => "invalid"
             })
  end

  test "tenant selection and tool scopes are enforced before database operations", %{
    id: id,
    grant: grant
  } do
    other_grant = %{grant | tenant_ids: ["another_tenant"]}
    assert {:ok, %{databases: []}} = Database.list(other_grant)
    assert {:error, _} = Database.query(other_grant, id, "SELECT 1", [], 10)
    assert {:error, _} = Database.describe(other_grant, id)
    assert {:error, _} = Database.history(other_grant, id)

    assert {:error, _} =
             Database.migrate(other_grant, id, "denied", ["CREATE TABLE denied (id int)"])

    read_grant = %{grant | scopes: ["db:read"]}

    assert {:error, _} =
             Tools.call(read_grant, "apply_migration", %{
               "tenant_id" => id,
               "name" => "denied",
               "statements" => ["CREATE TABLE denied (id int)"]
             })

    assert {:error, _} =
             Tools.call(read_grant, "create_database", %{
               "external_id" => "denied",
               "database_name" => "denied",
               "role_name" => "denied"
             })
  end

  test "privileged PostgreSQL users and the metadata database are refused", %{
    id: id,
    grant: grant
  } do
    privileged_id = id <> "_admin"
    tenant(privileged_id, id, "postgres", "postgres")
    privileged = %{grant | tenant_ids: [privileged_id]}

    assert {:error, message} = Database.query(privileged, privileged_id, "SELECT 1", [], 10)
    assert message =~ "without PostgreSQL administrative privileges"

    metadata_id = id <> "_metadata"
    tenant(metadata_id, Repo.config()[:database], "postgres", "postgres")
    metadata = %{grant | tenant_ids: [metadata_id]}
    assert {:error, _} = Database.query(metadata, metadata_id, "SELECT 1", [], 10)
  end

  test "membership in a server-file role cannot bypass the tenant privilege boundary", %{
    id: id,
    grant: grant
  } do
    with_admin(fn conn ->
      Postgrex.query!(conn, ~s(GRANT pg_read_server_files TO "#{id}"), [])
    end)

    assert {:error, message} = Database.query(grant, id, "SELECT current_user", [], 10)
    assert message =~ "without PostgreSQL administrative privileges"
  end

  test "schema descriptions and empty migration history are available", %{id: id, grant: grant} do
    assert {:ok, %{rows: rows}} = Database.describe(grant, id)
    assert Enum.any?(rows, &match?(["public", "accounts", "name", "text", "NO", nil], &1))
    assert {:ok, %{rows: [], row_count: 0}} = Database.history(grant, id)
  end

  test "migrations are atomic, idempotent and retain SQL and actor history", %{
    id: id,
    grant: grant
  } do
    statements = [
      "CREATE TABLE events (id integer PRIMARY KEY, label text)",
      "INSERT INTO events VALUES (1, 'created once')"
    ]

    assert {:ok, %{name: "create_events", applied: true, checksum: checksum}} =
             Database.migrate(grant, id, "create_events", statements)

    assert checksum =~ ~r/^[a-f0-9]{64}$/

    assert {:ok, %{applied: false, checksum: ^checksum}} =
             Database.migrate(grant, id, "create_events", statements)

    assert {:ok, %{rows: [[1]]}} =
             Database.query(grant, id, "SELECT count(*) FROM events", [], 10)

    assert {:ok, %{columns: columns, rows: [row], row_count: 1}} = Database.history(grant, id)
    entry = Map.new(Enum.zip(columns, row))
    assert entry["name"] == "create_events"
    assert entry["checksum"] == checksum
    assert entry["statements"] == statements
    assert entry["applied_by"] == "admin@example.com"
    assert {:ok, _, _} = DateTime.from_iso8601(entry["applied_at"])

    assert {:error, _} =
             Database.migrate(grant, id, "create_events", [
               "ALTER TABLE events ADD COLUMN changed int"
             ])

    assert {:ok, %{rows: [[0]]}} =
             Database.query(
               grant,
               id,
               "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'events' AND column_name = 'changed'",
               [],
               10
             )
  end

  test "failed migrations roll back schema, data and history together", %{id: id, grant: grant} do
    assert {:error, _} =
             Database.migrate(grant, id, "must_rollback", [
               "CREATE TABLE rollback_probe (id int)",
               "INSERT INTO accounts VALUES (3, 'must rollback')",
               "INSERT INTO nonexistent_table VALUES (1)"
             ])

    assert {:ok, %{rows: [[nil, 2]]}} =
             Database.query(
               grant,
               id,
               "SELECT to_regclass('public.rollback_probe'), (SELECT count(*) FROM accounts)",
               [],
               10
             )

    assert {:ok, %{rows: [], row_count: 0}} = Database.history(grant, id)
  end

  test "multi-statement entries, transaction control and database administration are rejected", %{
    id: id,
    grant: grant
  } do
    for statements <- [
          ["CREATE TABLE rejected (id int); INSERT INTO rejected VALUES (1)"],
          ["BEGIN", "CREATE TABLE rejected (id int)", "COMMIT"],
          ["ROLLBACK"],
          ["CREATE ROLE rejected LOGIN"],
          ["CREATE DATABASE rejected"],
          ["SET ROLE postgres"]
        ] do
      assert {:error, _} = Database.migrate(grant, id, "rejected", statements)
    end

    assert {:ok, %{rows: [[nil]]}} =
             Database.query(grant, id, "SELECT to_regclass('public.rejected')", [], 10)

    assert {:ok, %{rows: [], row_count: 0}} = Database.history(grant, id)
  end

  test "create tool needs only a database name, returns no credentials and authorizes the new tenant",
       %{
         grant: grant
       } do
    id = "mcp_create_#{System.unique_integer([:positive])}"
    cleanup_database(id)
    grant = persist_grant(grant)

    assert {:ok, result} =
             Tools.call(grant, "create_database", %{
               "database_name" => id
             })

    assert result == %{tenant_external_id: id, database_name: id, role_name: id}
    created = Supavisor.Tenants.get_tenant_by_external_id(id)
    assert [user] = created.users
    assert is_binary(user.db_password) and byte_size(user.db_password) > 20
    refute JSON.encode!(result) =~ user.db_password

    updated_grant = Repo.get!(Grant, grant.id)
    assert id in updated_grant.tenant_ids

    assert {:ok, %{rows: [[^id, ^id]]}} =
             Database.query(updated_grant, id, "SELECT current_database(), current_user", [], 10)
  end

  defp tenant(id, database, password, username \\ nil) do
    config = Repo.config()

    TenantsFixtures.tenant_fixture(%{
      external_id: id,
      db_database: database,
      db_host: config[:hostname],
      db_port: config[:port],
      users: [
        %{
          "db_user" => username || id,
          "db_password" => password,
          "pool_size" => 1,
          "mode_type" => "transaction"
        }
      ]
    })
  end

  defp persist_grant(grant) do
    id = Ecto.UUID.generate()

    Repo.insert!(%Client{
      id: id,
      name: "Database integration tests",
      redirect_uris: ["http://localhost/callback"]
    })

    Repo.insert!(%{
      grant
      | client_id: id,
        resource: Auth.resource(),
        access_hash: id <> "access",
        refresh_hash: id <> "refresh",
        expires_at: DateTime.add(DateTime.utc_now(), 3600),
        refresh_expires_at: DateTime.add(DateTime.utc_now(), 86_400)
    })
  end

  defp cleanup_database(id) do
    on_exit(fn ->
      with_admin(fn conn ->
        Postgrex.query!(conn, ~s|DROP DATABASE IF EXISTS "#{id}" WITH (FORCE)|, [])
        Postgrex.query!(conn, ~s(DROP ROLE IF EXISTS "#{id}"), [])
      end)
    end)
  end

  defp with_owner(id, password, fun) do
    opts = connection_options() |> Keyword.merge(database: id, username: id, password: password)
    with_connection(opts, fun)
  end

  defp with_admin(fun),
    do: with_connection(Keyword.put(connection_options(), :database, "postgres"), fun)

  defp connection_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end

  defp with_connection(opts, fun) do
    {:ok, conn} = Postgrex.start_link(opts)
    Process.unlink(conn)

    try do
      fun.(conn)
    after
      if Process.alive?(conn), do: GenServer.stop(conn)
    end
  end
end
