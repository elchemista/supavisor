defmodule SupavisorWeb.Admin.DashboardLive do
  use SupavisorWeb, :live_view

  alias Supavisor.Tenants
  alias SupavisorWeb.AdminProvisioning

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       tenants: list_tenants(),
       provisioning_available: AdminProvisioning.available?()
     )}
  end

  @impl true
  def handle_event("delete", %{"external-id" => external_id}, socket) do
    _ = Tenants.delete_tenant_by_external_id(external_id)

    socket =
      socket
      |> put_flash(:info, "Tenant deleted.")
      |> assign(:tenants, list_tenants())

    {:noreply, socket}
  end

  defp list_tenants do
    Tenants.list_tenants()
    |> Enum.sort_by(& &1.external_id)
  end

  defp total_users(tenants) do
    Enum.reduce(tenants, 0, fn tenant, acc -> acc + length(tenant.users || []) end)
  end

  defp auth_mode_counts(tenants) do
    Enum.reduce(tenants, {0, 0}, fn tenant, {stored, query} ->
      if tenant.require_user, do: {stored + 1, query}, else: {stored, query + 1}
    end)
  end

  @impl true
  def render(assigns) do
    {stored, query} = auth_mode_counts(assigns.tenants)

    assigns =
      assigns
      |> assign(:tenant_count, length(assigns.tenants))
      |> assign(:user_total, total_users(assigns.tenants))
      |> assign(:stored_count, stored)
      |> assign(:query_count, query)

    ~H"""
    <div class="page-title-row">
      <div>
        <p class="eyebrow">Connections</p>
        <h1>Tenants</h1>
        <p class="page-subtitle">
          Supavisor connection profiles. This is not a browser for every database inside Postgres.
        </p>
      </div>
      <div class="toolbar-actions">
        <.link :if={@provisioning_available} class="primary-button" navigate={~p"/admin/provision"}>
          <span class="hero-circle-stack-mini"></span>
          Provision database
        </.link>
        <.link class="secondary-button" navigate={~p"/admin/tenants/new"}>
          <span class="hero-plus-mini"></span>
          New tenant
        </.link>
      </div>
    </div>

    <.notice :if={@flash["info"]}><%= @flash["info"] %></.notice>
    <.notice :if={@flash["error"]} kind="error"><%= @flash["error"] %></.notice>

    <div class="stats-grid">
      <.stat_card
        icon="hero-rectangle-stack-mini"
        label="Tenants"
        value={@tenant_count}
        hint="Supavisor connection profiles"
      />
      <.stat_card
        icon="hero-users-mini"
        label="Database users"
        value={@user_total}
        hint="Across all tenants"
      />
      <.stat_card
        icon="hero-key-mini"
        label="Stored users"
        value={@stored_count}
        hint="Authenticated from Supavisor"
      />
      <.stat_card
        icon="hero-command-line-mini"
        label="Auth query"
        value={@query_count}
        hint="Delegated to Postgres"
      />
    </div>

    <section :if={@tenants == []} class="table-panel">
      <.empty_state
        icon="hero-rectangle-stack"
        title="No tenants yet"
        description="Create your first Supavisor connection profile to start routing traffic."
      >
        <:action>
          <.link :if={@provisioning_available} class="primary-button" navigate={~p"/admin/provision"}>
            <span class="hero-circle-stack-mini"></span>
            Provision database
          </.link>
          <.link class="secondary-button" navigate={~p"/admin/tenants/new"}>
            <span class="hero-plus-mini"></span>
            New tenant
          </.link>
        </:action>
      </.empty_state>
    </section>

    <section :if={@tenants != []} class="table-panel">
      <table>
        <thead>
          <tr>
            <th>External ID</th>
            <th>Upstream Postgres</th>
            <th>Auth</th>
            <th class="num">Users</th>
            <th class="num">Pool</th>
            <th class="actions-col"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={tenant <- @tenants}>
            <td>
              <strong><%= tenant.external_id %></strong>
              <small :if={tenant.sni_hostname}><%= tenant.sni_hostname %></small>
            </td>
            <td class="mono">
              <%= tenant.db_host %>:<%= tenant.db_port %>/<%= tenant.db_database %>
            </td>
            <td>
              <.badge
                variant="outline"
                icon={if tenant.require_user, do: "hero-key-mini", else: "hero-command-line-mini"}
              >
                <%= if tenant.require_user, do: "stored users", else: "auth query" %>
              </.badge>
            </td>
            <td class="num"><%= length(tenant.users || []) %></td>
            <td class="num"><%= tenant.default_pool_size %></td>
            <td class="actions">
              <.icon_button
                navigate={~p"/admin/tenants/#{tenant.external_id}/edit"}
                label="Edit tenant"
                icon="hero-pencil-square-mini"
              />
              <.icon_button
                variant="danger"
                label="Delete tenant"
                icon="hero-trash-mini"
                phx-click="delete"
                phx-value-external-id={tenant.external_id}
                data-confirm={"Delete tenant #{tenant.external_id}?"}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end
