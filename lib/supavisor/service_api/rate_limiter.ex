defmodule Supavisor.ServiceAPI.RateLimiter do
  @moduledoc "Shared, bounded REST/WS request budget per API key."
  use GenServer
  @table __MODULE__
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def allow?(id) do
    window = div(System.monotonic_time(:second), 60)
    :ets.update_counter(@table, {id, window}, {2, 1}, {{id, window}, 0}) <= 120
  rescue
    _ -> false
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :prune, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    now = div(System.monotonic_time(:second), 60)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :prune, 60_000)
    {:noreply, state}
  end
end
