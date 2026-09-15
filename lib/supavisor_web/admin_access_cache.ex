defmodule SupavisorWeb.AdminAccessCache do
  @moduledoc false
  use GenServer
  @table __MODULE__
  @topic "admin:authorization"
  @ttl 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def emails do
    case cached() do
      {:ok, emails} ->
        emails

      :miss ->
        if Process.whereis(__MODULE__),
          do: GenServer.call(__MODULE__, :refresh),
          else: SupavisorWeb.AdminSettings.uncached_admin_emails()
    end
  end

  def invalidate do
    if pid = Process.whereis(__MODULE__) do
      :ok = GenServer.call(__MODULE__, :invalidate)
      Phoenix.PubSub.broadcast_from(Supavisor.PubSub, pid, @topic, :invalidate_admin_access)
    else
      :ok
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Phoenix.PubSub.subscribe(Supavisor.PubSub, @topic)
    {:ok, nil}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    # One process fills the cache; invalidation cannot race an in-flight DB read.
    emails =
      case cached() do
        {:ok, emails} ->
          emails

        :miss ->
          emails = SupavisorWeb.AdminSettings.uncached_admin_emails()
          :ets.insert(@table, {:emails, now() + @ttl, emails})
          emails
      end

    {:reply, emails, state}
  rescue
    _ -> {:reply, [], state}
  end

  def handle_call(:invalidate, _from, state) do
    :ets.delete(@table, :emails)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:invalidate_admin_access, state) do
    :ets.delete(@table, :emails)
    {:noreply, state}
  end

  defp cached do
    case :ets.lookup(@table, :emails) do
      [{:emails, expires, emails}] -> if expires > now(), do: {:ok, emails}, else: :miss
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp now, do: System.monotonic_time(:millisecond)
end
