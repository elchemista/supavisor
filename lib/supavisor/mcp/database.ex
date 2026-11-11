defmodule Supavisor.MCP.Database do
  @moduledoc "Database operations performed as the tenant's stored PostgreSQL role."

  alias Supavisor.{PgParser, Repo, Tenants}
  alias Supavisor.MCP.Auth
  import Ecto.Query

  @max_rows 200
  @migration_types ~w(CreateStmt CreateSchemaStmt CreateSeqStmt AlterSeqStmt IndexStmt
    AlterTableStmt RenameStmt DropStmt CreateEnumStmt AlterEnumStmt CreateDomainStmt
    AlterDomainStmt ViewStmt CreateFunctionStmt AlterFunctionStmt CreateTrigStmt
    RuleStmt CommentStmt InsertStmt UpdateStmt DeleteStmt MergeStmt DoStmt
    CreateExtensionStmt AlterExtensionStmt AlterExtensionContentsStmt)

  def list(grant) do
    query = from(t in Supavisor.Tenants.Tenant, order_by: t.external_id, limit: 500)

    query =
      if "*" in grant.tenant_ids,
        do: query,
        else: where(query, [t], t.external_id in ^grant.tenant_ids)

    {:ok,
     %{
       databases:
         Enum.map(Repo.all(query), &%{tenant_id: &1.external_id, database: &1.db_database})
     }}
  end

  def describe(grant, id) do
    with_tenant(grant, id, fn conn ->
      read(
        conn,
        """
        SELECT table_schema, table_name, column_name, data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema', '_supavisor', '_supavisor_mcp')
        ORDER BY table_schema, table_name, ordinal_position
        """,
        [],
        @max_rows
      )
    end)
  end

  def query(grant, id, sql, params, limit)
      when is_binary(sql) and byte_size(sql) <= 65_536 and is_list(params) and
             length(params) <= 100 and is_integer(limit) and limit in 1..@max_rows do
    # PostgreSQL enforces read-only semantics too, including writes hidden in CTEs/functions.
    with {:ok, ["SelectStmt"]} <- PgParser.statements(sql) do
      sql = sql |> String.trim() |> String.trim_trailing(";")
      with_tenant(grant, id, &read(&1, sql, params, limit))
    else
      _ -> {:error, "Supply one SELECT or WITH query."}
    end
  end

  def query(_, _, _, _, _), do: {:error, "Invalid query, parameters, or row limit (1–200)."}

  def history(grant, id) do
    with_tenant(grant, id, fn conn ->
      case Postgrex.query(conn, "SELECT to_regclass('_supavisor_mcp.migrations')", []) do
        {:ok, %{rows: [[nil]]}} ->
          {:ok, %{columns: [], rows: [], row_count: 0, truncated: false}}

        {:ok, _} ->
          read(
            conn,
            "SELECT name, checksum, statements, applied_at, applied_by FROM _supavisor_mcp.migrations ORDER BY applied_at DESC, name",
            [],
            @max_rows
          )

        error ->
          error
      end
    end)
  end

  def migrate(grant, id, name, statements)
      when is_binary(name) and byte_size(name) in 1..128 and is_list(statements) and
             length(statements) in 1..100 do
    with :ok <- validate_statements(statements) do
      with_tenant(grant, id, fn conn ->
        checksum = :crypto.hash(:sha256, JSON.encode!(statements)) |> Base.encode16(case: :lower)

        transaction(conn, fn tx ->
          Postgrex.query!(tx, "SELECT pg_advisory_xact_lock(714489218734)", [])
          Postgrex.query!(tx, "CREATE SCHEMA IF NOT EXISTS _supavisor_mcp", [])

          Postgrex.query!(
            tx,
            """
            CREATE TABLE IF NOT EXISTS _supavisor_mcp.migrations (
              name text PRIMARY KEY, checksum text NOT NULL, statements text[] NOT NULL,
              applied_at timestamptz NOT NULL DEFAULT clock_timestamp(), applied_by text NOT NULL
            )
            """,
            []
          )

          case Postgrex.query!(
                 tx,
                 "SELECT checksum FROM _supavisor_mcp.migrations WHERE name = $1",
                 [name]
               ) do
            %{rows: [[^checksum]]} ->
              %{name: name, checksum: checksum, applied: false}

            %{rows: [[_]]} ->
              Postgrex.rollback(tx, "A migration with this name has different SQL.")

            %{rows: []} ->
              Enum.each(statements, &Postgrex.query!(tx, &1, []))

              Postgrex.query!(
                tx,
                "INSERT INTO _supavisor_mcp.migrations (name, checksum, statements, applied_by) VALUES ($1, $2, $3, $4)",
                [name, checksum, statements, grant.admin_email]
              )

              %{name: name, checksum: checksum, applied: true}
          end
        end)
      end)
    end
  end

  def migrate(_, _, _, _), do: {:error, "Provide a migration name and 1–100 SQL statements."}

  def validate_statements(statements) do
    valid? =
      Enum.all?(statements, fn
        sql when is_binary(sql) and byte_size(sql) in 1..65_536 ->
          case PgParser.statements(sql) do
            {:ok, [type]} -> type in @migration_types
            _ -> false
          end

        _ ->
          false
      end)

    if valid? and Enum.reduce(statements, 0, &(byte_size(&1) + &2)) <= 262_144,
      do: :ok,
      else:
        {:error,
         "Each entry must be one schema/data migration statement. Transaction control and role/database administration are excluded; total SQL is limited to 256 KiB."}
  end

  defp read(conn, sql, params, limit) do
    transaction(conn, fn tx ->
      Postgrex.query!(tx, "SET TRANSACTION READ ONLY", [])

      result =
        Postgrex.query!(tx, "SELECT * FROM (\n#{sql}\n) AS mcp_result LIMIT #{limit + 1}", params)

      %{
        columns: result.columns,
        rows:
          result.rows
          |> Enum.take(limit)
          |> Enum.map(&Enum.map(&1, fn value -> normalize(value) end)),
        row_count: min(result.num_rows, limit),
        truncated: result.num_rows > limit
      }
    end)
  end

  defp transaction(conn, fun) do
    Postgrex.transaction(
      conn,
      fn tx ->
        Postgrex.query!(tx, "SET LOCAL statement_timeout = '5s'", [])
        Postgrex.query!(tx, "SET LOCAL lock_timeout = '1s'", [])
        fun.(tx)
      end,
      timeout: 30_000
    )
  end

  defp with_tenant(grant, id, fun) do
    with true <- Auth.allowed_tenant?(grant, id),
         %{} = tenant <- Tenants.get_tenant_by_external_id(id),
         false <- metadata_database?(tenant),
         %{db_password: password} = user when is_binary(password) and password != "" <-
           Enum.find(tenant.users, &(not &1.is_manager)),
         {:ok, conn} <- Postgrex.start_link(connection_options(tenant, user)) do
      Process.unlink(conn)

      try do
        with :ok <- restricted_role(conn) do
          fun.(conn)
        end
      rescue
        _ in [
          Postgrex.Error,
          Postgrex.QueryError,
          DBConnection.ConnectionError,
          DBConnection.EncodeError
        ] ->
          {:error,
           "PostgreSQL rejected the operation; no credentials or server details are returned."}
      catch
        :exit, _ -> {:error, "Database connection failed."}
      after
        stop_connection(conn)
      end
    else
      _ ->
        {:error,
         "Database unavailable or outside the authorized selection. A stored, non-administrative tenant role is required."}
    end
  end

  defp stop_connection(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp restricted_role(conn) do
    case Postgrex.query(
           conn,
           """
           SELECT EXISTS (
             SELECT 1 FROM pg_roles
           WHERE (rolsuper OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls
           OR rolname IN ('pg_execute_server_program', 'pg_read_server_files', 'pg_write_server_files'))
               AND pg_has_role(current_user, oid, 'MEMBER')
           )
           """,
           []
         ) do
      {:ok, %{rows: [[false]]}} -> :ok
      _ -> {:error, "MCP requires a tenant role without PostgreSQL administrative privileges."}
    end
  end

  defp metadata_database?(tenant) do
    # Never expose the control plane, even when registered as a tenant under an alias.
    tenant.db_database == Repo.config()[:database]
  end

  defp connection_options(tenant, user) do
    ssl =
      if tenant.upstream_ssl do
        if tenant.upstream_verify == :peer do
          [
            verify: :verify_peer,
            cacerts:
              if(tenant.upstream_tls_ca,
                do: [tenant.upstream_tls_ca],
                else: :public_key.cacerts_get()
              ),
            server_name_indication: String.to_charlist(tenant.db_host)
          ]
        else
          [verify: :verify_none]
        end
      else
        false
      end

    [
      hostname: tenant.db_host,
      port: tenant.db_port,
      database: tenant.db_database,
      username: user.db_user,
      password: user.db_password,
      ssl: ssl,
      connect_timeout: 5_000,
      timeout: 10_000,
      backoff_type: :stop,
      parameters: [
        application_name: "supavisor_mcp",
        statement_timeout: "5000",
        lock_timeout: "1000"
      ]
    ]
  end

  defp normalize(nil), do: nil
  defp normalize(value) when is_boolean(value) or is_number(value), do: value

  defp normalize(value) when is_binary(value) do
    if String.valid?(value), do: String.slice(value, 0, 4096), else: "[binary data]"
  end

  defp normalize(value) when is_list(value), do: Enum.map(Enum.take(value, 200), &normalize/1)
  defp normalize(%Decimal{} = value), do: Decimal.to_string(value)
  defp normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize(value) when is_struct(value),
    do: inspect(value, limit: 20, printable_limit: 4096)

  defp normalize(value) when is_map(value),
    do: Map.new(Enum.take(value, 200), fn {k, v} -> {to_string(k), normalize(v)} end)

  defp normalize(value), do: inspect(value, limit: 20, printable_limit: 4096)
end
