defmodule SupavisorWeb.Admin.EmbeddingLive do
  use SupavisorWeb, :live_view
  alias Supavisor.Services.Embeddings
  alias SupavisorWeb.Admin.ServiceUI, as: UI
  alias Supavisor.Monitoring.ConsoleMetrics

  @impl true
  def mount(_, session, socket) do
    UI.subscribe(socket)

    if connected?(socket) do
      Embeddings.refresh_sizes()
      ConsoleMetrics.subscribe()
    end

    {:ok,
     socket
     |> assign(
       service_session: session,
       tab: "models",
       search: "",
       sort: "name",
       selected: nil,
       dirty: false,
       base_url: "",
       preview: nil,
       snapshot: Embeddings.snapshot()
     )
     |> stream(:models, [])
     |> stream(:jobs, [])
     |> load()}
  end

  @impl true
  def handle_params(_, uri, socket) do
    url =
      URI.parse(uri)
      |> Map.put(:path, "")
      |> Map.put(:query, nil)
      |> Map.put(:fragment, nil)
      |> URI.to_string()

    {:noreply, assign(socket, :base_url, url)}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["models", "requests", "examples"],
    do: {:noreply, assign(socket, :tab, tab) |> load()}

  def handle_event("search", %{"search" => search} = params, socket),
    do:
      {:noreply,
       socket
       |> assign(search: String.slice(search, 0, 100), sort: params["sort"] || "name")
       |> load()}

  def handle_event("refresh_sizes", _, socket) do
    Embeddings.refresh_sizes()
    {:noreply, load(socket)}
  end

  def handle_event(action, params, socket) when action in ["unload", "delete_model"] do
    with {:ok, _} <- UI.check_session(socket) do
      result =
        if action == "unload",
          do: Embeddings.unload(UI.principal(socket)),
          else: Embeddings.delete(params["model"], UI.principal(socket))

      case result do
        {:ok, _} ->
          {:noreply,
           load(socket)
           |> put_flash(:info, "Model operation started. Follow its status in Requests.")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error.message)}
      end
    else
      _ -> {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  def handle_event("select_model", %{"model" => name}, socket) do
    {:noreply,
     socket
     |> assign(:selected, Enum.find(socket.assigns.snapshot.models, &(&1.name == name)))
     |> load()
     |> push_event("embedding:inspect", %{})}
  end

  def handle_event("activate", %{"model" => name}, socket) do
    case Embeddings.activate(name, UI.principal(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Model activation queued. Downloads run in the background.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Embeddings.cancel(id, UI.principal(socket)) do
      {:ok, _} -> {:noreply, load(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("preview", %{"text" => text}, socket) do
    case Embeddings.submit(%{"input" => text}, UI.principal(socket)) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:preview, job.id)
         |> load()
         |> put_flash(:info, "Embedding request queued.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  @impl true
  def handle_info(:services_changed, socket), do: {:noreply, assign(socket, :dirty, true)}

  def handle_info(:metrics_updated, socket),
    do: {:noreply, assign(socket, :memory, ConsoleMetrics.snapshot())}

  def handle_info(:service_tick, socket) do
    Process.send_after(self(), :service_tick, 1000)

    case UI.check_session(socket) do
      {:ok, _} -> {:noreply, if(socket.assigns.dirty, do: load(socket), else: socket)}
      _ -> {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  defp load(socket) do
    snapshot = Embeddings.snapshot()
    query = String.downcase(socket.assigns.search)

    models =
      Enum.filter(
        snapshot.models,
        &String.contains?(String.downcase(&1.name <> " " <> &1.repository), query)
      )
      |> Enum.sort_by(fn model ->
        if socket.assigns.sort == "size",
          do: {is_nil(model.download_bytes), model.download_bytes || 0, model.name},
          else: model.name
      end)

    selected =
      if socket.assigns.selected,
        do: Enum.find(snapshot.models, &(&1.name == socket.assigns.selected.name)),
        else: Enum.find(snapshot.models, &(&1.name == snapshot.active)) || List.first(models)

    preview =
      if socket.assigns.preview do
        case Embeddings.request(socket.assigns.preview, UI.principal(socket)) do
          {:ok, job} -> job
          _ -> nil
        end
      end

    socket
    |> assign(
      snapshot: snapshot,
      selected: selected,
      model_count: length(models),
      dirty: false,
      preview_result: preview,
      memory: ConsoleMetrics.snapshot(),
      model_busy: not is_nil(snapshot.running) or snapshot.queued > 0,
      shared_active:
        selected &&
          Enum.any?(
            snapshot.models,
            &(&1.name == snapshot.loaded and &1.repository == selected.repository)
          )
    )
    |> UI.sync_stream(
      :models,
      Enum.map(
        models,
        &Map.merge(&1, %{
          id: &1.name,
          selected: selected && selected.name == &1.name,
          active: snapshot.active == &1.name,
          loaded: snapshot.loaded == &1.name
        })
      )
    )
    |> UI.sync_stream(:jobs, snapshot.jobs)
  end

  defp example_model(assigns),
    do: (assigns.selected && assigns.selected.name) || assigns.snapshot.active || "BGESmallENV15"

  defp rest_example(assigns) do
    body = Jason.encode!(%{model: example_model(assigns), input: ["Text to embed"]}, pretty: true)

    "curl #{assigns.base_url}/api/services/v1/embeddings \\\n  -H 'Authorization: Bearer YOUR_API_TOKEN' \\\n  -H 'Content-Type: application/json' \\\n  -d '#{body}'\n\n# HTTP 202 returns the request id. Retrieve the vector:\ncurl #{assigns.base_url}/api/services/v1/requests/REQUEST_ID \\\n  -H 'Authorization: Bearer YOUR_API_TOKEN'"
  end

  defp websocket_example(assigns) do
    "channel.on('request:update', job => {\n  if (job.status === 'completed') {\n    channel.push('request:get', {id: job.id})\n      .receive('ok', job => console.log(job.result.data))\n  }\n})\n\nchannel.push('embedding:run', {\n  model: '#{example_model(assigns)}',\n  input: ['Text to embed']\n}).receive('ok', job => console.log(job.id))"
  end

  defp size(nil), do: "Unavailable"
  defp size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp size(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GiB"

  defp job_title("model.load"), do: "Model activation"
  defp job_title("model.unload"), do: "Release model RAM"
  defp job_title("model.sleep"), do: "Idle timeout · releasing RAM"
  defp job_title("model.delete"), do: "Delete cached files"
  defp job_title(_), do: "Generate embeddings"

  defp memory_label("loaded"), do: "Loaded in RAM"
  defp memory_label("standby"), do: "Standby"
  defp memory_label("loading"), do: "Loading…"
  defp memory_label("unloading"), do: "Releasing RAM…"
  defp memory_label(_), do: "Not configured"

  defp delete_confirmation(selected, models) do
    variants =
      models
      |> Enum.filter(&(&1.repository == selected.repository))
      |> Enum.map_join(", ", & &1.name)

    "Delete the downloaded repository cache for #{selected.repository} (#{size(selected.disk_bytes)})? This removes the shared files for these variants: #{variants}. They can be downloaded again."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <UI.header
      title="Embedding"
      subtitle="Download a model, activate it and generate vectors on this server."
    >
      <:actions><span class="status-badge"><i class="status-dot"></i>ex_fastembed</span></:actions>
    </UI.header>
    <div class="summary-line">
      <div>
        <span>Configured model</span>
        <strong>
          <button :if={@snapshot.active} type="button" class="active-model-link"
            phx-click="select_model" phx-value-model={@snapshot.active}
            aria-label={"Manage active model " <> @snapshot.active}>
            {@snapshot.active}<span class="hero-arrow-up-right"></span>
          </button>
          <span :if={is_nil(@snapshot.active)}>None selected</span>
        </strong>
      </div>
      <div><span>Memory</span><strong>{memory_label(@snapshot.memory_state)}</strong></div>
      <div><span>Queued</span><strong><%= @snapshot.queued %> / 20</strong></div>
      <div>
        <span>Processing</span><strong><%= if @snapshot.running, do: @snapshot.running.model, else: "Idle" %></strong>
      </div>
      <div>
        <span>Downloaded</span><strong><%= Enum.count(@snapshot.models, & &1.cached) %></strong>
      </div>
    </div>
    <p :if={@snapshot.error} class="notice notice-error">{@snapshot.error}</p>
    <div :if={@snapshot.running && (String.starts_with?(@snapshot.running.kind, "model.") or @snapshot.running.phase == "loading_model")} class="operation-banner">
      <span class="hero-arrow-path spin-slow"></span>
      <div>
        <strong>{if @snapshot.running.phase == "loading_model", do: "Loading model for request", else: job_title(@snapshot.running.kind)} · {@snapshot.running.model}</strong>
        <p>The operation runs in the background. Requests wait for the model to load.</p>
      </div>
    </div>
    <UI.tabs
      tabs={[{"models", "Model catalog"}, {"requests", "Requests"}, {"examples", "API examples"}]}
      active={@tab}
    />
    <div hidden={@tab != "models"} class="workbench-split embedding-workbench">
      <section id="embedding-catalog" class="workbench-list">
        <div class="workbench-toolbar">
          <form phx-change="search" class="embedding-catalog-filters">
            <div class="search-field">
            <span class="hero-magnifying-glass"></span>
            <input
              name="search"
              type="search"
              value={@search}
              placeholder="Search models or repositories"
              aria-label="Search models"
              phx-debounce="250"
            />
            </div>
            <select name="sort" aria-label="Sort models">
              <option value="name" selected={@sort == "name"}>Name</option>
              <option value="size" selected={@sort == "size"}>Smallest download</option>
            </select>
          </form>
          <button type="button" class="text-button" phx-click="refresh_sizes" disabled={@snapshot.sizes_loading}>
            {if @snapshot.sizes_loading, do: "Checking sizes…", else: "Refresh sizes"}
          </button>
        </div>
        <div class="service-table-wrap">
          <table class="service-table">
            <thead>
              <tr>
                <th>Model</th>
                <th>Dimensions</th>
                <th>Download size</th>
                <th>Availability</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="embedding-models" phx-update="stream">
              <tr
                :for={{id, model} <- @streams.models}
                id={id}
                class={model.selected && "selected-row"}
              >
                <td>
                  <button
                    class="text-button model-name"
                    phx-click="select_model"
                    phx-value-model={model.name}
                  >
                    {model.name}
                  </button>
                  <span class="table-subline">{model.repository}</span>
                  <span class={[
                    "embedding-mobile-status",
                    UI.status_class(if model.loaded, do: "completed", else: "idle")
                  ]}>
                    {cond do
                      model.loaded -> "Loaded"
                      model.active -> "Standby"
                      model.cached -> "Downloaded"
                      true -> "Not downloaded"
                    end}
                  </span>
                </td>
                <td class="mono">{model.dimension}</td>
                <td class="mono">{if is_nil(model.download_bytes) && @snapshot.sizes_loading, do: "Checking…", else: size(model.download_bytes)}</td>
                <td>
                  <span class={UI.status_class(if model.loaded, do: "completed", else: "idle")}>
                    {cond do
                      model.loaded -> "Loaded"
                      model.active -> "Standby"
                      model.cached -> "Downloaded"
                      true -> "Not downloaded"
                    end}
                  </span>
                </td>
                <td>
                  <button
                    class="icon-button"
                    phx-click="select_model"
                    phx-value-model={model.name}
                    aria-label={"Details for #{model.name}"}
                  >
                    <span class="hero-chevron-right"></span>
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@model_count == 0} class="table-empty">No matching models.</p>
      </section>
      <aside :if={@selected} id="embedding-inspector" class="inspector">
        <span class="inspector-kicker">MODEL DETAILS</span>
        <h2>{@selected.name}</h2>
        <p class="muted small">{@selected.repository}</p>
        <button
          class="primary-button"
          phx-click="activate"
          phx-value-model={@selected.name}
          disabled={
            @snapshot.loaded == @selected.name or
              (@snapshot.running && String.starts_with?(@snapshot.running.kind, "model."))
          }
        >
          <span class="hero-arrow-down-tray"></span>{cond do
            @snapshot.loaded == @selected.name -> "Loaded in RAM"
            @snapshot.active == @selected.name && @selected.cached -> "Load into RAM"
            @selected.cached -> "Activate model"
            true -> "Download & activate"
          end}
        </button>
        <div class="embedding-model-actions">
          <button :if={@shared_active} type="button" class="secondary-button"
            phx-click="unload" disabled={@model_busy}
            data-confirm="Release the embedding model's RAM now? Files and the configured model will be kept. The next embedding request loads it again automatically.">
            <span class="hero-pause-circle"></span>Unload · release RAM
          </button>
          <button :if={@selected.disk_bytes > 0} type="button" class="danger-button"
            phx-click="delete_model" phx-value-model={@selected.name}
            disabled={@model_busy or @shared_active}
            data-confirm={delete_confirmation(@selected, @snapshot.models)}>
            Delete downloaded files
          </button>
        </div>
        <dl class="detail-list">
          <div>
            <dt>Task</dt>
            <dd>Text embedding</dd>
          </div>
          <div>
            <dt>Vector dimensions</dt>
            <dd>{@selected.dimension}</dd>
          </div>
          <div>
            <dt>Runtime</dt>
            <dd>ONNX · local CPU</dd>
          </div>
          <div>
            <dt>Files</dt>
            <dd>{if @selected.cached, do: "Cached on this server", else: "Download required"}</dd>
          </div>
          <div><dt>Variant download</dt><dd>{size(@selected.download_bytes)}</dd></div>
          <div><dt>Variant on disk</dt><dd>{size(@selected.variant_bytes)}</dd></div>
          <div><dt>Repository on disk</dt><dd>{size(@selected.disk_bytes)}</dd></div>
          <div><dt>Server RAM available</dt><dd>{size(@memory && @memory.available_memory)}</dd></div>
          <div><dt>App RAM (all services)</dt><dd>{size(@memory && @memory.app_rss)}</dd></div>
        </dl>
        <p class="field-help">Download size includes this variant's weights and required files. RAM depends on the model, runtime and batch size; it is not equal to the download size.</p>
        <p :if={@selected.sizes_stale} class="field-help">Showing previously checked download metadata. Refresh sizes to update it.</p>
        <p :if={@selected.disk_bytes > 0} class="field-help">Deletion removes this repository's shared cache and variants. Unload its active model first. No database data is deleted.</p>
        <p class="field-help">
          After 5 minutes without requests, the model releases its native session. The next request loads it from disk before running. Files and the configured model are kept, including across restarts. The first request after standby takes longer.
        </p>
        <a
          class="embedding-back-to-catalog row-link"
          href="#embedding-catalog"
        >
          <span class="hero-arrow-up"></span>Back to model catalog
        </a>
        <a
          class="row-link"
          href={"https://huggingface.co/#{@selected.repository}"}
          target="_blank"
          rel="noopener noreferrer"
        >
          Model card & license <span class="hero-arrow-up-right"></span>
        </a>
        <button class="text-button" phx-click="tab" phx-value-tab="examples">
          View API examples →
        </button>
      </aside>
    </div>
    <section hidden={@tab != "requests"}>
      <div class="workbench-toolbar">
        <div>
          <h2>Request queue</h2>
          <p class="muted small">One operation at a time. Last 20 results retained for 5 minutes.</p>
        </div>
      </div>
      <div class="service-table-wrap">
        <table class="service-table">
          <thead>
            <tr>
              <th>Request</th>
              <th>Model</th>
              <th>Status</th>
              <th>Started</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="embedding-jobs" phx-update="stream">
            <tr :for={{id, job} <- @streams.jobs} id={id}>
              <td>
                <strong>
                  {job_title(job.kind)}
                </strong>
                <span class="table-subline mono">{UI.short(job.id)}</span>
              </td>
              <td>{job.model}</td>
              <td>
                <span class={UI.status_class(job.status)}>{job.status}</span><span
                  :if={job.error}
                  class="table-subline error-text"
                ><%= job.error %></span>
              </td>
              <td class="small">{UI.time(job.started_at)}</td>
              <td>
                <button
                  :if={job.status == "queued"}
                  class="text-button"
                  phx-click="cancel"
                  phx-value-id={job.id}
                >
                  Cancel
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@snapshot.jobs == []} class="table-empty">
        No requests yet. Activate a model, then submit text through the API or the preview below.
      </p>
      <section class="inline-section">
        <h2>Preview an embedding</h2>
        <form phx-submit="preview" class="inline-compose">
          <.input
            type="textarea"
            name="text"
            value=""
            label="Text"
            rows="3"
            maxlength="4096"
            placeholder="Enter a short text…"
          />
          <button class="secondary-button" disabled={is_nil(@snapshot.active)}>
            Generate embedding
          </button>
        </form>
        <div :if={@preview_result} class="result-preview">
          <span class={UI.status_class(@preview_result.status)}>{@preview_result.status}</span>
          <p :if={@preview_result.result}>
            Generated {@preview_result.result.input_count} vector · {length(
              hd(@preview_result.result.data).embedding
            )} dimensions.
          </p>
          <pre :if={@preview_result.result}><%= @preview_result.result.data |> hd() |> Map.get(:embedding) |> Enum.take(12) |> UI.pretty() %> …</pre>
          <p :if={@preview_result.error} class="error-text">{@preview_result.error}</p>
        </div>
      </section>
    </section>
    <section hidden={@tab != "examples"} class="example-workbench">
      <div>
        <h2>REST</h2>
        <p>Activate the selected model first. The key needs <code>embedding:run</code>.</p>
        <pre class="code-sample"><code><%= rest_example(assigns) %></code></pre>
      </div>
      <div>
        <h2>WebSocket</h2>
        <p>
          Join <code>services:gateway</code>
          with your token. Responses use the same request IDs as REST.
        </p>
        <pre class="code-sample"><code><%= websocket_example(assigns) %></code></pre>
      </div>
    </section>
    """
  end
end
