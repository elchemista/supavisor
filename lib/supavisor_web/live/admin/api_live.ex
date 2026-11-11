defmodule SupavisorWeb.Admin.ApiLive do
  use SupavisorWeb, :live_view
  alias Supavisor.MCP.{Auth, Tools}
  alias SupavisorWeb.Admin.DatabaseUI, as: UI
  alias SupavisorWeb.MCPOrigin

  @impl true
  def mount(_, _, socket) do
    {:ok, socket |> assign(:endpoint, Auth.resource()) |> load()}
  end

  @impl true
  def handle_params(_, uri, socket) do
    {:noreply, assign(socket, :endpoint, Auth.resource(MCPOrigin.from_uri(uri)))}
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    case Auth.revoke_grant(id, socket.assigns.current_admin_email) do
      :ok ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Connection revoked. Its access and refresh tokens no longer work.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not revoke this connection.")}
    end
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    assign(socket,
      grants: Auth.list_grants(socket.assigns.current_admin_email),
      tools: Tools.list(%{scopes: Auth.scopes()}),
      scopes: Auth.scopes()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mcp-settings">
      <UI.header title="MCP database access" subtitle="Connect AI clients to PostgreSQL with permissions you control.">
        <:actions><button type="button" class="secondary-button" phx-click="refresh">Refresh connections</button></:actions>
      </UI.header>
      <section class="form-section">
        <div class="form-section-heading"><span class="step-marker"><span class="hero-link"></span></span><div><h2>Connect a client</h2><p>Add this remote MCP server in your client and choose OAuth authentication.</p></div></div>
        <div class="api-endpoint mono" id="mcp-endpoint">{@endpoint}</div>
        <button type="button" class="secondary-button" data-copy-target="#mcp-endpoint"><span class="hero-clipboard-document"></span>Copy MCP URL</button>
        <p class="copy-feedback" data-copy-feedback role="status"></p>
        <ol class="setup-steps">
          <li>In a client such as ChatGPT or Claude, add the MCP server URL above.</li>
          <li>Sign in to this console when the client opens the authorization page.</li>
          <li>Choose the databases and permissions, then allow access. Reading is selected by default; creation and migrations require your selection.</li>
        </ol>
        <details>
          <summary class="advanced-summary">Client ID and secret (only if requested)</summary>
          <p class="field-help">Most clients discover authorization automatically from this URL. If your client asks for a Client ID and Secret, register it with POST /oauth/register using its exact callback URL. The server supports public clients and client_secret_post/client_secret_basic.</p>
        </details>
      </section>
      <section class="form-section">
        <div class="section-heading"><h2>Your authorized connections</h2></div>
        <div class="service-table-wrap">
          <table class="service-table">
            <thead><tr><th>Client</th><th>Permissions</th><th>Databases</th><th>Access expires</th><th></th></tr></thead>
            <tbody id="mcp-grants">
              <tr :for={grant <- @grants} id={"mcp-grant-#{grant.id}"}>
                <td><strong>{grant.client_name}</strong><span class="table-subline">Authorized {UI.time(grant.inserted_at)}</span></td>
                <td><div class="scope-list"><code :for={scope <- grant.scopes}>{scope}</code></div></td>
                <td>{if "*" in grant.tenant_ids, do: "All current and future databases", else: Enum.join(grant.tenant_ids, ", ")}</td>
                <td>{UI.time(grant.expires_at)}</td>
                <td><button type="button" class="text-button error-text" phx-click="revoke" phx-value-id={grant.id} data-confirm="Revoke this client's database access?">Revoke</button></td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@grants == []} class="table-empty">No authorized connections yet.</p>
        <p class="field-help">Access tokens expire after one hour. Rotating refresh tokens keep approved connections available for up to 30 days. Revocation also invalidates refresh tokens.</p>
      </section>
      <section class="form-section">
        <div class="section-heading"><h2>Database tools</h2></div>
        <div class="service-table-wrap"><table class="service-table">
          <thead><tr><th>Tool</th><th>Behavior</th></tr></thead>
          <tbody><tr :for={tool <- @tools}><td><code>{tool.name}</code></td><td>{tool.description}</td></tr></tbody>
        </table></div>
        <p class="field-help">New databases use your configured provisioning targets. Reads and migrations connect with each tenant's stored role. Migration history records successful SQL changes, checksums, time and administrator in that database.</p>
      </section>
    </div>
    """
  end
end
