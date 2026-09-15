defmodule SupavisorWeb.AdminTenantOverview do
  @moduledoc false
  import Ecto.Query
  alias Supavisor.{Repo, Tenants.Tenant, Tenants.User}

  def summary do
    users = from u in User, select: count(u.id)

    stats =
      Repo.one(
        from t in Tenant,
          select: %{
            tenant_count: count(t.id),
            stored_count: filter(count(t.id), t.require_user == true),
            user_total: subquery(users)
          }
      )

    Map.put(stats, :query_count, stats.tenant_count - stats.stored_count)
  end

  def page(search, filter, requested_page, page_size) do
    query = from(t in Tenant)

    query =
      case filter do
        "stored" -> where(query, [t], t.require_user == true)
        "query" -> where(query, [t], t.require_user == false)
        _ -> query
      end

    query =
      if String.trim(search) == "" do
        query
      else
        pattern =
          "%" <>
            (search
             |> String.replace("\\", "\\\\")
             |> String.replace("%", "\\%")
             |> String.replace("_", "\\_")) <> "%"

        where(
          query,
          [t],
          ilike(t.external_id, ^pattern) or ilike(t.db_host, ^pattern) or
            ilike(t.db_database, ^pattern)
        )
      end

    total = Repo.aggregate(query, :count, :id)
    pages = max(1, ceil(total / page_size))
    page = requested_page |> min(pages) |> max(1)

    rows =
      Repo.all(
        from t in query,
          left_join: u in User,
          on: u.tenant_external_id == t.external_id,
          group_by: t.id,
          order_by: t.external_id,
          limit: ^page_size,
          offset: ^((page - 1) * page_size),
          select: %{
            id: t.id,
            external_id: t.external_id,
            db_host: t.db_host,
            db_port: t.db_port,
            db_database: t.db_database,
            sni_hostname: t.sni_hostname,
            require_user: t.require_user,
            default_pool_size: t.default_pool_size,
            user_count: count(u.id)
          }
      )

    %{rows: rows, total: total, pages: pages, page: page}
  end
end
