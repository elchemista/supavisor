defmodule SupavisorWeb.AdminPostgres do
  @moduledoc false
  alias SupavisorWeb.AdminProvisioning

  def connection_catalog(host, port, refresh \\ false) do
    key = {:admin_connection_catalog, host, port}
    if refresh, do: Cachex.del(Supavisor.Cache, key)

    case Cachex.fetch(Supavisor.Cache, key, fn ->
           case load_connection_catalog(host, port) do
             {:ok, catalog} -> {:commit, catalog, ttl: :timer.seconds(30)}
             error -> {:ignore, error}
           end
         end) do
      {:commit, catalog, _options} when is_map(catalog) -> {:ok, catalog}
      {status, catalog} when status in [:ok, :commit] and is_map(catalog) -> {:ok, catalog}
      _ -> {:error, :connection_failed}
    end
  end

  defp load_connection_catalog(host, port) do
    AdminProvisioning.with_connection(host, port, fn conn ->
      with {:ok, %{rows: databases}} <-
             Postgrex.query(
               conn,
               """
               SELECT datname, pg_get_userbyid(datdba)
               FROM pg_database WHERE NOT datistemplate AND datallowconn
               ORDER BY datname LIMIT 500
               """,
               []
             ),
           {:ok, %{rows: roles}} <-
             Postgrex.query(
               conn,
               """
               SELECT rolname FROM pg_roles WHERE rolcanlogin
               ORDER BY rolname LIMIT 500
               """,
               []
             ) do
        {:ok,
         %{
           databases: Enum.map(databases, fn [name, owner] -> %{name: name, owner: owner} end),
           roles: List.flatten(roles)
         }}
      else
        _ -> {:error, :connection_failed}
      end
    end)
  end

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
