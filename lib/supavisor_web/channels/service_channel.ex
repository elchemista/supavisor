defmodule SupavisorWeb.ServiceChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false
  alias Supavisor.ServiceAPI.Gateway

  @impl true
  def join("services:gateway", %{"token" => token}, socket) when is_binary(token) do
    case Gateway.register(token, socket.assigns.client_id) do
      {:ok, generation} ->
        monitor = Process.monitor(Process.whereis(Gateway))

        {:ok,
         %{
           client_id: socket.assigns.client_id,
           status: "authenticated",
           services: Gateway.services(),
           processing: "not_configured"
         },
         assign(socket,
           generation: generation,
           gateway_monitor: monitor,
           rate_window: nil,
           rate_count: 0
         )}

      {:error, reason} ->
        {:error, %{code: reason}}
    end
  catch
    :exit, _ -> {:error, %{code: "gateway_unavailable"}}
  end

  def join(_, _, _), do: {:error, %{code: "unauthorized"}}

  @impl true
  def handle_in(event, payload, socket) do
    now = System.monotonic_time(:second)
    count = if now == socket.assigns.rate_window, do: socket.assigns.rate_count + 1, else: 1
    socket = assign(socket, rate_window: now, rate_count: count)

    cond do
      !Gateway.authorized?(socket.assigns.generation) ->
        disconnect(socket)
        {:stop, :normal, socket}

      count > 30 ->
        {:reply, {:error, %{code: "rate_limited", retry_after_ms: 1000}}, socket}

      true ->
        respond(event, payload, socket)
    end
  end

  defp respond("gateway:status", _, socket) do
    {:reply,
     {:ok,
      %{
        status: "authenticated",
        client_id: socket.assigns.client_id,
        processing: "not_configured",
        services: Gateway.services(),
        time: DateTime.utc_now()
      }}, socket}
  end

  defp respond("request:submit", %{"service" => service}, socket) do
    code =
      if service in Gateway.services(), do: "service_not_implemented", else: "unknown_service"

    {:reply, {:error, %{code: code}}, socket}
  end

  defp respond(_, _, socket), do: {:reply, {:error, %{code: "unsupported_event"}}, socket}

  @impl true
  def handle_info(:token_revoked, socket) do
    push(socket, "authorization:revoked", %{reason: "token_changed"})
    disconnect(socket)
    {:stop, :normal, socket}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{assigns: %{gateway_monitor: ref}} = socket) do
    disconnect(socket)
    {:stop, :normal, socket}
  end

  defp disconnect(socket),
    do: SupavisorWeb.Endpoint.broadcast(SupavisorWeb.ServiceSocket.id(socket), "disconnect", %{})
end
