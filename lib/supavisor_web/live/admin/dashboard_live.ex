defmodule SupavisorWeb.Admin.DashboardLive do
  use SupavisorWeb, :live_view
  alias Supavisor.Tenants
  alias SupavisorWeb.{AdminProvisioning, AdminTenantOverview}
  @page_size 10

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Supavisor.PubSub, "admin:tenants")

    {:ok,
     socket
     |> assign(
       provisioning_available: AdminProvisioning.available?(),
       search: "",
       filter: "all",
       page: 1
     )
     |> assign(AdminTenantOverview.summary())
     |> load_page()}
  end

  @impl true
  def handle_event("delete", %{"external-id" => external_id}, socket) do
    if Tenants.delete_tenant_by_external_id(external_id) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Connection profile removed. The PostgreSQL database and its data were kept."
       )
       |> assign(AdminTenantOverview.summary())
       |> load_page()}
    else
      {:noreply, put_flash(socket, :error, "Connection profile not found. Refresh the page.")}
    end
  end

  def handle_event("search", %{"search" => query}, socket),
    do: {:noreply, socket |> assign(search: query, page: 1) |> load_page()}

  def handle_event("filter", %{"filter" => filter}, socket)
      when filter in ["all", "stored", "query"],
      do: {:noreply, socket |> assign(filter: filter, page: 1) |> load_page()}

  def handle_event("page", %{"direction" => direction}, socket) do
    page = if direction == "next", do: socket.assigns.page + 1, else: socket.assigns.page - 1
    {:noreply, socket |> assign(:page, page) |> load_page()}
  end

  @impl true
  def handle_info(:tenants_changed, socket) do
    if SupavisorWeb.AdminAuth.admin_email?(socket.assigns.current_admin_email) do
      {:noreply, socket |> assign(AdminTenantOverview.summary()) |> load_page()}
    else
      {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  defp load_page(socket) do
    result =
      AdminTenantOverview.page(
        socket.assigns.search,
        socket.assigns.filter,
        socket.assigns.page,
        @page_size
      )

    socket
    |> assign(filtered_count: result.total, page: result.page, pages: result.pages)
    |> stream(:tenants, result.rows, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-hero">
      <div><div class="eyebrow"><span class="eyebrow-line"></span> YOUR DATABASE WORKSPACE</div><h1>Connections<span class="heading-dot">.</span></h1><p class="page-subtitle">Create a database or connect an existing one. Manage its users and connection settings here.</p></div>
      <div class="toolbar-actions"><.link :if={@provisioning_available} class="secondary-button" navigate={~p"/admin/provision"}><span class="hero-circle-stack"></span>Create database</.link><.link class="primary-button" navigate={~p"/admin/tenants/new"}><span class="hero-plus"></span>Connect database</.link></div>
    </section>
    <div class="stats-grid">
      <.stat_card icon="hero-square-3-stack-3d" label="Connections" value={@tenant_count} hint="Saved connection profiles" />
      <.stat_card icon="hero-users" label="Database users" value={@user_total} hint="Across your connections" />
      <.stat_card icon="hero-key" label="Saved credentials" value={@stored_count} hint="Database user passwords" />
      <.stat_card icon="hero-command-line" label="Database lookup" value={@query_count} hint="Credentials from PostgreSQL" />
    </div>
    <section class="data-panel">
      <div class="panel-toolbar">
        <div class="panel-tabs" role="tablist" aria-label="Filter connections">
          <button role="tab" aria-selected={to_string(@filter == "all")} class={@filter == "all" && "is-active"} phx-click="filter" phx-value-filter="all">All <span class="count-badge"><%= @tenant_count %></span></button>
          <button role="tab" aria-selected={to_string(@filter == "stored")} class={@filter == "stored" && "is-active"} phx-click="filter" phx-value-filter="stored">Saved passwords</button>
          <button role="tab" aria-selected={to_string(@filter == "query")} class={@filter == "query" && "is-active"} phx-click="filter" phx-value-filter="query">Database lookup</button>
        </div>
        <form class="search-field" phx-change="search" phx-submit="search"><span class="hero-magnifying-glass"></span><input type="search" name="search" value={@search} placeholder="Search connections…" aria-label="Search connections" phx-debounce="180" /></form>
      </div>
      <div class="table-scroll">
        <table class="responsive-table tenant-table">
          <thead><tr><th>Connection</th><th>Database / server</th><th>Authentication</th><th>Users</th><th>Pool</th><th><span class="sr-only">Actions</span></th></tr></thead>
          <tbody id="tenant-rows" phx-update="stream"><tr :for={{dom_id, tenant} <- @streams.tenants} id={dom_id}>
            <td class="name-cell"><span class="resource-icon"><span class="hero-square-3-stack-3d"></span></span><div><strong><%= tenant.external_id %></strong><small :if={tenant.sni_hostname} class="table-secondary"><%= tenant.sni_hostname %></small></div></td>
            <td data-label="Database / server"><span class="table-database"><%= tenant.db_database %></span><small class="table-secondary mono"><%= tenant.db_host %>:<%= tenant.db_port %></small></td>
            <td data-label="Authentication"><.badge variant="outline" icon={if tenant.require_user, do: "hero-key-mini", else: "hero-command-line-mini"}><%= if tenant.require_user, do: "Saved password", else: "Database lookup" %></.badge></td>
            <td data-label="Users" class="mono muted"><%= tenant.user_count %></td>
            <td data-label="Pool" class="mono muted"><%= tenant.default_pool_size %></td>
            <td class="row-actions"><div class="actions"><.icon_button navigate={~p"/admin/tenants/#{tenant.external_id}/edit"} label={"Edit #{tenant.external_id}"} icon="hero-pencil-square-mini" /><.icon_button variant="danger" label={"Remove connection #{tenant.external_id}"} icon="hero-trash-mini" phx-click="delete" phx-value-external-id={tenant.external_id} data-confirm={"Remove connection profile #{tenant.external_id}? The PostgreSQL database, its data and database users will be kept."} /></div></td>
          </tr></tbody>
        </table>
        <.empty_state :if={@filtered_count == 0} icon="hero-magnifying-glass" title={if @tenant_count == 0, do: "Connect your first database", else: "No connections found"} description={if @tenant_count == 0, do: "Choose Connect database to use an existing database, or Create database to make a new one.", else: "Try a different connection name or database."} />
      </div>
      <div class="panel-pagination"><span><strong><%= @filtered_count %></strong> <%= if @filtered_count == 1, do: "connection", else: "connections" %> <span class="pagination-detail">in this workspace</span></span><div><button class="quiet-button" phx-click="page" phx-value-direction="prev" disabled={@page <= 1} aria-label="Previous page"><span class="hero-chevron-left"></span></button><span><%= @page %> <span class="muted">/ <%= @pages %></span></span><button class="quiet-button" phx-click="page" phx-value-direction="next" disabled={@page >= @pages} aria-label="Next page"><span class="hero-chevron-right"></span></button></div></div>
    </section>
    <div class="quick-notes"><div><span class="note-icon hero-circle-stack"></span><div><strong>Saved connection settings</strong><p>Each profile stores access and pooling settings for a database.</p></div></div><div><span class="note-icon hero-key"></span><div><strong>Database data is kept</strong><p>Removing a connection profile keeps its PostgreSQL database and data.</p></div></div><div><span class="note-icon hero-bolt"></span><div><strong>Ready for your application</strong><p>Create or connect a database, then use its connection details.</p></div></div></div>
    """
  end
end
