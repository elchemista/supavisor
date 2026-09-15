defmodule SupavisorWeb.AdminPostgres do
  @moduledoc false
  alias SupavisorWeb.AdminProvisioning

  def overview(host, port) do
    AdminProvisioning.with_connection(host, port, fn conn ->
      with {:ok, %{rows: [[version]]}} <- Postgrex.query(conn, "SHOW server_version", []),
           {:ok, %{rows: databases}} <-
             Postgrex.query(
               conn,
               """
               SELECT d.datname, pg_get_userbyid(d.datdba),
                      pg_size_pretty(pg_database_size(d.oid)),
                      (SELECT count(*) FROM pg_stat_activity a WHERE a.datid = d.oid)
               FROM pg_database d WHERE NOT d.datistemplate
               ORDER BY d.datname LIMIT 500
               """,
               []
             ),
           {:ok, %{rows: roles}} <-
             Postgrex.query(
               conn,
               """
               SELECT rolname, rolcanlogin, rolcreatedb, rolcreaterole, rolconnlimit
               FROM pg_roles WHERE left(rolname, 3) <> 'pg_'
               ORDER BY rolname LIMIT 500
               """,
               []
             ) do
        {:ok, %{version: version, databases: databases, roles: roles}}
      else
        {:error, _} -> {:error, :connection_failed}
      end
    end)
  end
end
