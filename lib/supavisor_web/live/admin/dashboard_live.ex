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
       |> put_flash(:info, "Tenant deleted.")
       |> assign(AdminTenantOverview.summary())
       |> load_page()}
    else
      {:noreply, put_flash(socket, :error, "Tenant not found. Refresh the page.")}
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
      <div><div class="eyebrow"><span class="eyebrow-line"></span> YOUR CONNECTED WORKSPACE</div><h1>Tenants<span class="heading-dot">.</span></h1><p class="page-subtitle">Your PostgreSQL connections, in one workspace.</p></div>
      <div class="toolbar-actions"><.link :if={@provisioning_available} class="secondary-button" navigate={~p"/admin/provision"}><span class="hero-circle-stack"></span>Create database</.link><.link class="primary-button" navigate={~p"/admin/tenants/new"}><span class="hero-plus"></span>New tenant</.link></div>
    </section>
    <div class="stats-grid">
      <.stat_card icon="hero-square-3-stack-3d" label="Tenants" value={@tenant_count} hint="Connection profiles" />
      <.stat_card icon="hero-users" label="Database users" value={@user_total} hint="Configured across tenants" />
      <.stat_card icon="hero-key" label="Stored credentials" value={@stored_count} hint="Supavisor authentication" />
      <.stat_card icon="hero-command-line" label="Auth query" value={@query_count} hint="PostgreSQL authentication" />
    </div>
    <section class="data-panel">
      <div class="panel-toolbar">
        <div class="panel-tabs" role="tablist" aria-label="Filter tenants">
          <button role="tab" aria-selected={to_string(@filter == "all")} class={@filter == "all" && "is-active"} phx-click="filter" phx-value-filter="all">All <span class="count-badge"><%= @tenant_count %></span></button>
          <button role="tab" aria-selected={to_string(@filter == "stored")} class={@filter == "stored" && "is-active"} phx-click="filter" phx-value-filter="stored">Credentials</button>
          <button role="tab" aria-selected={to_string(@filter == "query")} class={@filter == "query" && "is-active"} phx-click="filter" phx-value-filter="query">Auth query</button>
        </div>
        <form class="search-field" phx-change="search" phx-submit="search"><span class="hero-magnifying-glass"></span><input type="search" name="search" value={@search} placeholder="Search tenants…" aria-label="Search tenants" phx-debounce="180" /></form>
      </div>
      <div class="table-scroll">
        <table class="responsive-table tenant-table">
          <thead><tr><th>Tenant</th><th>Database / host</th><th>Authentication</th><th>Users</th><th>Pool</th><th><span class="sr-only">Actions</span></th></tr></thead>
          <tbody id="tenant-rows" phx-update="stream"><tr :for={{dom_id, tenant} <- @streams.tenants} id={dom_id}>
            <td class="name-cell"><span class="resource-icon"><span class="hero-square-3-stack-3d"></span></span><div><strong><%= tenant.external_id %></strong><small :if={tenant.sni_hostname} class="table-secondary"><%= tenant.sni_hostname %></small></div></td>
            <td data-label="Database / host"><span class="table-database"><%= tenant.db_database %></span><small class="table-secondary mono"><%= tenant.db_host %>:<%= tenant.db_port %></small></td>
            <td data-label="Authentication"><.badge variant="outline" icon={if tenant.require_user, do: "hero-key-mini", else: "hero-command-line-mini"}><%= if tenant.require_user, do: "Credentials", else: "Auth query" %></.badge></td>
            <td data-label="Users" class="mono muted"><%= tenant.user_count %></td>
            <td data-label="Pool" class="mono muted"><%= tenant.default_pool_size %></td>
            <td class="row-actions"><div class="actions"><.icon_button navigate={~p"/admin/tenants/#{tenant.external_id}/edit"} label={"Edit #{tenant.external_id}"} icon="hero-pencil-square-mini" /><.icon_button variant="danger" label={"Delete #{tenant.external_id}"} icon="hero-trash-mini" phx-click="delete" phx-value-external-id={tenant.external_id} data-confirm={"Delete profile #{tenant.external_id}? The PostgreSQL database will be kept."} /></div></td>
          </tr></tbody>
        </table>
        <.empty_state :if={@filtered_count == 0} icon="hero-magnifying-glass" title={if @tenant_count == 0, do: "Your first tenant", else: "No tenants found"} description={if @tenant_count == 0, do: "Create a profile to connect PostgreSQL to your workspace.", else: "Try a different name, host or database."} />
      </div>
      <div class="panel-pagination"><span><strong><%= @filtered_count %></strong> tenant <span class="pagination-detail">in this workspace</span></span><div><button class="quiet-button" phx-click="page" phx-value-direction="prev" disabled={@page <= 1} aria-label="Previous page"><span class="hero-chevron-left"></span></button><span><%= @page %> <span class="muted">/ <%= @pages %></span></span><button class="quiet-button" phx-click="page" phx-value-direction="next" disabled={@page >= @pages} aria-label="Next page"><span class="hero-chevron-right"></span></button></div></div>
    </section>
    <div class="quick-notes"><div><span class="note-icon hero-circle-stack"></span><div><strong>One database, one profile</strong><p>Each tenant defines access and pooling.</p></div></div><div><span class="note-icon hero-key"></span><div><strong>Access that fits</strong><p>Stored credentials or an authentication query.</p></div></div><div><span class="note-icon hero-bolt"></span><div><strong>Connections, organized</strong><p>Manage users and pool settings in your tenant.</p></div></div></div>
    """
  end
end
