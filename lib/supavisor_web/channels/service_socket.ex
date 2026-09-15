defmodule SupavisorWeb.ServiceSocket do
  use Phoenix.Socket

  channel "services:gateway", SupavisorWeb.ServiceChannel

  # Authenticate the channel join, so tokens never appear in the URL. This
  # transport does not use console cookies, PostgreSQL JWTs or query tokens.
  @impl true
  def connect(_params, socket, _info),
    do: {:ok, assign(socket, :client_id, Ecto.UUID.generate())}

  @impl true
  def id(socket), do: "service_client:" <> socket.assigns.client_id
end
