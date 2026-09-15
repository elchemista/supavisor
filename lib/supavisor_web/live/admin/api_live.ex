defmodule SupavisorWeb.Admin.ApiLive do
  use SupavisorWeb, :live_view
  alias Supavisor.ServiceAPI.{Credential, Gateway}
  alias SupavisorWeb.AdminAuth

  @impl true
  def mount(_, session, socket) do
    if connected?(socket) do
      Gateway.subscribe()
      Process.send_after(self(), :check_session, 60_000)
    end

    {:ok,
     socket
     |> assign(
       api_session: session,
       client_ids: MapSet.new(),
       activity_ids: MapSet.new(),
       new_token: nil,
       secret_timer: nil,
       gateway: nil,
       endpoint: ""
     )
     |> stream(:clients, [])
     |> stream(:activity, [])
     |> load_snapshot()}
  end

  @impl true
  def handle_params(_, uri, socket) do
    endpoint =
      URI.parse(uri)
      |> Map.put(:scheme, if(String.starts_with?(uri, "https:"), do: "wss", else: "ws"))
      |> Map.put(:path, "/services/socket/websocket")
      |> Map.put(:query, nil)
      |> Map.put(:fragment, nil)
      |> URI.to_string()

    {:noreply, assign(socket, :endpoint, endpoint)}
  end

  @impl true
  def handle_event("generate_token", _, socket),
    do: save_token(Credential.generate(), socket, true)

  def handle_event("save_token", %{"api_token" => token}, socket),
    do: save_token(token, socket, false)

  def handle_event("revoke_token", _, socket), do: save_token(nil, socket, false)
  def handle_event("hide_token", _, socket), do: {:noreply, clear_secret(socket)}

  defp save_token(token, socket, reveal?) do
    case Gateway.configure(token, socket.assigns.current_admin_email) do
      :ok ->
        socket = socket |> clear_secret() |> load_snapshot() |> push_event("clear-api-token", %{})

        socket =
          if reveal? do
            ref = make_ref()
            timer = Process.send_after(self(), {:hide_secret, ref}, 120_000)
            assign(socket, new_token: token, secret_timer: {timer, ref})
          else
            socket
          end

        message =
          if token,
            do:
              "API token saved. Clients can authenticate now. Previous connections were closed.",
            else: "API token revoked. Service clients can no longer authenticate."

        {:noreply, put_flash(socket, :info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  catch
    :exit, _ ->
      {:noreply, put_flash(socket, :error, "The gateway is restarting. Please try again.")}
  end

  @impl true
  def handle_info(:service_api_updated, socket) do
    with_session(socket, &load_snapshot/1)
  end

  def handle_info(:check_session, socket) do
    Process.send_after(self(), :check_session, 60_000)
    with_session(socket, &load_snapshot/1)
  end

  def handle_info({:hide_secret, ref}, %{assigns: %{secret_timer: {_, ref}}} = socket),
    do: {:noreply, clear_secret(socket)}

  def handle_info({:hide_secret, _}, socket), do: {:noreply, socket}

  defp with_session(socket, fun) do
    case AdminAuth.authenticate_session(socket.assigns.api_session) do
      {:ok, _} -> {:noreply, fun.(socket)}
      :error -> {:noreply, socket |> clear_secret() |> redirect(to: ~p"/admin/login")}
    end
  end

  defp clear_secret(socket) do
    if socket.assigns.secret_timer, do: Process.cancel_timer(elem(socket.assigns.secret_timer, 0))
    assign(socket, new_token: nil, secret_timer: nil)
  end

  defp load_snapshot(socket) do
    case Gateway.snapshot() do
      nil ->
        assign(socket, :gateway, nil)

      snapshot ->
        socket
        |> assign(:gateway, Map.drop(snapshot, [:clients, :activity]))
        |> sync_stream(:clients, :client_ids, snapshot.clients)
        |> sync_stream(:activity, :activity_ids, snapshot.activity)
    end
  end

  defp sync_stream(socket, stream_name, ids_key, rows) do
    previous = socket.assigns[ids_key]
    current = MapSet.new(rows, & &1.id)

    socket =
      Enum.reduce(MapSet.difference(previous, current), socket, fn id, acc ->
        stream_delete(acc, stream_name, %{id: id})
      end)

    socket =
      rows
      |> Enum.reverse()
      |> Enum.reduce(socket, fn row, acc ->
        if MapSet.member?(previous, row.id),
          do: acc,
          else: stream_insert(acc, stream_name, row, at: 0)
      end)

    assign(socket, ids_key, current)
  end

  defp clock(datetime), do: Calendar.strftime(datetime, "%H:%M:%S UTC")

  defp client_example(endpoint) do
    socket_url = String.replace_suffix(endpoint, "/websocket", "")

    """
    import {Socket} from "phoenix"

    const socket = new Socket("#{socket_url}")
    const channel = socket.channel("services:gateway", {token: API_TOKEN})

    channel.on("authorization:revoked", () => socket.disconnect())
    channel.join()
      .receive("ok", reply => {
        console.log(reply.status)
        channel.push("gateway:status", {})
          .receive("ok", status => console.log(status))
      })
      .receive("error", reply => console.error(reply.code))
    socket.connect()
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="service-api" phx-hook="ServiceAPI">
      <section class="page-hero">
        <div><div class="eyebrow"><span class="eyebrow-line"></span> THE CONNECTION TO YOUR SERVICES</div><h1>API<span class="heading-dot">.</span></h1><p class="page-subtitle">An always-available WebSocket endpoint. One token for your service clients.</p></div>
        <span class="protocol-badge">↔ WebSocket</span>
      </section>
      <div :if={@gateway == nil} class="notice" role="status">The service gateway is starting. Reload this page in a moment.</div>
      <div :if={@gateway}>
        <div class="gateway-status-strip">
          <span class="gateway-signal"><span class="hero-signal"></span></span>
          <div><strong>Service gateway</strong><span>Endpoint available · Phoenix Channels</span></div>
          <span class="status-badge gateway-live-indicator"><i class="status-dot"></i>Live monitoring</span>
          <span class="status-badge pending gateway-offline-indicator">Reconnecting monitor…</span>
        </div>
        <div class="stats-grid gateway-stats">
          <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-link"></span></span><span class="stat-label">Connected clients</span></div><div class="stat-value"><%= @gateway.connected %></div><div class="stat-hint">Authenticated · up to <%= @gateway.max_clients %> clients</div></article>
          <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-queue-list"></span></span><span class="stat-label">Queue</span></div><div class="stat-value">—</div><div class="stat-hint">Processing not implemented yet</div></article>
          <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-bolt"></span></span><span class="stat-label">In progress</span></div><div class="stat-value">—</div><div class="stat-hint">No service handlers connected</div></article>
          <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-shield-check"></span></span><span class="stat-label">Authorization</span></div><div class="stat-value gateway-word-value"><%= if @gateway.ready, do: "Protected", else: "Locked" %></div><div class="stat-hint"><%= if @gateway.ready, do: "Service token required", else: "Create a token to allow clients" %></div></article>
        </div>
        <div class="gateway-settings-grid">
          <section class="form-section gateway-token-panel">
            <div class="form-section-heading"><span class="step-marker"><span class="hero-key"></span></span><div><h2>Access token</h2><p>Authorize applications that use your services.</p></div></div>
            <div class="gateway-token-state"><span class={["status-badge", !@gateway.ready && "pending"]}><i class="status-dot"></i><%= if @gateway.ready, do: "Token configured", else: "No active token" %></span><code :if={@gateway.fingerprint}>SHA-256 · <%= @gateway.fingerprint %></code></div>
            <p :if={@gateway.token_updated_at} class="field-help">Updated <%= Calendar.strftime(@gateway.token_updated_at, "%d %b %Y, %H:%M UTC") %></p>
            <div class="form-actions"><button type="button" class="primary-button" phx-click="generate_token" phx-disable-with="Generating…"><span class="hero-arrow-path"></span><%= if @gateway.ready, do: "Replace token", else: "Generate token" %></button><button :if={@gateway.ready} type="button" class="danger-button" phx-click="revoke_token" phx-disable-with="Revoking…">Revoke</button></div>
            <div :if={@new_token} class="gateway-new-token" role="status">
              <strong>Your new token is ready</strong><p>Copy it now. It is hidden after two minutes and cannot be recovered.</p>
              <label class="field"><span>Generated API token</span><input id="generated-api-token" type="password" value={@new_token} readonly autocomplete="off" spellcheck="false" /></label>
              <div class="form-actions"><button class="secondary-button" type="button" data-copy-target="#generated-api-token"><span class="hero-clipboard-document"></span>Copy token</button><button class="quiet-text-button" type="button" phx-click="hide_token">Done</button></div>
            </div>
            <details class="gateway-custom-token"><summary>Use your own token <span class="hero-chevron-down"></span></summary><form phx-submit="save_token" id="service-token-form"><.input type="password" name="api_token" value="" label="API token" autocomplete="new-password" minlength="32" maxlength="128" required placeholder="Paste a strong, random token" /><p class="field-help">32–128 letters, numbers, underscores or hyphens.</p><button type="submit" class="secondary-button" phx-disable-with="Saving…">Save token</button></form></details>
            <p class="service-note"><span class="hero-lock-closed"></span>Only the token hash is stored. Replacing or revoking it closes existing service connections.</p>
          </section>
          <section class="form-section gateway-endpoint-panel">
            <div class="form-section-heading"><span class="step-marker"><span class="hero-code-bracket"></span></span><div><h2>Connection details</h2><p>Use this endpoint from your application.</p></div></div>
            <label class="field"><span>WebSocket URL</span><input id="service-endpoint" class="mono" type="text" value={@endpoint} readonly /></label>
            <button class="secondary-button gateway-copy-endpoint" type="button" data-copy-target="#service-endpoint"><span class="hero-clipboard-document"></span>Copy endpoint</button>
            <dl class="config-list"><div><dt>Channel</dt><dd>services:gateway</dd></div><div><dt>Authentication</dt><dd>Token in channel join</dd></div><div><dt>Transport</dt><dd>WebSocket · JSON</dd></div><div><dt>Reconnect</dt><dd>Automatic with Phoenix client</dd></div></dl>
            <div class="gateway-scope"><span class="hero-server-stack"></span><p>PostgreSQL keeps its existing REST API and credentials. This token is for Mailer, Embedding, AI model, STT and TTS.</p></div>
          </section>
        </div>
        <p class="gateway-copy-feedback" data-copy-feedback role="status" phx-update="ignore" id="api-copy-feedback"></p>
        <div class="gateway-monitor-grid">
          <section class="data-panel">
            <div class="metrics-panel-heading"><div><h2>Live connections</h2><p>Authenticated service clients on this server</p></div><span class="count-badge"><%= @gateway.connected %></span></div>
            <div class="gateway-client-list" id="service-clients" phx-update="stream"><div class="gateway-list-empty" id="clients-empty"><span class="hero-link"></span><strong>Waiting for your application</strong><p>Clients appear here after joining with a valid token.</p></div><div :for={{id, client} <- @streams.clients} id={id} class="gateway-client"><span class="status-dot"></span><div><code><%= client.id %></code><span>Connected <%= clock(client.connected_at) %></span></div><span class="status-badge">Authorized</span></div></div>
          </section>
          <section class="data-panel">
            <div class="metrics-panel-heading"><div><h2>Connection activity</h2><p>Last 30 events · held in memory</p></div><span class="hero-clock muted"></span></div>
            <div class="gateway-activity-list" id="service-activity" phx-update="stream"><div class="gateway-list-empty" id="activity-empty"><span class="hero-signal"></span><strong>No activity yet</strong><p>Connection events will appear automatically.</p></div><div :for={{id, event} <- @streams.activity} id={id} class="gateway-activity"><span class={if event.event == "connected", do: "hero-arrow-right-end-on-rectangle", else: "hero-arrow-right-start-on-rectangle"}></span><div><strong>Client <%= event.event %></strong><code><%= String.slice(event.client_id, 0, 8) %></code></div><time><%= clock(event.at) %></time></div></div>
          </section>
        </div>
        <section class="gateway-services data-panel"><div class="metrics-panel-heading"><div><h2>Service processing</h2><p>Connection and authorization are ready. You can implement the service handlers next.</p></div><span class="status-badge pending">Not implemented</span></div><div class="gateway-service-tags"><span :for={label <- ["Mailer", "Embedding", "AI model", "STT", "TTS"]}><%= label %></span></div><p>Submissions currently return <code>service_not_implemented</code>. No jobs are accepted, queued or marked as completed.</p></section>
        <details class="data-panel gateway-example"><summary><span class="hero-code-bracket"></span>Client connection example<span class="hero-chevron-down"></span></summary><div><p>Use the <code>phoenix</code> JavaScript client. Keep the token in your application's secret configuration.</p><pre><code><%= client_example(@endpoint) %></code></pre><p>The client keeps the connection alive and reconnects after network interruptions. A replaced token must be updated in the client configuration. Request handlers are not available yet.</p></div></details>
      </div>
    </div>
    """
  end
end
