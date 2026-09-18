defmodule SupavisorWeb.AdminLoginLimiter do
  @moduledoc "Bounded, in-memory limits for administrator sign-in attempts."
  use GenServer
  @table __MODULE__
  @max_entries 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def allow?(ip, email), do: GenServer.call(__MODULE__, {:allow, ip, account(email)})
  def allow_cap?(ip), do: GenServer.call(__MODULE__, {:allow_cap, ip})
  def allow_oauth?(ip), do: GenServer.call(__MODULE__, {:allow_oauth, ip})
  def succeeded(email), do: GenServer.call(__MODULE__, {:succeeded, account(email)})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected])
    Process.send_after(self(), :prune, 60_000)
    {:ok, nil}
  end

  @impl true
  def handle_call({:allow, ip, email}, _from, state) do
    buckets = [{{:ip, ip}, 15, 60_000}, {{:account, email}, 10, 900_000}]
    {:reply, consume(buckets), state}
  end

  def handle_call({:allow_cap, ip}, _from, state) do
    # Bound both individual requests and total challenge growth in PhoenixCap's ETS tables.
    buckets = [{{:cap_ip, ip}, 20, 60_000}, {:cap_global, 100, 60_000}]
    {:reply, consume(buckets), state}
  end

  def handle_call({:allow_oauth, ip}, _from, state) do
    {:reply, consume([{{:ip, ip}, 15, 60_000}]), state}
  end

  def handle_call({:succeeded, email}, _from, state) do
    :ets.delete(@table, {:account, email})
    {:reply, :ok, state}
  end

  defp consume(buckets) do
    now = System.monotonic_time(:millisecond)

    allowed =
      :ets.info(@table, :size) < @max_entries and
        Enum.all?(buckets, fn {key, limit, _window} -> count(key, now) < limit end)

    if allowed do
      Enum.each(buckets, fn {key, _limit, window} ->
        case :ets.lookup(@table, key) do
          [{^key, attempts, until}] when until > now ->
            :ets.insert(@table, {key, attempts + 1, until})

          _ ->
            :ets.insert(@table, {key, 1, now + window})
        end
      end)
    end

    allowed
  end

  @impl true
  def handle_info(:prune, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    Process.send_after(self(), :prune, 60_000)
    {:noreply, state}
  end

  defp count(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, count, until}] when until > now -> count
      _ -> 0
    end
  end

  defp account(email), do: :crypto.hash(:sha256, email |> String.trim() |> String.downcase())
end
