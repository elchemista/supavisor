defmodule SupavisorWeb.Admin.LocalModelsLive do
  use SupavisorWeb, :live_view
  alias Supavisor.Services.{LocalModels, Inference}
  alias Supavisor.Services.LocalModels.Models
  alias SupavisorWeb.Admin.ServiceUI, as: UI

  @impl true
  def mount(_, session, socket) do
    if connected?(socket), do: LocalModels.subscribe()
    UI.subscribe(socket)

    {:ok,
     socket
     |> assign(
       service_session: session,
       model: nil,
       dirty: false,
       scanning: false,
       catalog_error: nil,
       tab: "model",
       base_url: SupavisorWeb.Endpoint.url()
     )
     |> stream(:files, [])
     |> stream(:jobs, [])}
  end

  @impl true
  def handle_params(_, _, socket) do
    service = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(
       service: service,
       title: if(service == :ai_model, do: "AI model", else: String.upcase(to_string(service))),
       model: nil,
       directory: LocalModels.directory_label(service),
       tab: "model"
     )
     |> update_snapshot()
     |> scan()}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["model", "requests", "examples"],
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("refresh", _, socket), do: {:noreply, scan(socket)}

  def handle_event(action, _, socket) when action in ["load", "unload"] do
    case UI.check_session(socket) do
      {:ok, _} ->
        action = if action == "load", do: :load, else: :unload

        case Inference.manage(socket.assigns.service, action, UI.principal(socket)) do
          {:ok, _} ->
            {:noreply,
             socket
             |> clear_flash()
             |> update_snapshot()}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, error.message)}
        end

      _ ->
        {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  @impl true
  def handle_async({:catalog, service}, {:ok, model}, socket)
      when service == socket.assigns.service do
    {:noreply,
     socket
     |> assign(model: model, scanning: false, catalog_error: nil)
     |> UI.sync_stream(:files, model.files)
     |> update_snapshot()}
  end

  def handle_async({:catalog, service}, _, socket) when service == socket.assigns.service,
    do:
      {:noreply,
       assign(socket,
         scanning: false,
         catalog_error: "Could not read model files. Check the directory and permissions."
       )}

  def handle_async(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:local_models_changed, service}, socket),
    do:
      {:noreply, if(service == socket.assigns.service, do: update_snapshot(socket), else: socket)}

  def handle_info(:services_changed, socket), do: {:noreply, assign(socket, :dirty, true)}

  def handle_info(:service_tick, socket) do
    Process.send_after(self(), :service_tick, 1000)

    case UI.check_session(socket) do
      {:ok, _} -> {:noreply, if(socket.assigns.dirty, do: update_snapshot(socket), else: socket)}
      _ -> {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  defp scan(socket) do
    service = socket.assigns.service

    socket
    |> assign(:scanning, true)
    |> start_async({:catalog, service}, fn -> Models.info(service) end)
  end

  defp update_snapshot(socket) do
    snapshot = LocalModels.snapshot(socket.assigns.service)
    queue = Inference.snapshot()
    graphs = Models.definition(socket.assigns.service).graphs
    jobs = Enum.filter(queue.jobs, &(&1.service == socket.assigns.service))

    socket
    |> assign(
      snapshot: snapshot,
      loaded: Enum.all?(graphs, &Map.has_key?(snapshot.loaded, &1)),
      partial: Enum.any?(graphs, &Map.has_key?(snapshot.loaded, &1)),
      busy: not is_nil(queue.running) or queue.queued > 0 or not is_nil(snapshot.busy),
      queued: Enum.count(jobs, &(&1.status == "queued")),
      running: Enum.find(jobs, &(&1.status == "running")),
      job_count: length(jobs),
      dirty: false
    )
    |> UI.sync_stream(:jobs, jobs)
  end

  defp size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp api_service(:ai_model), do: "ai"
  defp api_service(service), do: to_string(service)

  defp payload(:tts),
    do: %{
      model: Models.definition(:tts).id,
      input: "Ciao! Il servizio vocale è pronto.",
      voice: "if_sara",
      speed: 1.0
    }

  defp payload(:stt), do: %{model: Models.definition(:stt).id, audio_id: "AUDIO_ID"}

  defp payload(:ai_model),
    do: %{
      model: Models.definition(:ai_model).id,
      messages: [%{role: "user", content: "Explain connection pooling in one sentence."}],
      max_tokens: 128
    }

  defp rest_example(assigns) do
    base = assigns.base_url <> "/api/services/v1"

    upload =
      if assigns.service == :stt,
        do:
          "# Upload a recording (up to 25 MiB, 30 seconds). Copy the returned id.\ncurl '#{base}/audio' \\\n  -H \"Authorization: Bearer $SERVICE_TOKEN\" \\\n  -F 'file=@recording.mp3'\n\n",
        else: ""

    download =
      if assigns.service == :tts,
        do:
          "\n\n# When completed, use result.audio.download_url with the same token:\ncurl '#{base}/audio/AUDIO_ID' \\\n  -H \"Authorization: Bearer $SERVICE_TOKEN\" --output speech.mp3",
        else: ""

    upload <>
      "curl '#{base}/#{api_service(assigns.service)}' \\\n  -H \"Authorization: Bearer $SERVICE_TOKEN\" \\\n  -H 'Content-Type: application/json' \\\n  -d '#{Jason.encode!(payload(assigns.service), pretty: true)}'\n\n# HTTP 202 returns a request id. Poll until completed or failed:\ncurl '#{base}/requests/REQUEST_ID' \\\n  -H \"Authorization: Bearer $SERVICE_TOKEN\"" <>
      download
  end

  defp websocket_example(assigns) do
    base =
      assigns.base_url
      |> String.replace_prefix("https://", "wss://")
      |> String.replace_prefix("http://", "ws://")

    upload =
      if assigns.service == :stt,
        do:
          "\n// Upload over this channel; each chunk is acknowledged before the next.\nconst file = document.querySelector('input[type=file]').files[0];\nconst upload = await push('audio:upload:start', {filename: file.name, bytes: file.size});\nfor (let offset = 0; offset < file.size; offset += 49152) {\n  const bytes = new Uint8Array(await file.slice(offset, offset + 49152).arrayBuffer());\n  await push('audio:upload:chunk', {id: upload.id, offset, data: btoa(String.fromCharCode(...bytes))});\n}\nconst audio = await push('audio:upload:finish', {id: upload.id});\nconst job = await push('stt:run', {model: 'whisper-it-distil-int8', audio_id: audio.id});",
        else:
          "\nconst job = await push('#{api_service(assigns.service)}:run', #{Jason.encode!(payload(assigns.service), pretty: true)});"

    "import {Socket} from 'phoenix';\nconst socket = new Socket('#{base}/services/socket');\nsocket.connect();\nconst channel = socket.channel('services:gateway', {token: SERVICE_TOKEN});\nconst push = (event, body) => new Promise((resolve, reject) => {\n  channel.push(event, body, 30000).receive('ok', resolve).receive('error', reject).receive('timeout', () => reject(new Error('Timed out')));\n});\nchannel.on('request:update', job => console.log(job.status, job.result, job.error));\nawait new Promise((resolve, reject) => channel.join().receive('ok', resolve).receive('error', reject));\n" <>
      upload <>
      "\n// After reconnecting, retrieve a request with:\nawait push('request:get', {id: job.id});"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <UI.header title={@title} subtitle="Your model, ready for REST and WebSocket requests.">
      <:actions><.link navigate={~p"/admin/api"} class="secondary-button"><span class="hero-key"></span>Manage API keys</.link></:actions>
    </UI.header>
    <div class="summary-line">
      <div><span>Model files</span><strong>{cond do @scanning -> "Checking…"; @model && @model.ready -> "Ready"; true -> "Incomplete" end}</strong></div>
      <div><span>Memory</span><strong>{if @loaded, do: "Loaded", else: "Standby"}</strong></div>
      <div><span>Processing</span><strong>{if @running, do: "1 request", else: "Idle"}</strong></div>
      <div><span>Queued</span><strong>{@queued}</strong></div>
    </div>
    <UI.tabs tabs={[{"model", "Model"}, {"requests", "Requests"}, {"examples", "API / WebSocket"}]} active={@tab}/>
    <p :if={@catalog_error || @snapshot.error} class="notice notice-error" role="alert">{@catalog_error || @snapshot.error}</p>
    <div :if={@snapshot.busy || @running} class="operation-banner" role="status"><span class="hero-arrow-path spin-slow"></span><div><strong>{if @running, do: "#{@running.kind} · #{@running.model}", else: "Updating model memory…"}</strong></div></div>
    <section hidden={@tab != "model"}>
      <div class="workbench-toolbar">
        <div><h2>{Models.definition(@service).name}</h2><p class="workspace-footnote">{if @model, do: "#{size(@model.bytes)} on disk · #{length(@model.files)} files", else: "Reading model files…"}</p></div>
        <div class="toolbar-actions">
          <button id="load-model" type="button" class="primary-button" phx-click="load" disabled={not @snapshot.available or @busy or @loaded or is_nil(@model) or not @model.ready}><span class="hero-play"></span>Load model</button>
          <button id="unload-model" type="button" class="secondary-button" phx-click="unload" disabled={@busy or not @partial}><span class="hero-stop"></span>Release RAM</button>
        </div>
      </div>
      <p class="workspace-footnote">The first API request loads the model automatically. After 5 minutes without use, its RAM is released. Downloaded model files stay on disk.</p>
      <p :if={not @snapshot.available} class="notice notice-error">Model processing is disabled on this server.</p>
      <p :if={@model && not @model.ready} class="notice notice-error">Missing files: {Enum.join(@model.missing, ", ")}</p>
      <dl class="detail-list">
        <div><dt>Model ID</dt><dd><code>{Models.definition(@service).id}</code></dd></div>
        <div><dt>API permission</dt><dd><code>{Models.scope(@service)}</code></dd></div>
        <div :if={@service == :tts}><dt>Output</dt><dd>MP3 · 24 kHz · private authenticated download</dd></div>
        <div :if={@service == :stt}><dt>Input</dt><dd>MP3, WAV, OGG, FLAC, WebM, M4A · up to 25 MiB / 30 seconds · Italian</dd></div>
        <div :if={@service == :ai_model}><dt>Generation limits</dt><dd>512 input tokens · up to 256 output tokens · non-thinking mode</dd></div>
        <div :if={@service in [:tts, :stt]}><dt>Audio retention</dt><dd>3 days · automatic cleanup with Oban</dd></div>
        <div :if={@service == :tts}><dt>Voices</dt><dd>{Enum.join(Supavisor.Services.LocalModels.Adapters.Kokoro.voices(), ", ")}</dd></div>
      </dl>
      <div class="workbench-toolbar"><div><h2>Model files</h2><p class="workspace-footnote"><code>{@directory}</code></p></div><button id="refresh-model-files" class="secondary-button" type="button" phx-click="refresh" disabled={@scanning}><span class={[@scanning && "spin-slow", "hero-arrow-path"]}></span>Refresh files</button></div>
      <details class="inline-section"><summary>View files and sizes</summary><div class="service-table-wrap"><table class="service-table"><thead><tr><th>File</th><th>Size</th><th>Status</th></tr></thead><tbody id="model-files" phx-update="stream"><tr :for={{dom_id, file} <- @streams.files} id={dom_id}><td><code>{file.path}</code></td><td>{size(file.bytes)}</td><td><span class="state-label state-success">Present</span></td></tr></tbody></table></div></details>
    </section>
    <section hidden={@tab != "requests"}>
      <h2 class="section-heading">Request queue</h2>
      <div class="service-table-wrap"><table class="service-table"><thead><tr><th>Request</th><th>Operation</th><th>Status</th><th>Created</th><th>Details</th></tr></thead><tbody id="model-requests" phx-update="stream"><tr :for={{dom_id, job} <- @streams.jobs} id={dom_id}><td><code>{UI.short(job.id)}</code></td><td>{job.kind}</td><td><span class={UI.status_class(job.status)}>{job.status}</span></td><td>{UI.time(job.inserted_at)}</td><td>{job.error || "—"}</td></tr></tbody></table></div>
      <p :if={@job_count == 0} class="table-empty">No requests yet. Use the API / WebSocket examples to call this model.</p>
      <p class="workspace-footnote">Requests run one at a time across these CPU models. Up to 10 requests can wait. Results expire after 5 minutes; request history resets on restart.</p>
    </section>
    <section hidden={@tab != "examples"}>
      <p class="workspace-footnote">Create a key in <.link navigate={~p"/admin/api"}>API</.link> with <code>{Models.scope(@service)}</code> and the transports you use. Existing keys keep their current permissions.</p>
      <div class="example-workbench">
        <div><h2 class="section-heading">REST</h2><pre class="code-sample"><code>{rest_example(assigns)}</code></pre></div>
        <div><h2 class="section-heading">WebSocket · Phoenix Channels</h2><pre class="code-sample"><code>{websocket_example(assigns)}</code></pre></div>
      </div>
      <p class="workspace-footnote">Tokens belong in the Authorization header or channel join payload, never in a URL. REST returns HTTP 202; WebSocket sends request:update when processing finishes. Request results are available for 5 minutes.</p>
      <p :if={@service == :tts} class="workspace-footnote">Download the resulting MP3 using result.audio.download_url and the same Bearer token (enable REST on the key). Audio is streamed by Phoenix and expires after 3 days.</p>
    </section>
    """
  end
end
