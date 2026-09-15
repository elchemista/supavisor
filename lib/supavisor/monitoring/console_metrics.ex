defmodule Supavisor.Monitoring.ConsoleMetrics do
  @moduledoc """
  One sampler per node, with a bounded ten-minute history held in ETS.
  Reads Linux /proc counters every five seconds. No database reads or writes.
  CPU percentages use all host CPUs as the denominator; RAM uses physical host
  memory. These are host metrics, not cgroup limits or child-process totals.
  """
  use GenServer
  alias Supavisor.Monitoring.ModelMetrics

  @table __MODULE__
  @interval 5_000
  @history_limit 120
  @topic "admin:metrics"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def subscribe, do: Phoenix.PubSub.subscribe(Supavisor.PubSub, @topic)
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(Supavisor.PubSub, @topic)

  def snapshot do
    case :ets.lookup(@table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    ModelMetrics.init()

    state = %{
      previous: nil,
      history: :queue.new(),
      count: 0,
      started_at: DateTime.utc_now(),
      started: System.monotonic_time(:second)
    }

    {:ok, sample(state)}
  end

  @impl true
  def handle_info(:sample, state), do: {:noreply, sample(state)}

  @impl true
  def terminate(_, _), do: ModelMetrics.detach()

  defp sample(state) do
    system = read_system()
    {app_cpu, server_cpu} = cpu_percentages(system.cpu, state.previous)
    app_memory_percent = percent(system.app_rss, system.total_memory)
    server_memory_percent = percent(system.used_memory, system.total_memory)
    time = System.system_time(:second)
    plot_time = System.monotonic_time(:second)

    point = %{
      time: plot_time,
      app_cpu: app_cpu,
      server_cpu: server_cpu,
      app_memory: app_memory_percent,
      server_memory: server_memory_percent
    }

    history = :queue.in(point, state.history)
    history = if state.count >= @history_limit, do: :queue.drop(history), else: history
    models = ModelMetrics.snapshot()
    completed = Enum.reduce(models, 0, &(&1.completed + &2))
    errors = Enum.reduce(models, 0, &(&1.errors + &2))
    in_flight = Enum.reduce(models, 0, &(&1.in_flight + &2))

    snapshot = %{
      time: time,
      plot_time: plot_time,
      started_at: state.started_at,
      uptime_seconds: System.monotonic_time(:second) - state.started,
      interval_seconds: div(@interval, 1000),
      history: :queue.to_list(history),
      app_rss: system.app_rss,
      total_memory: system.total_memory,
      used_memory: system.used_memory,
      available_memory: system.available_memory,
      app_memory_percent: app_memory_percent,
      server_memory_percent: server_memory_percent,
      app_cpu: app_cpu,
      server_cpu: server_cpu,
      cpu_count: system.cpu_count,
      models: models,
      completed: completed,
      errors: errors,
      in_flight: in_flight
    }

    :ets.insert(@table, {:snapshot, snapshot})
    Phoenix.PubSub.broadcast(Supavisor.PubSub, @topic, :metrics_updated)
    Process.send_after(self(), :sample, @interval)
    %{state | previous: system.cpu, history: history, count: min(state.count + 1, @history_limit)}
  end

  defp read_system do
    memory = read_kilobytes("/proc/meminfo")
    process = read_kilobytes("/proc/self/status")
    total = memory["MemTotal"]
    available = memory["MemAvailable"]
    used = if is_integer(total) && is_integer(available), do: max(0, total - available)
    {cpu, cpu_count} = read_cpu()

    %{
      total_memory: total,
      available_memory: available,
      used_memory: used,
      app_rss: process["VmRSS"],
      cpu: cpu,
      cpu_count: cpu_count
    }
  end

  defp read_kilobytes(path) do
    case File.read(path) do
      {:ok, content} ->
        for [_, key, value] <-
              Regex.scan(~r/^(MemTotal|MemAvailable|VmRSS):\s+(\d+)\s+kB/m, content),
            into: %{},
            do: {key, String.to_integer(value) * 1024}

      _ ->
        %{}
    end
  end

  defp read_cpu do
    with {:ok, host} <- File.read("/proc/stat"),
         {:ok, process} <- File.read("/proc/self/stat"),
         [_, process_fields] <- Regex.run(~r/^\d+ \(.*\) (.+)$/s, process) do
      [cpu_line | lines] = String.split(host, "\n")
      ticks = cpu_line |> String.split() |> tl() |> Enum.take(8) |> Enum.map(&String.to_integer/1)
      process_fields = String.split(process_fields)

      app_ticks =
        String.to_integer(Enum.at(process_fields, 11)) +
          String.to_integer(Enum.at(process_fields, 12))

      idle = Enum.at(ticks, 3) + Enum.at(ticks, 4)
      cpu_count = Enum.count(lines, &Regex.match?(~r/^cpu\d+\s/, &1))
      {%{total: Enum.sum(ticks), idle: idle, app: app_ticks, count: cpu_count}, cpu_count}
    else
      _ -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  defp cpu_percentages(%{count: count} = current, %{count: count} = previous) do
    elapsed = current.total - previous.total
    busy = elapsed - (current.idle - previous.idle)
    app = current.app - previous.app

    if elapsed > 0 && app >= 0,
      do: {percent(app, elapsed), percent(busy, elapsed)},
      else: {nil, nil}
  end

  defp cpu_percentages(_, _), do: {nil, nil}

  defp percent(value, total) when is_number(value) and is_number(total) and total > 0,
    do: Float.round(min(100.0, max(0.0, value / total * 100)), 2)

  defp percent(_, _), do: nil
end
