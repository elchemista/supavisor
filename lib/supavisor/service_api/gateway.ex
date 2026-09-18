defmodule Supavisor.ServiceAPI.Gateway do
  @moduledoc "Authenticated WebSocket connections, monitored without per-connection database writes."
  use GenServer
  alias Supavisor.ServiceAPI.KeyCache
  @table __MODULE__
  @topic "admin:service_api"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def subscribe, do: Phoenix.PubSub.subscribe(Supavisor.PubSub, @topic)
  def register(token, id), do: GenServer.call(__MODULE__, {:register, token, id})

  def snapshot do
    case :ets.lookup(@table, :snapshot) do
      [{_, snapshot}] -> snapshot
      _ -> %{connected: 0, clients: [], activity: []}
    end
  rescue
    _ -> %{connected: 0, clients: [], activity: []}
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Process.send_after(self(), :publish, 1000)
    {:ok, publish(%{clients: %{}, history: [], dirty: true})}
  end

  @impl true
  def handle_call({:register, token, id}, {pid, _}, state) do
    with {:ok, key} <- KeyCache.authenticate(token, "websocket"),
         true <-
           map_size(state.clients) < 100 and
             Enum.count(state.clients, fn {_, c} -> c.key_id == key.id end) < 10 do
      ref = Process.monitor(pid)
      client = %{id: id, key_id: key.id, key_name: key.name, connected_at: DateTime.utc_now()}

      state =
        %{state | clients: Map.put(state.clients, ref, client)} |> activity("connected", client)

      {:reply, {:ok, key}, state}
    else
      false -> {:reply, {:error, "connection_limit"}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state.clients, ref) do
      {nil, _} ->
        {:noreply, state}

      {client, clients} ->
        {:noreply, %{state | clients: clients} |> activity("disconnected", client)}
    end
  end

  def handle_info(:publish, state) do
    Process.send_after(self(), :publish, 1000)
    {:noreply, if(state.dirty, do: publish(state), else: state)}
  end

  defp activity(state, event, client) do
    item = %{
      id: Ecto.UUID.generate(),
      event: event,
      client_id: client.id,
      key_name: client.key_name,
      at: DateTime.utc_now()
    }

    %{state | history: Enum.take([item | state.history], 30), dirty: true}
  end

  defp publish(state) do
    snapshot = %{
      connected: map_size(state.clients),
      clients: Map.values(state.clients),
      activity: state.history
    }

    :ets.insert(@table, {:snapshot, snapshot})
    Phoenix.PubSub.broadcast(Supavisor.PubSub, @topic, :service_api_updated)
    %{state | dirty: false}
  end
end
