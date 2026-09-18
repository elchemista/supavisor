defmodule SupavisorWeb.Admin.MailerLive do
  use SupavisorWeb, :live_view
  alias Phoenix.LiveView.JS
  alias Supavisor.Services.{Mail, Mailbox, MailDelivery, MailWorker, InboundServer}
  alias SupavisorWeb.Admin.ServiceUI, as: UI

  @box_fields ~w(name address hostname enabled delivery_mode dkim_enabled dkim_selector webhook_enabled webhook_url)a

  @impl true
  def mount(_, session, socket) do
    UI.subscribe(socket)

    {:ok,
     socket
     |> assign(
       service_session: session,
       dirty: false,
       tab: "inbox",
       search: "",
       mailbox_filter: "",
       page: 1,
       editing: false,
       editing_id: nil,
       form: %{},
       errors: %{},
       composing: false,
       compose: %{},
       selected: nil,
       dns: nil,
       dns_loading: false,
       base_url: "",
       ws_url: ""
     )
     |> stream(:messages, [])
     |> stream(:mailboxes, [])
     |> load()}
  end

  @impl true
  def handle_params(_, uri, socket) do
    base = URI.parse(uri) |> Map.put(:path, "") |> Map.put(:query, nil) |> Map.put(:fragment, nil)

    {:noreply,
     assign(socket,
       base_url: URI.to_string(base),
       ws_url:
         URI.to_string(%{
           base
           | scheme: if(base.scheme == "https", do: "wss", else: "ws"),
             path: "/services/socket"
         })
     )}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket)
      when tab in ["inbox", "outbox", "queue", "mailboxes", "examples"],
      do: {:noreply, socket |> assign(tab: tab, page: 1, selected: nil) |> load()}

  def handle_event("filter", params, socket),
    do:
      {:noreply,
       socket
       |> assign(
         search: params["search"] || "",
         mailbox_filter: params["mailbox_id"] || "",
         page: 1
       )
       |> load()}

  def handle_event("page", %{"direction" => direction}, socket),
    do:
      {:noreply,
       socket
       |> assign(:page, max(1, socket.assigns.page + if(direction == "next", do: 1, else: -1)))
       |> load()}

  def handle_event("new_mailbox", _, socket),
    do:
      {:noreply,
       assign(socket,
         editing: true,
         editing_id: nil,
         form: box_form(%Mailbox{}),
         errors: %{},
         composing: false,
         dns: nil
       )}

  def handle_event("edit_mailbox", %{"id" => id}, socket) do
    case Mail.mailbox(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Mailbox not found.")}

      box ->
        {:noreply,
         assign(socket,
           editing: true,
           editing_id: id,
           form: box_form(box),
           errors: %{},
           composing: false,
           dns: nil
         )}
    end
  end

  def handle_event("close_editor", _, socket),
    do: {:noreply, assign(socket, editing: false, composing: false, errors: %{})}

  def handle_event("save_mailbox", %{"box" => params}, socket) do
    case Mail.save_mailbox(socket.assigns.editing_id, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editing: false, form: %{}, tab: "mailboxes")
         |> load()
         |> put_flash(:info, "Mailbox saved.")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(form: Map.delete(params, "webhook_token"), errors: UI.form_errors(error))
         |> put_flash(:error, UI.changeset_message(error))}
    end
  end

  def handle_event("delete_mailbox", %{"id" => id}, socket) do
    case Mail.delete_mailbox(id) do
      :ok -> {:noreply, socket |> load() |> put_flash(:info, "Mailbox removed.")}
      {:error, error} -> {:noreply, put_flash(socket, :error, error)}
    end
  end

  def handle_event("compose", _, socket),
    do: {:noreply, assign(socket, composing: true, editing: false, compose: %{})}

  def handle_event("send", %{"email" => params}, socket) do
    case Mail.enqueue(params, UI.principal(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(composing: false, compose: %{}, tab: "outbox")
         |> load()
         |> put_flash(:info, "Message queued. Delivery status updates automatically.")}

      {:error, error} ->
        {:noreply, socket |> assign(:compose, params) |> put_flash(:error, error.message)}
    end
  end

  def handle_event("select_message", %{"id" => id}, socket) do
    case Mail.get(id, UI.principal(socket), true) do
      {:ok, message} -> {:noreply, socket |> assign(:selected, message) |> load()}
      {:error, error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("close_message", _, socket),
    do: {:noreply, socket |> assign(:selected, nil) |> load()}

  def handle_event("cancel", %{"id" => id}, socket) do
    case Mail.cancel(id, UI.principal(socket)) do
      {:ok, _} -> {:noreply, load(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("delete_message", %{"id" => id}, socket) do
    Mail.delete(id)
    {:noreply, socket |> assign(:selected, nil) |> load()}
  end

  def handle_event("retry_webhook", %{"id" => id}, socket) do
    Mail.retry_webhook(id)

    {:noreply,
     socket |> load() |> put_flash(:info, "Webhook retry queued with the original event ID.")}
  end

  def handle_event("toggle_receiver", _, socket) do
    InboundServer.toggle(!socket.assigns.receiver.running)
    {:noreply, load(socket)}
  end

  def handle_event("dkim", %{"id" => id}, socket) do
    case Mail.mailbox(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Mailbox not found.")}

      box ->
        {:noreply,
         socket
         |> assign(dns_loading: true, dns: nil)
         |> start_async(:dkim, fn -> MailDelivery.dkim_record(box) end)}
    end
  end

  @impl true
  def handle_async(:dkim, {:ok, {:ok, record}}, socket),
    do: {:noreply, assign(socket, dns: record, dns_loading: false)}

  def handle_async(:dkim, _, socket),
    do:
      {:noreply,
       socket
       |> assign(:dns_loading, false)
       |> put_flash(
         :error,
         "Could not prepare the DKIM key. Check the server’s mail key directory."
       )}

  @impl true
  def handle_info(:services_changed, socket), do: {:noreply, assign(socket, :dirty, true)}

  def handle_info(:service_tick, socket) do
    Process.send_after(self(), :service_tick, 1000)

    case UI.check_session(socket) do
      {:ok, _} -> {:noreply, if(socket.assigns.dirty, do: load(socket), else: socket)}
      _ -> {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  defp load(socket) do
    direction =
      case socket.assigns.tab do
        "outbox" -> "outbound"
        "queue" -> "queue"
        _ -> "inbound"
      end

    result =
      Mail.list(%{
        "direction" => direction,
        "search" => socket.assigns.search,
        "mailbox_id" => socket.assigns.mailbox_filter,
        "page" => socket.assigns.page
      })

    mailboxes = Mail.mailboxes()

    selected =
      if socket.assigns.selected do
        case Mail.get(socket.assigns.selected.id, UI.principal(socket)) do
          {:ok, message} -> message
          _ -> nil
        end
      end

    socket
    |> assign(
      boxes: mailboxes,
      total: result.total,
      page: result.page,
      pages: result.pages,
      selected: selected,
      stats: MailWorker.snapshot(),
      receiver: InboundServer.status(),
      dirty: false
    )
    |> UI.sync_stream(
      :messages,
      Enum.map(result.rows, &Map.put(&1, :selected, selected && selected.id == &1.id))
    )
    |> UI.sync_stream(:mailboxes, mailboxes)
  end

  defp box_form(box), do: Map.new(@box_fields, fn key -> {to_string(key), Map.get(box, key)} end)
  defp checked?(value), do: value in [true, "true"]

  defp body(message, key),
    do: Map.get(message.body, key) || Map.get(message.body, to_string(key)) || ""

  defp safe_html(html) do
    "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'\"><style>body{font:14px/1.6 system-ui;padding:16px;color:#1f2937;overflow-wrap:anywhere}img{max-width:100%}</style></head><body>" <>
      html <> "</body></html>"
  end

  defp rest_example(assigns) do
    mailbox =
      case assigns.boxes do
        [first | _] -> first.id
        _ -> "MAILBOX_ID"
      end

    payload =
      UI.pretty(%{
        mailbox_id: mailbox,
        to: "recipient@example.com",
        subject: "Hello",
        text: "Sent with Postbeam"
      })

    "curl #{assigns.base_url}/api/services/v1/mail/send \\\n  -H 'Authorization: Bearer YOUR_API_TOKEN' \\\n  -H 'Idempotency-Key: unique-message-123' \\\n  -H 'Content-Type: application/json' \\\n  -d '#{payload}'"
  end

  defp ws_example(assigns) do
    mailbox =
      case assigns.boxes do
        [first | _] -> first.id
        _ -> "MAILBOX_ID"
      end

    "channel.push('mail:send', {\n  mailbox_id: '#{mailbox}',\n  to: 'recipient@example.com',\n  subject: 'Hello',\n  text: 'Sent with Postbeam',\n  idempotency_key: 'unique-message-123'\n}).receive('ok', job => console.log(job.id))\n\nchannel.on('request:update', job => console.log(job.status))"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="service-mailer" phx-hook="ServiceAPI">
      <UI.header
        title="Mailer"
        subtitle="Incoming mail, outgoing delivery and webhooks. Powered by Postbeam."
      >
        <:actions>
          <button class="secondary-button" phx-click="new_mailbox">
            <span class="hero-plus"></span>Add mailbox
          </button>
          <button class="primary-button" phx-click="compose" disabled={@boxes == []}>
            <span class="hero-pencil-square"></span>Compose
          </button>
        </:actions>
      </UI.header>
      <div class="summary-line">
        <div><span>Unread</span><strong><%= Map.get(@stats, :unread, 0) %></strong></div>
        <div><span>Queued</span><strong><%= Map.get(@stats, :queued, 0) %></strong></div>
        <div><span>Sending now</span><strong><%= Map.get(@stats, :sending, 0) %></strong></div>
        <div><span>Webhook queue</span><strong><%= Map.get(@stats, :webhooks, 0) %></strong></div>
        <div><span>Mailboxes</span><strong><%= length(@boxes) %></strong></div>
      </div>
      <section :if={@editing} class="inline-editor">
        <div class="section-heading">
          <h2>{if @editing_id, do: "Edit mailbox", else: "New mailbox"}</h2>
          <button class="icon-button" phx-click="close_editor" aria-label="Close mailbox editor">
            <span class="hero-x-mark"></span>
          </button>
        </div>
        <form id="mailbox-form" phx-submit="save_mailbox">
          <div class="editor-grid">
            <.input
              name="box[name]"
              value={@form["name"]}
              label="Mailbox name"
              placeholder="Support"
              required
              errors={Map.get(@errors, :name, [])}
            /><.input
              type="email"
              name="box[address]"
              value={@form["address"]}
              label="Email address"
              placeholder="support@example.com"
              required
              errors={Map.get(@errors, :address, [])}
            /><.input
              name="box[hostname]"
              value={@form["hostname"]}
              label="Sending server hostname"
              placeholder="mail.example.com"
              required
              errors={Map.get(@errors, :hostname, [])}
            /><.input
              type="select"
              name="box[delivery_mode]"
              value={@form["delivery_mode"]}
              label="Delivery mode"
              options={[
                {"Local · store without sending", "local"},
                {"Direct delivery · Postbeam SMTP", "direct"}
              ]}
            />
          </div>
          <div class="form-checkbox-row">
            <.input
              type="checkbox"
              name="box[enabled]"
              checked={checked?(@form["enabled"])}
              label="Mailbox enabled"
            /><.input
              type="checkbox"
              name="box[dkim_enabled]"
              checked={checked?(@form["dkim_enabled"])}
              label="Sign outgoing mail with DKIM"
            />
          </div>
          <.input
            name="box[dkim_selector]"
            value={@form["dkim_selector"]}
            label="DKIM selector"
            errors={Map.get(@errors, :dkim_selector, [])}
          />
          <p class="field-help">
            Direct delivery sends to recipient MX servers. Configure your domain’s MX, SPF, DKIM and reverse DNS before using it externally.
          </p>
          <section class="form-subsection">
            <h3>Incoming email webhook</h3>
            <p>Forward each received email as JSON, after it is safely stored in the inbox.</p>
            <.input
              type="checkbox"
              name="box[webhook_enabled]"
              checked={checked?(@form["webhook_enabled"])}
              label="Forward incoming email to a webhook"
            />
            <div class="editor-grid">
              <.input
                type="url"
                name="box[webhook_url]"
                value={@form["webhook_url"]}
                label="Webhook URL"
                placeholder="https://your-app.example/webhooks/email"
                errors={Map.get(@errors, :webhook_url, [])}
              /><.input
                type="password"
                name="box[webhook_token]"
                value=""
                label="Webhook Bearer token"
                autocomplete="new-password"
                placeholder={
                  if @editing_id,
                    do: "Leave blank to keep the saved token",
                    else: "Optional authentication token"
                }
                errors={Map.get(@errors, :webhook_token, [])}
              />
            </div>
            <.input
              :if={@editing_id}
              type="checkbox"
              name="box[clear_webhook_token]"
              checked={false}
              label="Remove the saved webhook token"
            />
            <p class="field-help">
              HTTPS required; localhost also supports HTTP. The token is encrypted. Deliveries use a stable event ID and make up to five attempts for temporary failures.
            </p>
          </section>
          <div class="form-actions">
            <button class="primary-button" phx-disable-with="Saving…">Save mailbox</button><button
              type="button"
              class="secondary-button"
              phx-click="close_editor"
            >Cancel</button>
          </div>
        </form>
      </section>
      <section :if={@composing} class="inline-editor">
        <div class="section-heading">
          <h2>Compose email</h2>
          <button class="icon-button" phx-click="close_editor" aria-label="Close composer">
            <span class="hero-x-mark"></span>
          </button>
        </div>
        <form id="email-compose" phx-submit="send">
          <div class="editor-grid">
            <.input
              type="select"
              name="email[mailbox_id]"
              value={@compose["mailbox_id"]}
              label="From mailbox"
              options={
                Enum.filter(@boxes, & &1.enabled)
                |> Enum.map(&{&1.address <> " · " <> &1.delivery_mode, &1.id})
              }
            /><.input
              type="email"
              name="email[to]"
              value={@compose["to"] || ""}
              label="Recipient"
              required
            />
          </div>
          <.input
            name="email[subject]"
            value={@compose["subject"] || ""}
            label="Subject"
            maxlength="512"
          /><.input
            type="textarea"
            name="email[text]"
            value={@compose["text"] || ""}
            label="Message"
            rows="7"
            maxlength="128000"
          />
          <div class="form-actions">
            <button class="primary-button" phx-disable-with="Queuing…">
              <span class="hero-paper-airplane"></span>Queue email
            </button>
            <button type="button" class="secondary-button" phx-click="close_editor">Cancel</button>
          </div>
          <p class="field-help">
            Local mailboxes store the message without external delivery. Direct mailboxes send through Postbeam.
          </p>
        </form>
      </section>
      <UI.tabs
        tabs={[
          {"inbox", "Inbox"},
          {"outbox", "Outbox"},
          {"queue", "Queue"},
          {"mailboxes", "Mailboxes & webhooks"},
          {"examples", "API examples"}
        ]}
        active={@tab}
      />
      <section hidden={@tab not in ["inbox", "outbox", "queue"]}>
        <form class="workbench-toolbar mail-filters" phx-change="filter">
          <div class="search-field">
            <span class="hero-magnifying-glass"></span>
            <input
              name="search"
              type="search"
              value={@search}
              aria-label="Search email"
              placeholder="Search subject or address"
              phx-debounce="250"
            />
          </div>
          <select name="mailbox_id" aria-label="Filter by mailbox">
            <option value="">All mailboxes</option>
            <option :for={box <- @boxes} value={box.id} selected={@mailbox_filter == box.id}>
              {box.address}
            </option>
          </select>
          <span class="muted small">{@total} messages</span>
        </form>
        <div class={["mail-workbench", @selected && "has-selection"]}>
          <div>
            <div class="service-table-wrap">
              <table class="service-table">
                <thead>
                  <tr>
                    <th>Message</th>
                    <th>{if @tab == "inbox", do: "From", else: "To"}</th>
                    <th>Status</th>
                    <th>Received / queued</th>
                  </tr>
                </thead>
                <tbody id="mail-messages" phx-update="stream">
                  <tr
                    :for={{id, message} <- @streams.messages}
                    id={id}
                    class={[
                      message.selected && "selected-row",
                      is_nil(message.read_at) && message.direction == "inbound" && "unread-row"
                    ]}
                  >
                    <td>
                      <button
                        class="text-button message-subject"
                        phx-click="select_message"
                        phx-value-id={message.id}
                      >
                        {if message.subject == "", do: "(No subject)", else: message.subject}
                      </button>
                      <span class="table-subline mono">
                        {UI.short(message.id)} · {message.direction}
                      </span>
                    </td>
                    <td>
                      <span class="address-text">
                        {if message.direction == "inbound",
                          do: message.sender,
                          else: message.recipient}
                      </span>
                    </td>
                    <td>
                      <span class={UI.status_class(message.status)}>{message.status}</span><span
                        :if={message.webhook_status != "disabled"}
                        class="table-subline"
                      >Webhook · <%= message.webhook_status %></span>
                    </td>
                    <td class="small">{UI.time(message.inserted_at)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div :if={@total == 0} class="table-empty">
              <span class="hero-inbox"></span><strong><%= if @tab == "queue", do: "The queue is clear", else: "No messages here yet" %></strong>
              <p>
                {if @boxes == [],
                  do: "Add a mailbox to receive or send email.",
                  else: "Messages and delivery updates appear automatically."}
              </p>
            </div>
            <div class="panel-pagination">
              <span>Page {@page} of {@pages}</span>
              <div>
                <button
                  class="quiet-button"
                  phx-click="page"
                  phx-value-direction="prev"
                  disabled={@page <= 1}
                  aria-label="Previous email page"
                >
                  <span class="hero-chevron-left"></span>
                </button>
                <button
                  class="quiet-button"
                  phx-click="page"
                  phx-value-direction="next"
                  disabled={@page >= @pages}
                  aria-label="Next email page"
                >
                  <span class="hero-chevron-right"></span>
                </button>
              </div>
            </div>
          </div>
          <aside
            :if={@selected}
            id="mail-reader"
            class="mail-reader inspector"
            tabindex="-1"
            phx-mounted={JS.focus(to: "#mail-reader")}
          >
            <div class="section-heading">
              <span class={UI.status_class(@selected.status)}>{@selected.status}</span><button
                class="icon-button"
                phx-click="close_message"
                aria-label="Close message"
              ><span class="hero-x-mark"></span></button>
            </div>
            <h2>{@selected.subject}</h2>
            <dl class="detail-list">
              <div>
                <dt>From</dt>
                <dd>{@selected.sender}</dd>
              </div>
              <div>
                <dt>To</dt>
                <dd>{@selected.recipient}</dd>
              </div>
              <div>
                <dt>Received / queued</dt>
                <dd>{UI.time(@selected.inserted_at)}</dd>
              </div>
              <div :if={@selected.started_at}>
                <dt>Started</dt>
                <dd>{UI.time(@selected.started_at)}</dd>
              </div>
              <div :if={@selected.finished_at}>
                <dt>Finished</dt>
                <dd>{UI.time(@selected.finished_at)}</dd>
              </div>
            </dl>
            <p :if={@selected.error} class="notice notice-error">{@selected.error}</p>
            <p :if={@selected.status == "accepted"} class="field-help">
              Accepted by the recipient’s SMTP server. Inbox placement is determined by that server.
            </p>
            <p :if={@selected.status == "local"} class="field-help">
              Stored locally. This message was not sent externally.
            </p>
            <div class="message-body">
              <pre :if={body(@selected, :text) != ""}><%= body(@selected, :text) %></pre><iframe
                :if={body(@selected, :text) == "" && body(@selected, :html) != ""}
                title="Email content"
                sandbox=""
                referrerpolicy="no-referrer"
                srcdoc={safe_html(body(@selected, :html))}
              >
              </iframe>
            </div>
            <details :if={body(@selected, :html) != ""}>
              <summary>HTML source</summary>
              <pre class="message-source"><%= body(@selected, :html) %></pre>
            </details>
            <section :if={@selected.direction == "inbound"} class="form-subsection">
              <h3>Webhook delivery</h3>
              <span class={UI.status_class(@selected.webhook_status)}>
                {@selected.webhook_status}
              </span>
              <p class="field-help">
                {@selected.webhook_attempts} attempts · Event ID <code>{@selected.id}</code>
              </p>
              <p :if={@selected.webhook_error} class="error-text small">{@selected.webhook_error}</p>
              <p
                :if={@selected.webhook_next_at && @selected.webhook_status in ["pending", "retrying"]}
                class="field-help"
              >
                Next attempt: {UI.time(@selected.webhook_next_at)}
              </p>
              <button
                :if={@selected.webhook_status == "failed"}
                class="secondary-button"
                phx-click="retry_webhook"
                phx-value-id={@selected.id}
              >
                Retry webhook
              </button>
            </section>
            <div class="form-actions">
              <button
                :if={@selected.status == "queued"}
                class="secondary-button"
                phx-click="cancel"
                phx-value-id={@selected.id}
              >
                Cancel queued email
              </button>
              <button
                :if={
                  @selected.status not in ["queued", "sending"] &&
                    @selected.webhook_status not in ["pending", "retrying", "sending"]
                }
                class="text-button error-text"
                phx-click="delete_message"
                phx-value-id={@selected.id}
                data-confirm="Delete this stored message?"
              >
                Delete message
              </button>
            </div>
          </aside>
        </div>
        <p class="workspace-footnote">
          Up to 1,000 messages per mailbox. Automatic retention is optional and disabled by default. Email content is encrypted. Ambiguous SMTP acceptance is marked “uncertain” and is never automatically retried.
        </p>
      </section>
      <section hidden={@tab != "mailboxes"}>
        <div class="receiver-status">
          <span class={UI.status_class(if @receiver.running, do: "completed", else: "idle")}>
            {if @receiver.running, do: "SMTP receiver running", else: "SMTP receiver stopped"}
          </span>
          <code>{@receiver.address}:{@receiver.port}</code><button
            class="secondary-button"
            phx-click="toggle_receiver"
          ><%= if @receiver.running, do: "Stop receiver", else: "Start receiver" %></button>
        </div>
        <p :if={@receiver.error} class="notice notice-error">{@receiver.error}</p>
        <div class="service-table-wrap">
          <table class="service-table">
            <thead>
              <tr>
                <th>Mailbox</th>
                <th>Delivery</th>
                <th>Inbound webhook</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="mailboxes" phx-update="stream">
              <tr :for={{id, box} <- @streams.mailboxes} id={id}>
                <td>
                  <strong>{box.name}</strong><span class="table-subline"><%= box.address %></span>
                  <code id={"mailbox-id-#{box.id}"} class="table-subline mono">{box.id}</code>
                  <button
                    type="button"
                    class="text-button small"
                    data-copy-target={"#mailbox-id-#{box.id}"}
                  >
                    Copy ID
                  </button>
                </td>
                <td>
                  {if box.delivery_mode == "local", do: "Local storage", else: "Postbeam SMTP"}<span class="table-subline"><%= if box.dkim_enabled, do: "DKIM enabled", else: "DKIM disabled" %></span>
                </td>
                <td>
                  <span class="address-text">
                    {if box.webhook_enabled, do: box.webhook_url, else: "Disabled"}
                  </span>
                  <span :if={box.webhook_enabled && box.webhook_token} class="table-subline">
                    Bearer token saved
                  </span>
                </td>
                <td>
                  <span class={UI.status_class(if box.enabled, do: "completed", else: "idle")}>
                    {if box.enabled, do: "Enabled", else: "Disabled"}
                  </span>
                </td>
                <td class="row-actions">
                  <button class="text-button" phx-click="edit_mailbox" phx-value-id={box.id}>
                    Edit
                  </button>
                  <button
                    class="text-button"
                    phx-click="dkim"
                    phx-value-id={box.id}
                    disabled={@dns_loading}
                  >
                    DKIM DNS
                  </button>
                  <button
                    class="text-button error-text"
                    phx-click="delete_mailbox"
                    phx-value-id={box.id}
                    data-confirm="Remove this mailbox? Only empty mailboxes can be removed."
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@boxes == []} class="table-empty">
          Create a mailbox to configure its address, delivery mode and incoming webhook.
        </p>
        <section :if={@dns || @dns_loading} class="inline-section">
          <h2>DKIM DNS record</h2>
          <p :if={@dns_loading}>Preparing the signing key…</p>
          <div :if={@dns}>
            <p class="field-help">
              Publish this TXT record in your domain’s DNS, then enable DKIM signing for the mailbox.
            </p>
            <code>{@dns.name}</code><pre id="dkim-record" class="code-sample"><%= @dns.value %></pre>
            <button
              type="button"
              class="secondary-button"
              data-copy-target="#dkim-record"
            >
              Copy DNS value
            </button>
          </div>
        </section>
        <p class="workspace-footnote">
          The receiver accepts only enabled mailbox addresses and never relays messages. Start/stop applies until the app restarts. Server binding, port and TLS certificates use SERVICE_SMTP_* environment settings. Local development listens on 127.0.0.1:2525. Each mailbox stores up to 1,000 messages. Messages are retained until deleted unless automatic retention is configured on the server.
        </p>
      </section>
      <section hidden={@tab != "examples"} class="example-workbench">
        <div>
          <h2>Send with REST</h2>
          <p>The key needs <code>mail:send</code> and access to the sending mailbox.</p>
          <pre class="code-sample"><code><%= rest_example(assigns) %></code></pre>
          <h2>Read incoming email</h2>
          <pre class="code-sample"><code>GET <%= @base_url %>/api/services/v1/mail/messages?direction=inbound
    Authorization: Bearer YOUR_API_TOKEN</code></pre>
        </div>
        <div>
          <h2>Send with WebSocket</h2>
          <p>Join <code>services:gateway</code> with your API token first.</p>
          <pre class="code-sample"><code><%= ws_example(assigns) %></code></pre>
          <h2>Incoming webhook</h2>
          <p>
            Configure the URL and Bearer token per mailbox. Your endpoint should return HTTP 2xx after accepting the event.
          </p>
          <pre class="code-sample"><code><%= UI.pretty(%{event: "email.received", event_id: "MESSAGE_UUID", mailbox: %{id: "MAILBOX_ID", address: "support@example.com"}, from: "sender@example.net", to: ["support@example.com"], subject: "Hello", text: "Message body", html: "", attachments: []}) %></code></pre>
          <p class="field-help">
            The <code>Authorization: Bearer …</code>, <code>X-Postbeam-Event-Id</code>
            and <code>Idempotency-Key</code>
            headers accompany the request. Deduplicate by event ID: a timeout may trigger another attempt. Redirects are not followed.
          </p>
        </div>
      </section>
      <p
        id="mail-copy-feedback"
        class="copy-feedback"
        data-copy-feedback
        role="status"
        phx-update="ignore"
      >
      </p>
    </div>
    """
  end
end
