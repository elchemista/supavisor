defmodule SupavisorWeb.Admin.PostgresLive do
  use SupavisorWeb, :live_view

  alias SupavisorWeb.{AdminPostgres, AdminProvisioning}
  @page_size 10

  @impl true
  def mount(_params, _session, socket) do
    targets =
      Enum.map(AdminProvisioning.allowed_targets(), fn
        {host, port} -> {host, port}
        %{host: host, port: port} -> {host, port}
      end)

    socket =
      assign(socket,
        targets: targets,
        selected: 0,
        overview: nil,
        loading: false,
        error: nil,
        tab: "databases",
        search: "",
        page: 1,
        updated_at: nil,
        databases: 0,
        roles: 0,
        connections: 0,
        logins: 0
      )
      |> stream_configure(:databases,
        dom_id: fn row -> "postgres-db-" <> Base.url_encode64(row.id, padding: false) end
      )
      |> stream_configure(:roles,
        dom_id: fn row -> "postgres-role-" <> Base.url_encode64(row.id, padding: false) end
      )
      |> stream_page()

    {:ok, if(connected?(socket), do: refresh(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("search", %{"search" => query}, socket),
    do: {:noreply, socket |> assign(search: query, page: 1) |> stream_page()}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["databases", "roles"],
    do: {:noreply, socket |> assign(tab: tab, search: "", page: 1) |> stream_page()}

  def handle_event("page", %{"direction" => direction}, socket) do
    total = filtered_rows(socket.assigns) |> length()
    pages = max(1, ceil(total / @page_size))

    page =
      if direction == "next",
        do: min(socket.assigns.page + 1, pages),
        else: max(socket.assigns.page - 1, 1)

    {:noreply, socket |> assign(:page, page) |> stream_page()}
  end

  def handle_event("select", %{"target" => target}, socket) do
    case Integer.parse(target) do
      {index, ""} when index >= 0 and index < length(socket.assigns.targets) ->
        {:noreply,
         socket |> assign(selected: index, overview: nil, page: 1) |> stream_page() |> refresh()}

      _ ->
        {:noreply, socket}
    end
  end

  defp refresh(socket) do
    case Enum.at(socket.assigns.targets, socket.assigns.selected) do
      nil ->
        assign(socket, error: "Configure a PostgreSQL server to see its databases and roles.")

      {host, port} ->
        socket
        |> cancel_async(:overview)
        |> assign(loading: true, error: nil)
        |> start_async(:overview, fn -> AdminPostgres.overview(host, port) end)
    end
  end

  @impl true
  def handle_async(:overview, {:ok, {:ok, overview}}, socket) do
    {:noreply,
     socket
     |> assign(
       overview: overview,
       loading: false,
       updated_at: DateTime.utc_now(),
       databases: length(overview.databases),
       roles: length(overview.roles),
       connections: Enum.reduce(overview.databases, 0, fn [_, _, _, n], sum -> sum + n end),
       logins: Enum.count(overview.roles, fn [_, login, _, _, _] -> login end)
     )
     |> stream_page()}
  end

  def handle_async(:overview, _result, socket) do
    {:noreply,
     assign(socket,
       overview: nil,
       loading: false,
       error: "Could not read the PostgreSQL server. Check the connection and permissions."
     )
     |> stream_page()}
  end

  defp filtered_rows(%{overview: nil}), do: []

  defp filtered_rows(assigns) do
    rows =
      if assigns.tab == "databases", do: assigns.overview.databases, else: assigns.overview.roles

    query = String.downcase(assigns.search)
    Enum.filter(rows, &String.contains?(String.downcase(to_string(hd(&1))), query))
  end

  defp stream_page(socket) do
    rows = filtered_rows(socket.assigns)
    pages = max(1, ceil(length(rows) / @page_size))
    page = min(socket.assigns.page, pages)

    items =
      rows
      |> Enum.slice((page - 1) * @page_size, @page_size)
      |> Enum.map(fn row -> %{id: hd(row), values: row} end)

    socket
    |> assign(filtered_count: length(rows), pages: pages, page: page)
    |> stream(:databases, if(socket.assigns.tab == "databases", do: items, else: []), reset: true)
    |> stream(:roles, if(socket.assigns.tab == "roles", do: items, else: []), reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-hero">
      <div>
        <div class="eyebrow"><span class="eyebrow-line"></span> DATABASE WORKSPACE</div>
        <h1>PostgreSQL<span class="heading-dot">.</span></h1>
        <p class="page-subtitle">A clear view of your data. Everything under control.</p>
      </div>
      <.link class="primary-button" navigate={~p"/admin/provision"}><span class="hero-plus"></span> Create database</.link>
    </section>

    <div class="stats-grid">
      <.stat_card icon="hero-circle-stack" label="Database" value={if @overview, do: @databases, else: "—"} hint="On your server" />
      <.stat_card icon="hero-users" label="Roles" value={if @overview, do: @roles, else: "—"} hint="PostgreSQL identities" />
      <.stat_card icon="hero-arrows-right-left" label="Connections" value={if @overview, do: @connections, else: "—"} hint="Current database sessions" />
      <.stat_card icon="hero-key" label="Login roles" value={if @overview, do: @logins, else: "—"} hint="Database access" />
    </div>

    <div class="server-strip">
      <div class="server-strip-icon"><span class="hero-server-stack"></span></div>
      <div class="server-selector"><span class="micro-label">SERVER POSTGRESQL</span>
        <form phx-change="select"><select name="target" aria-label="PostgreSQL server">
          <option :for={{{host, port}, index} <- Enum.with_index(@targets)} value={index} selected={index == @selected}><%= host %>:<%= port %></option>
        </select></form>
      </div>
      <span :if={@overview} class="status-badge"><i class="status-dot"></i>Connected <span class="version-label">v<%= @overview.version %></span></span>
      <span :if={@loading} class="muted small" role="status">Refreshing…</span>
      <button class="quiet-button refresh-button" phx-click="refresh" disabled={@loading} aria-label="Refresh server" title="Refresh server"><span class={["hero-arrow-path", @loading && "is-spinning"]}></span></button>
    </div>
    <p :if={@error} class="notice notice-error" role="alert"><%= @error %></p>

    <section class="data-panel">
      <div class="panel-toolbar">
        <div class="panel-tabs" role="tablist" aria-label="PostgreSQL data">
          <button role="tab" aria-selected={to_string(@tab == "databases")} class={@tab == "databases" && "is-active"} phx-click="tab" phx-value-tab="databases"><span class="hero-circle-stack"></span> Database <span class="count-badge"><%= @databases %></span></button>
          <button role="tab" aria-selected={to_string(@tab == "roles")} class={@tab == "roles" && "is-active"} phx-click="tab" phx-value-tab="roles"><span class="hero-users"></span> Roles <span class="count-badge"><%= @roles %></span></button>
        </div>
        <form class="search-field" phx-change="search" phx-submit="search"><span class="hero-magnifying-glass"></span><input type="search" name="search" value={@search} placeholder={if @tab == "databases", do: "Search databases…", else: "Search roles…"} aria-label="Search PostgreSQL" phx-debounce="180" /></form>
      </div>
      <div :if={@overview == nil and @loading} class="skeleton-list" aria-label="Loading data"><div :for={_ <- 1..5} class="skeleton-row"><span></span><span></span><span></span></div></div>
      <div class="table-scroll" hidden={@overview == nil}>
        <table hidden={@tab != "databases"} class="responsive-table">
          <thead><tr><th>Database name</th><th>Owner</th><th>Size</th><th>Connections</th><th><span class="sr-only">Actions</span></th></tr></thead>
          <tbody id="postgres-databases" phx-update="stream">
            <tr :for={{dom_id, %{values: [name, owner, size, connections]}} <- @streams.databases} id={dom_id}>
              <td class="name-cell"><span class="resource-icon"><span class="hero-circle-stack"></span></span><strong><%= name %></strong></td>
              <td data-label="Owner"><span class="owner-label"><span class="hero-user-circle"></span><%= owner %></span></td>
              <td data-label="Size" class="mono muted"><%= size %></td>
              <td data-label="Connections"><span class={["connection-count", connections > 0 && "has-connections"]}><i></i><%= connections %></span></td>
              <td class="row-actions"><.link navigate={~p"/admin/tenants/new?#{%{db_database: name, db_host: elem(Enum.at(@targets, @selected), 0), db_port: elem(Enum.at(@targets, @selected), 1)}}"} class="row-link" aria-label={"Connect #{name}"}>Connect <span class="hero-arrow-up-right"></span></.link></td>
            </tr>
          </tbody>
        </table>
        <table hidden={@tab != "roles"} class="responsive-table">
          <thead><tr><th>Role name</th><th>Login</th><th>Create database</th><th>Create roles</th><th>Connection limit</th></tr></thead>
          <tbody id="postgres-roles" phx-update="stream">
            <tr :for={{dom_id, %{values: [name, login, createdb, createrole, limit]}} <- @streams.roles} id={dom_id}>
              <td class="name-cell"><span class="resource-icon violet"><span class="hero-user"></span></span><strong><%= name %></strong></td>
              <td data-label="Login"><span class={if login, do: "status-badge", else: "muted"}><%= if login, do: "Enabled", else: "Disabled" %></span></td>
              <td data-label="Create database"><span class={if createdb, do: "permission-yes", else: "muted"}><%= if createdb, do: "Allowed", else: "—" %></span></td>
              <td data-label="Create roles"><span class={if createrole, do: "permission-yes", else: "muted"}><%= if createrole, do: "Allowed", else: "—" %></span></td>
              <td data-label="Connections" class="mono"><%= if limit == -1, do: "Unlimited", else: limit %></td>
            </tr>
          </tbody>
        </table>
        <.empty_state :if={@filtered_count == 0} icon="hero-magnifying-glass" title="No results found" description="Try searching for another name." />
      </div>
      <div class="panel-pagination"><span><strong><%= @filtered_count %></strong> results <span class="pagination-detail">· up to 500 per server</span></span><div><button class="quiet-button" phx-click="page" phx-value-direction="prev" disabled={@page <= 1} aria-label="Previous page"><span class="hero-chevron-left"></span></button><span><%= @page %> <span class="muted">/ <%= @pages %></span></span><button class="quiet-button" phx-click="page" phx-value-direction="next" disabled={@page >= @pages} aria-label="Next page"><span class="hero-chevron-right"></span></button></div></div>
    </section>
    <div class="quick-notes">
      <div><span class="note-icon hero-shield-check"></span><div><strong>Your database overview</strong><p>This view reads your server metadata.</p></div></div>
      <div><span class="note-icon hero-arrows-right-left"></span><div><strong>Ready for pooling</strong><p>Connect a database to a Supavisor tenant.</p></div></div>
      <div><span class="note-icon hero-arrow-path"></span><div><strong>A snapshot of your server</strong><p>Refresh to read the current server state.</p></div></div>
    </div>
    """
  end
end
