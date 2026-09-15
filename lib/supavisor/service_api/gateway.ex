defmodule Supavisor.ServiceAPI.Gateway do
  @moduledoc """
  Service WebSocket authentication and live connection registry.

  Only a SHA-256 token digest is persisted. Connections and recent activity live
  in memory, are bounded, and are never written to PostgreSQL. Service handlers
  are deliberately not implemented yet; submissions fail with an explicit error.
  PostgreSQL REST API authentication is independent of this gateway.
  """
  use GenServer
  alias Supavisor.ServiceAPI.Credential

  @table __MODULE__
  @topic "admin:service_api"
  @credentials_topic "service_api:credentials"
  @max_clients 100
  @history_limit 30
  @services ["mailer", "embedding", "ai_model", "stt", "tts"]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def subscribe, do: Phoenix.PubSub.subscribe(Supavisor.PubSub, @topic)
  def services, do: @services
  def register(token, client_id), do: GenServer.call(__MODULE__, {:register, token, client_id})
  def configure(token, actor), do: GenServer.call(__MODULE__, {:configure, token, actor})

  def authorized?(generation) when is_binary(generation) do
    case :ets.lookup(@table, :generation) do
      [{:generation, ^generation}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def authorized?(_), do: false

  def snapshot do
    case :ets.lookup(@table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Phoenix.PubSub.subscribe(Supavisor.PubSub, @credentials_topic)

    state = %{
      credential: nil,
      clients: %{},
      history: [],
      dirty: true,
      started_at: DateTime.utc_now()
    }

    state = reload_credential(state)
    Process.send_after(self(), :publish, 1_000)
    {:ok, publish(state)}
  end

  @impl true
  def handle_call({:register, token, id}, {pid, _}, state) do
    cond do
      !valid_token?(token, state.credential) ->
        {:reply, {:error, "unauthorized"}, state}

      map_size(state.clients) >= @max_clients ->
        {:reply, {:error, "connection_limit"}, state}

      true ->
        monitor = Process.monitor(pid)
        client = %{id: id, connected_at: DateTime.utc_now(), pid: pid}

        state =
          %{state | clients: Map.put(state.clients, monitor, client)} |> activity("connected", id)

        {:reply, {:ok, state.credential.generation}, cache(state)}
    end
  end

  def handle_call({:configure, token, actor}, _from, state) do
    case Credential.save(token, actor) do
      {:ok, credential} ->
        state = replace_credential(state, credential)

        Phoenix.PubSub.broadcast_from(
          Supavisor.PubSub,
          self(),
          @credentials_topic,
          :credential_changed
        )

        {:reply, :ok, publish(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.clients, monitor) do
      {nil, _} ->
        {:noreply, state}

      {client, clients} ->
        {:noreply, %{state | clients: clients} |> activity("disconnected", client.id)}
    end
  end

  def handle_info(:credential_changed, state),
    do: {:noreply, state |> reload_credential() |> publish()}

  def handle_info(:publish, state) do
    Process.send_after(self(), :publish, 1_000)
    {:noreply, if(state.dirty, do: publish(state), else: state)}
  end

  defp reload_credential(state) do
    replace_credential(state, Credential.read())
  rescue
    _ -> replace_credential(state, nil)
  end

  defp replace_credential(state, credential) do
    old_generation = state.credential && state.credential.generation
    new_generation = credential && credential.token_digest && credential.generation
    :ets.insert(@table, {:generation, new_generation})

    state =
      if old_generation != new_generation do
        Enum.reduce(state.clients, state, fn {ref, client}, acc ->
          send(client.pid, :token_revoked)
          Process.demonitor(ref, [:flush])
          activity(acc, "revoked", client.id)
        end)
      else
        state
      end

    %{
      state
      | credential: credential,
        clients: if(old_generation != new_generation, do: %{}, else: state.clients),
        dirty: true
    }
  end

  defp valid_token?(token, %{token_digest: hash})
       when is_binary(token) and byte_size(token) in 32..128 and is_binary(hash),
       do: Plug.Crypto.secure_compare(Credential.digest(token), hash)

  defp valid_token?(_, _), do: false

  defp activity(state, event, client_id) do
    item = %{id: Ecto.UUID.generate(), event: event, client_id: client_id, at: DateTime.utc_now()}
    %{state | history: Enum.take([item | state.history], @history_limit), dirty: true}
  end

  defp cache(state) do
    credential = state.credential

    snapshot = %{
      ready: !!(credential && credential.token_digest),
      fingerprint: credential && credential.token_fingerprint,
      token_updated_at: credential && credential.updated_at,
      connected: map_size(state.clients),
      clients:
        state.clients
        |> Map.values()
        |> Enum.map(&Map.drop(&1, [:pid]))
        |> Enum.sort_by(& &1.connected_at, {:desc, DateTime}),
      activity: state.history,
      max_clients: @max_clients,
      started_at: state.started_at
    }

    :ets.insert(@table, {:snapshot, snapshot})
    state
  end

  defp publish(state) do
    cache(state)
    Phoenix.PubSub.broadcast(Supavisor.PubSub, @topic, :service_api_updated)
    %{state | dirty: false}
  end
end
