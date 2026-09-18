defmodule SupavisorWeb.Admin.ServiceUI do
  use Phoenix.Component
  def time(nil), do: "—"
  def time(value), do: Calendar.strftime(value, "%d %b, %H:%M:%S UTC")
  def short(nil), do: "—"
  def short(id), do: String.slice(id, 0, 8)

  def status_class(status)
      when status in ["completed", "accepted", "received", "delivered", "local"],
      do: "state-label state-success"

  def status_class(status) when status in ["failed", "uncertain", "revoked"],
    do: "state-label state-error"

  def status_class(status) when status in ["running", "sending", "queued", "pending", "retrying"],
    do: "state-label state-pending"

  def status_class(_), do: "state-label"
  def pretty(value), do: Jason.encode!(value, pretty: true)
  def principal(socket), do: %{admin: true, email: socket.assigns.current_admin_email}

  def check_session(socket),
    do: SupavisorWeb.AdminAuth.authenticate_session(socket.assigns.service_session)

  def changeset_message(error), do: Supavisor.Services.Events.errors(error)

  def form_errors(%Ecto.Changeset{} = changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end)

  def form_errors(_), do: %{}

  def subscribe(socket) do
    if Phoenix.LiveView.connected?(socket) do
      Supavisor.Services.Events.subscribe()
      Process.send_after(self(), :service_tick, 1000)
    end
  end

  # Keep only fingerprints in the LiveView process; stream unchanged rows without
  # resending table contents on every status notification.
  def sync_stream(socket, name, rows) do
    cache = Map.get(socket.assigns, :service_streams, %{})
    previous = Map.get(cache, name, %{ids: [], hashes: %{}})
    ids = Enum.map(rows, & &1.id)
    hashes = Map.new(rows, &{&1.id, :erlang.phash2(&1)})

    socket =
      if ids == previous.ids do
        Enum.reduce(rows, socket, fn row, acc ->
          if previous.hashes[row.id] == hashes[row.id],
            do: acc,
            else: Phoenix.LiveView.stream_insert(acc, name, row)
        end)
      else
        Phoenix.LiveView.stream(socket, name, rows, reset: true)
      end

    assign(socket, :service_streams, Map.put(cache, name, %{ids: ids, hashes: hashes}))
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="service-page-header">
      <div>
        <h1>{@title}</h1>
        <p>{@subtitle}</p>
      </div>
      <div class="toolbar-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :tabs, :list, required: true
  attr :active, :string, required: true

  def tabs(assigns) do
    ~H"""
    <nav class="service-tabs" aria-label="Page sections">
      <button
        :for={{id, label} <- @tabs}
        type="button"
        phx-click="tab"
        phx-value-tab={id}
        class={@active == id && "is-active"}
        aria-current={if @active == id, do: "page"}
      >
        {label}
      </button>
    </nav>
    """
  end
end
