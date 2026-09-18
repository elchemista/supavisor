defmodule Supavisor.ServiceAPI.KeyCache do
  @moduledoc "Small credential cache. Revocation is synchronous locally and broadcast across nodes."
  use GenServer
  alias Supavisor.ServiceAPI.AccessKey
  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def refresh do
    result = GenServer.call(__MODULE__, :refresh)
    Phoenix.PubSub.broadcast(Supavisor.PubSub, "services:keys", {:keys_changed, node()})
    result
  end

  def authenticate(token, transport) when is_binary(token) and byte_size(token) in 32..128 do
    hash = :crypto.hash(:sha256, token)

    case :ets.lookup(@table, {:digest, hash}) do
      [{_, key}] ->
        if valid?(key) and transport in key.transports,
          do: {:ok, key},
          else: {:error, "unauthorized"}

      _ ->
        {:error, "unauthorized"}
    end
  rescue
    ArgumentError -> {:error, "unavailable"}
  end

  def authenticate(_, _), do: {:error, "unauthorized"}

  def get(id) do
    case :ets.lookup(@table, {:id, id}) do
      [{_, key}] -> if valid?(key), do: {:ok, key}, else: {:error, "unauthorized"}
      _ -> {:error, "unauthorized"}
    end
  rescue
    ArgumentError -> {:error, "unavailable"}
  end

  def allowed?(%{admin: true}, _scope), do: true

  def allowed?(%{id: id}, scope) do
    case get(id) do
      {:ok, key} -> scope in key.scopes
      _ -> false
    end
  end

  def owner(%{admin: true, email: email}), do: "admin:" <> email
  def owner(%{id: id}), do: id
  def mailbox?(%{admin: true}, _id), do: true
  def mailbox?(%{mailbox_ids: []}, _id), do: true
  def mailbox?(%{mailbox_ids: ids}, id), do: id in ids

  def valid?(key),
    do: is_nil(key.expires_at) or DateTime.compare(key.expires_at, DateTime.utc_now()) == :gt

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Supavisor.PubSub, "services:keys")
    Process.send_after(self(), :refresh, 5_000)
    {:ok, reload(%{ids: MapSet.new()})}
  end

  @impl true
  def handle_call(:refresh, _, state), do: {:reply, :ok, reload(state)}
  @impl true
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, 5_000)
    {:noreply, reload(state)}
  end

  def handle_info({:keys_changed, origin}, state),
    do: {:noreply, if(origin == node(), do: state, else: reload(state))}

  defp reload(state) do
    keys = AccessKey.active()
    ids = MapSet.new(keys, & &1.id)

    rows =
      Enum.flat_map(keys, fn key ->
        public = Map.take(key, [:id, :name, :scopes, :transports, :mailbox_ids, :expires_at])
        [{{:digest, key.digest}, public}, {{:id, key.id}, public}]
      end)

    # Existing credentials stay readable while the new set is prepared.
    for key <- :ets.tab2list(@table),
        elem(key, 0) not in Enum.map(rows, &elem(&1, 0)),
        do: :ets.delete(@table, elem(key, 0))

    :ets.insert(@table, rows)

    for id <- MapSet.difference(state.ids, ids),
        do: Phoenix.PubSub.broadcast(Supavisor.PubSub, "services:key:#{id}", :key_revoked)

    if ids != state.ids, do: Supavisor.Services.Events.changed()
    %{state | ids: ids}
  rescue
    _ ->
      :ets.delete_all_objects(@table)

      for id <- state.ids,
          do: Phoenix.PubSub.broadcast(Supavisor.PubSub, "services:key:#{id}", :key_revoked)

      %{state | ids: MapSet.new()}
  end
end
