defmodule SupavisorWeb.Admin.MetricsLive do
  use SupavisorWeb, :live_view
  alias Supavisor.Monitoring.ConsoleMetrics
  alias SupavisorWeb.AdminAuth

  @services %{
    ai_model: %{label: "AI model", icon: "hero-sparkles"},
    embedding: %{label: "Embedding", icon: "hero-cube-transparent"},
    stt: %{label: "STT", icon: "hero-microphone"},
    tts: %{label: "TTS", icon: "hero-speaker-wave"}
  }

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: ConsoleMetrics.subscribe()

    {:ok,
     socket
     |> assign(paused: false, metrics_session: session, metrics: nil)
     |> stream(:models, [])
     |> load_snapshot()}
  end

  @impl true
  def handle_event("toggle_updates", _, socket) do
    if socket.assigns.paused do
      ConsoleMetrics.subscribe()
      {:noreply, socket |> assign(:paused, false) |> load_snapshot()}
    else
      ConsoleMetrics.unsubscribe()
      {:noreply, assign(socket, :paused, true)}
    end
  end

  @impl true
  def handle_info(:metrics_updated, %{assigns: %{paused: true}} = socket), do: {:noreply, socket}

  def handle_info(:metrics_updated, socket) do
    case AdminAuth.authenticate_session(socket.assigns.metrics_session) do
      {:ok, _} -> {:noreply, load_snapshot(socket)}
      :error -> {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  defp load_snapshot(socket) do
    case ConsoleMetrics.snapshot() do
      nil ->
        assign(socket, :metrics, nil)

      metrics ->
        socket
        |> assign(
          metrics: Map.drop(metrics, [:history, :models]),
          cpu_chart: chart(metrics.history, :app_cpu, :server_cpu, metrics.plot_time),
          memory_chart: chart(metrics.history, :app_memory, :server_memory, metrics.plot_time)
        )
        |> stream(:models, Enum.map(metrics.models, &Map.merge(&1, Map.fetch!(@services, &1.id))))
    end
  end

  defp chart(history, app_key, server_key, now) do
    %{app: line(history, app_key, now), server: line(history, server_key, now)}
  end

  defp line(history, key, now) do
    {parts, _connected, last} =
      Enum.reduce(history, {[], false, nil}, fn point, {path, connected, last} ->
        case point[key] do
          value when is_number(value) ->
            x = Float.round(40 + max(0, 1 - (now - point.time) / 600) * 530, 1)
            y = Float.round(155 - value / 100 * 135, 1)
            command = if connected, do: "L", else: "M"
            {["#{command}#{x},#{y}" | path], true, {x, y}}

          _ ->
            {path, false, last}
        end
      end)

    %{path: parts |> Enum.reverse() |> Enum.join(" "), last: last}
  end

  defp bytes(nil), do: "—"

  defp bytes(value) when value >= 1_073_741_824,
    do: "#{Float.round(value / 1_073_741_824, 1)} GiB"

  defp bytes(value), do: "#{Float.round(value / 1_048_576, 1)} MiB"
  defp percentage(nil), do: "—"
  defp percentage(value), do: "#{Float.round(value * 1.0, 1)}%"
  defp meter(nil), do: "width: 0%"
  defp meter(value), do: "width: #{min(100, max(0, value))}%"
  defp duration(nil), do: "—"
  defp duration(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 2)} s"
  defp duration(ms), do: "#{Float.round(ms * 1.0, 1)} ms"

  defp clock(time),
    do:
      time
      |> DateTime.from_unix!()
      |> DateTime.to_time()
      |> Time.to_string()
      |> String.slice(0, 8)

  attr :chart, :map, required: true
  attr :title, :string, required: true

  defp history_chart(assigns) do
    ~H"""
    <svg class="metrics-chart" viewBox="0 0 600 190" role="img" aria-label={@title}>
      <title><%= @title %></title>
      <g class="chart-grid"><line x1="40" y1="20" x2="570" y2="20" /><line x1="40" y1="87.5" x2="570" y2="87.5" /><line x1="40" y1="155" x2="570" y2="155" /></g>
      <g class="chart-axis"><text x="0" y="24">100%</text><text x="7" y="91.5">50%</text><text x="14" y="159">0%</text><text x="40" y="183">−10 min</text><text x="546" y="183">Now</text></g>
      <path class="chart-line chart-server" d={@chart.server.path} /><path class="chart-line chart-app" d={@chart.app.path} />
      <circle :if={@chart.server.last} class="chart-dot chart-server" cx={elem(@chart.server.last, 0)} cy={elem(@chart.server.last, 1)} r="3" />
      <circle :if={@chart.app.last} class="chart-dot chart-app" cx={elem(@chart.app.last, 0)} cy={elem(@chart.app.last, 1)} r="3" />
    </svg>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-hero">
      <div><div class="eyebrow"><span class="eyebrow-line"></span> A PULSE ON YOUR STACK</div><h1>Metrics<span class="heading-dot">.</span></h1><p class="page-subtitle">Your resources and model traffic. Just the numbers that matter.</p></div>
      <button type="button" class="secondary-button" phx-click="toggle_updates"><span class={if @paused, do: "hero-play", else: "hero-pause"}></span><%= if @paused, do: "Resume live", else: "Pause live" %></button>
    </section>
    <div :if={@metrics == nil} class="notice" role="status">The metrics collector is starting. Live readings will appear shortly.</div>
    <div :if={@metrics} class="metrics-workspace">
      <div class="metrics-status-line"><span class={["status-badge", @paused && "pending"]}><i class="status-dot"></i><%= if @paused, do: "Paused", else: "Live · every 5 seconds" %></span><span>Updated <%= clock(@metrics.time) %> UTC <span class="metrics-status-divider">/</span> This server</span></div>
      <div class="stats-grid metrics-stats">
        <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-cube"></span></span><span class="stat-label">Supavisor RAM</span></div><div class="stat-value"><%= bytes(@metrics.app_rss) %></div><div class="stat-hint"><%= percentage(@metrics.app_memory_percent) %> of <%= bytes(@metrics.total_memory) %> server RAM</div><div class="metric-meter"><span style={meter(@metrics.app_memory_percent)}></span></div></article>
        <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-server-stack"></span></span><span class="stat-label">Server RAM</span></div><div class="stat-value"><%= bytes(@metrics.used_memory) %></div><div class="stat-hint"><%= bytes(@metrics.available_memory) %> available · <%= percentage(@metrics.server_memory_percent) %> used</div><div class="metric-meter server"><span style={meter(@metrics.server_memory_percent)}></span></div></article>
        <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-cpu-chip"></span></span><span class="stat-label">Supavisor CPU</span></div><div class="stat-value"><%= percentage(@metrics.app_cpu) %></div><div class="stat-hint">Share of total server CPU capacity</div><div class="metric-meter"><span style={meter(@metrics.app_cpu)}></span></div></article>
        <article class="stat-card"><div class="stat-head"><span class="stat-icon"><span class="hero-chart-bar"></span></span><span class="stat-label">Server CPU</span></div><div class="stat-value"><%= percentage(@metrics.server_cpu) %></div><div class="stat-hint"><%= @metrics.cpu_count || "—" %> logical CPUs · all processes</div><div class="metric-meter server"><span style={meter(@metrics.server_cpu)}></span></div></article>
      </div>
      <div class="metrics-charts-grid">
        <section class="data-panel metrics-chart-panel"><div class="metrics-panel-heading"><div><h2>CPU activity</h2><p>Percentage of total server capacity</p></div><span class="metrics-window">10 MIN</span></div><div class="chart-legend"><span><i class="app"></i>Supavisor</span><span><i class="server"></i>Server</span></div><.history_chart chart={@cpu_chart} title="Supavisor and server CPU usage over the last 10 minutes, from 0 to 100 percent" /></section>
        <section class="data-panel metrics-chart-panel"><div class="metrics-panel-heading"><div><h2>Memory usage</h2><p>Percentage of physical server RAM</p></div><span class="metrics-window">10 MIN</span></div><div class="chart-legend"><span><i class="app"></i>Supavisor</span><span><i class="server"></i>Server</span></div><.history_chart chart={@memory_chart} title="Supavisor and server memory usage over the last 10 minutes, from 0 to 100 percent" /></section>
      </div>
      <section class="data-panel metrics-models">
        <div class="metrics-panel-heading"><div><div class="section-kicker">MODEL TRAFFIC</div><h2>Every request, accounted for.</h2><p>Completed requests, including failures, since the collector started.</p></div><span class="metrics-total"><strong><%= @metrics.completed %></strong> processed</span></div>
        <div class="metrics-traffic-summary"><span><i class="status-dot"></i><strong><%= @metrics.in_flight %></strong> in progress</span><span><span class="hero-exclamation-circle"></span><strong><%= @metrics.errors %></strong> errors</span><span>Started <%= Calendar.strftime(@metrics.started_at, "%d %b · %H:%M UTC") %></span></div>
        <div class="table-scroll"><table class="responsive-table metrics-model-table"><thead><tr><th>Service</th><th>Completed</th><th>Errors</th><th>In progress</th><th>Avg. duration</th></tr></thead><tbody id="model-metrics" phx-update="stream"><tr :for={{id, model} <- @streams.models} id={id}><td class="name-cell"><span class="resource-icon"><span class={model.icon}></span></span><div><strong><%= model.label %></strong><small :if={model.completed == 0 and model.in_flight == 0} class="table-secondary">Awaiting requests</small></div></td><td data-label="Completed" class="mono"><%= model.completed %></td><td data-label="Errors" class={["mono", model.errors > 0 && "metric-error"]}><%= model.errors %></td><td data-label="In progress" class="mono"><%= model.in_flight %></td><td data-label="Avg. duration" class="mono muted"><%= duration(model.average_ms) %></td></tr></tbody></table></div>
        <p :if={@metrics.completed == 0 and @metrics.in_flight == 0} class="metrics-empty-note"><span class="hero-information-circle"></span>No model traffic yet. Model providers still need to be connected; counters will populate when instrumented requests run.</p>
      </section>
      <div class="metrics-footnotes"><div><span class="hero-bolt"></span><p><strong>Light by design.</strong> One shared sampler, 120 readings in memory and four service counters. No metric writes to PostgreSQL.</p></div><div><span class="hero-information-circle"></span><p>RAM is the Supavisor process’s resident memory. CPU is averaged across all server CPUs. History and totals reset when the collector restarts; unavailable readings show “—”.</p></div></div>
    </div>
    """
  end
end
