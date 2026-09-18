defmodule SupavisorWeb.ServiceChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false
  alias Supavisor.ServiceAPI.{Gateway, KeyCache, RateLimiter}
  alias Supavisor.Services.Dispatcher

  @impl true
  def join("services:gateway", %{"token" => token}, socket) when is_binary(token) do
    with {:ok, key} <- Gateway.register(token, socket.assigns.client_id) do
      Phoenix.PubSub.subscribe(Supavisor.PubSub, "services:key:#{key.id}")
      monitor = Process.monitor(Process.whereis(Gateway))
      Process.send_after(self(), :check_access, 5_000)

      {:ok,
       %{
         client_id: socket.assigns.client_id,
         status: "authenticated",
         scopes: key.scopes,
         services: ["embedding", "mailer", "tts", "stt", "ai"]
       }, assign(socket, principal: key, gateway_monitor: monitor)}
    else
      {:error, code} -> {:error, %{code: code}}
    end
  catch
    :exit, _ -> {:error, %{code: "unavailable"}}
  end

  def join(_, _, _), do: {:error, %{code: "unauthorized"}}

  @impl true
  def handle_in(event, params, socket) do
    case KeyCache.get(socket.assigns.principal.id) do
      {:ok, key} ->
        cond do
          "websocket" not in key.transports ->
            close(socket)

          event != "audio:upload:chunk" and !RateLimiter.allow?(key.id) ->
            {:reply,
             {:error, %{code: "rate_limited", message: "120 requests per minute per API key."}},
             socket}

          true ->
            {:reply, Dispatcher.call(key, event, params), assign(socket, :principal, key)}
        end

      _ ->
        close(socket)
    end
  end

  @impl true
  def handle_info({:request_updated, data}, socket) do
    case KeyCache.get(socket.assigns.principal.id) do
      {:ok, _} ->
        push(socket, "request:update", data)
        {:noreply, socket}

      _ ->
        close(socket)
    end
  end

  def handle_info(:key_revoked, socket), do: close(socket)

  def handle_info(:check_access, socket) do
    Process.send_after(self(), :check_access, 5_000)

    case KeyCache.get(socket.assigns.principal.id) do
      {:ok, _} -> {:noreply, socket}
      _ -> close(socket)
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{assigns: %{gateway_monitor: ref}} = socket),
    do: close(socket)

  defp close(socket) do
    push(socket, "authorization:revoked", %{reason: "key_revoked_or_expired"})
    SupavisorWeb.Endpoint.broadcast(SupavisorWeb.ServiceSocket.id(socket), "disconnect", %{})
    {:stop, :normal, socket}
  end
end
