defmodule SupavisorWeb.Admin.ApiLive do
  use SupavisorWeb, :live_view
  alias Supavisor.ServiceAPI.{AccessKey, Gateway}
  alias Supavisor.Services.{Embeddings, Mail, MailWorker}
  alias SupavisorWeb.Admin.ServiceUI, as: UI

  @impl true
  def mount(_, session, socket) do
    UI.subscribe(socket)
    if connected?(socket), do: Gateway.subscribe()

    {:ok,
     socket
     |> assign(
       service_session: session,
       tab: "keys",
       creating: false,
       new_token: nil,
       dirty: false,
       secret_timer: nil,
       base_url: "",
       ws_url: "",
       errors: %{},
       form: %{},
       gateway: Gateway.snapshot()
     )
     |> stream(:keys, [])
     |> stream(:clients, [])
     |> stream(:activity, [])
     |> load()}
  end

  @impl true
  def handle_params(_, uri, socket) do
    base = URI.parse(uri) |> Map.put(:path, "") |> Map.put(:query, nil) |> Map.put(:fragment, nil)

    ws = %{
      base
      | scheme: if(base.scheme == "https", do: "wss", else: "ws"),
        path: "/services/socket"
    }

    {:noreply, assign(socket, base_url: URI.to_string(base), ws_url: URI.to_string(ws))}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["keys", "connections", "usage"],
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("new_key", _, socket),
    do: {:noreply, assign(socket, creating: !socket.assigns.creating, errors: %{}, form: %{})}

  def handle_event("create_key", %{"key" => params}, socket) do
    days =
      case params["lifetime"] do
        "7" -> 7
        "90" -> 90
        "never" -> nil
        _ -> 30
      end

    params =
      params
      |> Map.put_new("scopes", [])
      |> Map.put_new("transports", [])
      |> Map.put_new("mailbox_ids", [])
      |> Map.put(
        "expires_at",
        if(days, do: DateTime.add(DateTime.utc_now(), days * 86_400, :second))
      )

    case AccessKey.create(params, socket.assigns.current_admin_email) do
      {:ok, _key, token} ->
        socket = clear_secret(socket)
        ref = make_ref()
        timer = Process.send_after(self(), {:hide_secret, ref}, 120_000)

        {:noreply,
         socket
         |> assign(
           new_token: token,
           creating: false,
           form: %{},
           errors: %{},
           secret_timer: {timer, ref}
         )
         |> load()
         |> push_event("clear-api-token", %{})
         |> put_flash(:info, "API key created. Copy the token now; it is shown only once.")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(form: Map.delete(params, "token"), errors: UI.form_errors(error))
         |> put_flash(:error, UI.changeset_message(error))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case AccessKey.revoke(id, socket.assigns.current_admin_email) do
      :ok ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Key revoked. Clients using it lose access immediately.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error)}
    end
  end

  def handle_event("delete_key", %{"id" => id}, socket) do
    case AccessKey.delete(id, socket.assigns.current_admin_email) do
      :ok -> {:noreply, load(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, error)}
    end
  end

  def handle_event("hide_token", _, socket), do: {:noreply, clear_secret(socket)}

  @impl true
  def handle_info(event, socket) when event in [:services_changed, :service_api_updated],
    do: {:noreply, assign(socket, :dirty, true)}

  def handle_info(:service_tick, socket) do
    Process.send_after(self(), :service_tick, 1000)

    case UI.check_session(socket) do
      {:ok, _} -> {:noreply, if(socket.assigns.dirty, do: load(socket), else: socket)}
      _ -> {:noreply, socket |> clear_secret() |> redirect(to: ~p"/admin/login")}
    end
  end

  def handle_info({:hide_secret, ref}, %{assigns: %{secret_timer: {_, ref}}} = socket),
    do: {:noreply, clear_secret(socket)}

  def handle_info({:hide_secret, _}, socket), do: {:noreply, socket}

  defp clear_secret(socket) do
    if socket.assigns.secret_timer, do: Process.cancel_timer(elem(socket.assigns.secret_timer, 0))
    assign(socket, new_token: nil, secret_timer: nil)
  end

  defp load(socket) do
    keys = Enum.map(AccessKey.list(), &Map.put(&1, :status, key_status(&1)))
    gateway = Gateway.snapshot()
    embeddings = Embeddings.snapshot()
    mail = MailWorker.snapshot()
    inference = Supavisor.Services.Inference.snapshot()

    socket
    |> assign(
      keys_count: length(keys),
      active_keys:
        Enum.count(keys, &(is_nil(&1.revoked_at) && Supavisor.ServiceAPI.KeyCache.valid?(&1))),
      gateway: gateway,
      queue_count:
        inference.queued + embeddings.queued + Map.get(mail, :queued, 0) +
          Map.get(mail, :webhook_queued, 0),
      running_count:
        if(inference.running, do: 1, else: 0) + if(embeddings.running, do: 1, else: 0) +
          Map.get(mail, :sending, 0) +
          Map.get(mail, :webhook_sending, 0),
      mailboxes: Mail.mailboxes(),
      dirty: false
    )
    |> UI.sync_stream(:keys, keys)
    |> UI.sync_stream(:clients, gateway.clients)
    |> UI.sync_stream(:activity, gateway.activity)
  end

  defp key_status(key) do
    cond do
      not is_nil(key.revoked_at) -> "revoked"
      !Supavisor.ServiceAPI.KeyCache.valid?(key) -> "expired"
      true -> "active"
    end
  end

  defp example(assigns) do
    "import {Socket} from 'phoenix'\n\nconst socket = new Socket('#{assigns.ws_url}')\nconst channel = socket.channel('services:gateway', {token: API_TOKEN})\n\nchannel.on('authorization:revoked', () => socket.disconnect())\nchannel.on('request:update', job => console.log(job))\nchannel.join().receive('ok', () => {\n  channel.push('models:list', {}).receive('ok', console.log)\n})\nsocket.connect()"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="service-api" phx-hook="ServiceAPI">
      <UI.header
        title="API"
        subtitle="One service layer. REST and WebSocket, with shared permissions and request IDs."
      >
        <:actions>
          <button class="primary-button" phx-click="new_key">
            <span class="hero-plus"></span>New API key
          </button>
        </:actions>
      </UI.header>
      <div class="summary-line">
        <div><span>Active keys</span><strong><%= @active_keys %></strong></div>
        <div><span>WebSocket clients</span><strong><%= @gateway.connected %></strong></div>
        <div><span>Queued requests</span><strong><%= @queue_count %></strong></div>
        <div><span>Processing</span><strong><%= @running_count %></strong></div>
      </div>
      <div :if={@new_token} class="token-reveal">
        <div>
          <strong>Copy your new token</strong>
          <p>Hidden after two minutes. Only its hash is stored.</p>
        </div>
        <input
          id="generated-api-token"
          type="password"
          value={@new_token}
          readonly
          aria-label="New API token"
          autocomplete="off"
        />
        <button type="button" class="secondary-button" data-copy-target="#generated-api-token">
          Copy token
        </button>
        <button type="button" class="text-button" phx-click="hide_token">Done</button>
      </div>
      <section :if={@creating} class="inline-editor">
        <div class="section-heading">
          <h2>Create API key</h2>
          <button class="icon-button" phx-click="new_key" aria-label="Close new key form">
            <span class="hero-x-mark"></span>
          </button>
        </div>
        <form phx-submit="create_key" id="api-key-form">
          <div class="editor-grid">
            <.input
              name="key[name]"
              value={@form["name"] || ""}
              label="Name"
              placeholder="e.g. Production backend"
              required
              maxlength="80"
              errors={Map.get(@errors, :name, [])}
            /><.input
              type="select"
              name="key[lifetime]"
              value="30"
              label="Expires in"
              options={[{"7 days", "7"}, {"30 days", "30"}, {"90 days", "90"}, {"Never", "never"}]}
            />
          </div>
          <.input
            type="password"
            name="key[token]"
            value=""
            label="Custom token (optional)"
            placeholder="Leave blank to generate a secure token"
            autocomplete="new-password"
            minlength="32"
            maxlength="128"
          />
          <div class="editor-grid">
            <fieldset class="permission-fieldset">
              <legend>Permissions</legend>
              <label :for={scope <- AccessKey.scopes()}>
                <input
                  type="checkbox"
                  name="key[scopes][]"
                  value={scope}
                  checked={scope in Map.get(@form, "scopes", AccessKey.scopes())}
                /><code>{scope}</code>
              </label>
            </fieldset>
            <fieldset class="permission-fieldset">
              <legend>Transports</legend>
              <label>
                <input type="checkbox" name="key[transports][]" value="rest" checked />REST
              </label>
              <label><input
                type="checkbox"
                name="key[transports][]"
                value="websocket"
                checked
              />WebSocket</label>
            </fieldset>
          </div>
          <label class="field">
            <span>Restrict to mailboxes (optional)</span><select
              multiple
              name="key[mailbox_ids][]"
              size="3"
            ><option :for={box <- @mailboxes} value={box.id}><%= box.address %></option></select>
          </label>
          <p class="field-help">
            No selection grants access to all workspace mailboxes allowed by the selected permissions.
          </p>
          <div class="form-actions">
            <button class="primary-button" phx-disable-with="Creating…">Create key</button><button
              type="button"
              class="secondary-button"
              phx-click="new_key"
            >Cancel</button>
          </div>
        </form>
      </section>
      <p
        id="api-copy-feedback"
        class="copy-feedback"
        data-copy-feedback
        role="status"
        phx-update="ignore"
      >
      </p>
      <UI.tabs
        tabs={[
          {"keys", "Access keys"},
          {"connections", "Live connections"},
          {"usage", "Endpoints & examples"}
        ]}
        active={@tab}
      />
      <section hidden={@tab != "keys"}>
        <div class="service-table-wrap">
          <table class="service-table">
            <thead>
              <tr>
                <th>Name / fingerprint</th>
                <th>Permissions</th>
                <th>Transports</th>
                <th>Expires</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="api-keys" phx-update="stream">
              <tr :for={{id, key} <- @streams.keys} id={id}>
                <td>
                  <strong>{key.name}</strong><span class="table-subline mono"><%= key.fingerprint %></span>
                </td>
                <td>
                  <div class="scope-list"><code :for={scope <- key.scopes}>{scope}</code></div>
                  <span :if={key.mailbox_ids != []} class="table-subline">
                    {length(key.mailbox_ids)} selected mailboxes
                  </span>
                </td>
                <td>{Enum.join(key.transports, " · ")}</td>
                <td class="small">{if key.expires_at, do: UI.time(key.expires_at), else: "Never"}</td>
                <td><span class={UI.status_class(key.status)}>{key.status}</span></td>
                <td>
                  <button
                    :if={is_nil(key.revoked_at)}
                    class="text-button error-text"
                    phx-click="revoke"
                    phx-value-id={key.id}
                  >
                    Revoke
                  </button>
                  <button
                    :if={key.revoked_at}
                    class="text-button"
                    phx-click="delete_key"
                    phx-value-id={key.id}
                  >Remove</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@keys_count == 0} class="table-empty">
          <strong>No API keys yet</strong>
          <p>Create a key for your application and choose its permissions.</p>
        </div>
        <p class="workspace-footnote">
          120 application requests per minute per key, shared across REST and WebSocket. Revocation closes the key’s connections and prevents new work. PostgreSQL keeps its existing REST API credentials.
        </p>
      </section>
      <section hidden={@tab != "connections"}>
        <div class="service-table-wrap">
          <table class="service-table">
            <thead>
              <tr>
                <th>Connection</th>
                <th>API key</th>
                <th>Connected since</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody id="api-clients" phx-update="stream">
              <tr :for={{id, client} <- @streams.clients} id={id}>
                <td class="mono">{client.id}</td>
                <td>{client.key_name}</td>
                <td>{UI.time(client.connected_at)}</td>
                <td><span class="state-label state-success">Connected</span></td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@gateway.connected == 0} class="table-empty">
          No authenticated clients connected. The WebSocket endpoint remains available.
        </p>
        <h2 class="section-heading">Recent connection activity</h2>
        <div id="api-activity" phx-update="stream" class="activity-timeline">
          <div :for={{id, event} <- @streams.activity} id={id}>
            <time>{UI.time(event.at)}</time><span><%= event.key_name %> · <%= event.event %></span><code><%= UI.short(event.client_id) %></code>
          </div>
        </div>
      </section>
      <section hidden={@tab != "usage"}>
        <div class="endpoint-line">
          <span class="method-label">REST</span><code id="rest-endpoint"><%= @base_url %>/api/services/v1</code><button
            class="icon-button"
            data-copy-target="#rest-endpoint"
            aria-label="Copy REST endpoint"
          ><span class="hero-clipboard-document"></span></button>
        </div>
        <div class="endpoint-line">
          <span class="method-label">WS</span><code id="ws-endpoint"><%= @ws_url %>/websocket</code><button
            class="icon-button"
            data-copy-target="#ws-endpoint"
            aria-label="Copy WebSocket endpoint"
          ><span class="hero-clipboard-document"></span></button>
        </div>
        <div class="service-table-wrap">
          <table class="service-table">
            <thead>
              <tr>
                <th>REST</th>
                <th>WebSocket event</th>
                <th>Permission</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>GET /status</td>
                <td><code>gateway:status</code></td>
                <td>Valid key</td>
              </tr>
              <tr>
                <td>GET /models</td>
                <td><code>models:list</code></td>
                <td>embedding:read</td>
              </tr>
              <tr>
                <td>POST /embeddings</td>
                <td><code>embedding:run</code></td>
                <td>embedding:run</td>
              </tr>
              <tr :for={service <- ["tts", "stt", "ai"]}>
                <td>POST /{service}</td><td><code>{service}:run</code></td><td>{service}:run</td>
              </tr>
              <tr><td>POST /audio</td><td><code>audio:upload:start / chunk / finish</code></td><td>stt:run</td></tr>
              <tr><td>GET /audio/:id</td><td>Authenticated HTTP download</td><td>File owner + service permission</td></tr>
              <tr>
                <td>POST /mail/send</td>
                <td><code>mail:send</code></td>
                <td>mail:send</td>
              </tr>
              <tr>
                <td>GET /mailboxes</td>
                <td><code>mailboxes:list</code></td>
                <td>mail:read</td>
              </tr>
              <tr>
                <td>GET /mail/messages</td>
                <td><code>mail:list</code></td>
                <td>mail:read</td>
              </tr>
              <tr>
                <td>GET /mail/messages/:id</td>
                <td><code>mail:get</code></td>
                <td>mail:read</td>
              </tr>
              <tr>
                <td>GET /requests/:id</td>
                <td><code>request:get</code></td>
                <td>Request owner</td>
              </tr>
              <tr>
                <td>POST /requests/:id/cancel</td>
                <td><code>request:cancel</code></td>
                <td>Request owner · queued only</td>
              </tr>
            </tbody>
          </table>
        </div>
        <section class="inline-section">
          <h2>Connect once, receive live updates</h2>
          <p class="muted">
            REST uses <code>Authorization: Bearer YOUR_API_TOKEN</code>. WebSocket authenticates the channel join; keep tokens out of URLs.
          </p>
          <pre class="code-sample"><code><%= example(assigns) %></code></pre>
          <p class="workspace-footnote">
            POST requests return HTTP 202 and a request ID. WebSocket clients receive <code>request:update</code>; use
            <code>request:get</code>
            to retrieve the result. Embedding results expire after five minutes and are local to this server. Send an
            <code>Idempotency-Key</code>
            header for outgoing email, or <code>idempotency_key</code>
            over WebSocket.
          </p>
        </section>
      </section>
    </div>
    """
  end
end
