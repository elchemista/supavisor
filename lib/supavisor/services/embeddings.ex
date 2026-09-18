defmodule Supavisor.Services.Embeddings do
  @moduledoc "Serializes FastEmbed model activation and inference; vectors stay in bounded, expiring ETS storage."
  use GenServer
  alias Supavisor.Services.{Events, EmbeddingFiles, ModelIdle}
  alias Supavisor.ServiceAPI.KeyCache
  alias Supavisor.Monitoring.ModelMetrics
  @table __MODULE__
  @max_pending 20
  @max_results 20
  @ttl 300

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def snapshot do
    case :ets.lookup(@table, :snapshot) do
      [{_, value}] -> value
      _ -> empty()
    end
  rescue
    _ -> empty()
  end

  defp empty,
    do: %{
      models: [],
      active: nil,
      loaded: nil,
      memory_state: "unconfigured",
      idle_timeout_seconds: div(ModelIdle.timeout_ms(), 1000),
      queued: 0,
      running: nil,
      jobs: [],
      available: false,
      sizes_loading: false,
      error: nil
    }

  def activate(name, principal), do: GenServer.call(__MODULE__, {:activate, name, principal})
  def submit(params, principal), do: GenServer.call(__MODULE__, {:submit, params, principal})
  def cancel(id, principal), do: GenServer.call(__MODULE__, {:cancel, id, principal})
  def unload(principal), do: GenServer.call(__MODULE__, {:unload, principal})
  def delete(name, principal), do: GenServer.call(__MODULE__, {:delete, name, principal})
  def refresh_sizes, do: GenServer.cast(__MODULE__, :refresh_sizes)

  def request(id, principal) do
    case :ets.lookup(@table, {:job, id}) do
      [{_, job}] ->
        if principal[:admin] || job.owner == KeyCache.owner(principal),
          do: {:ok, public(job, true)},
          else: Events.error("not_found", "Request not found.")

      _ ->
        Events.error("not_found", "Result expired or request not found on this server.")
    end
  rescue
    _ -> Events.error("unavailable", "Embedding worker is starting.")
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    sizes = EmbeddingFiles.load_metadata()
    {models, error} = catalog(sizes)

    state = %{
      models: models,
      catalog_error: error,
      selection_error: nil,
      active: saved_model(models),
      loaded: nil,
      last_used: nil,
      idle_timer: nil,
      task: nil,
      running: nil,
      pending: :queue.new(),
      completed: [],
      sizes: sizes,
      sizes_task: nil,
      sizes_requested_at: nil
    }

    Process.send_after(self(), :expire, 30_000)
    {:ok, publish(state)}
  end

  @impl true
  def handle_call({:activate, name, %{admin: true} = principal}, _, state) do
    model = Enum.find(state.models, &(&1.name == name))

    cond do
      is_nil(model) ->
        {:reply, Events.error("unknown_model", "Choose a model from the catalog."), state}

      :queue.len(state.pending) >= @max_pending ->
        {:reply, Events.error("queue_full", "The embedding queue is full."), state}

      Enum.any?(
        jobs(state),
        &(String.starts_with?(&1.kind, "model.") and &1.status in ["queued", "running"])
      ) ->
        {:reply, Events.error("model_busy", "A model operation is already in progress."), state}

      true ->
        enqueue("model.load", model.name, nil, principal, state)
    end
  end

  def handle_call({:activate, _, _}, _, state),
    do: {:reply, Events.error("forbidden", "Only administrators can activate models."), state}

  def handle_call({:unload, %{admin: true} = principal}, _, state) do
    cond do
      busy?(state) ->
        {:reply, Events.error("model_busy", "Wait for the queue to finish before unloading."),
         state}

      is_nil(state.loaded) ->
        {:reply, Events.error("model_not_loaded", "No embedding model is loaded."), state}

      true ->
        enqueue("model.unload", state.loaded, nil, principal, state)
    end
  end

  def handle_call({:delete, name, %{admin: true} = principal}, _, state) do
    model = Enum.find(state.models, &(&1.name == name))
    loaded = Enum.find(state.models, &(&1.name == state.loaded))
    selected = Enum.find(state.models, &(&1.name == state.active))

    cond do
      is_nil(model) ->
        {:reply, Events.error("unknown_model", "Choose a model from the catalog."), state}

      busy?(state) ->
        {:reply,
         Events.error("model_busy", "Wait for the queue to finish before deleting files."), state}

      loaded && loaded.repository == model.repository ->
        {:reply,
         Events.error(
           "model_loaded",
           "Unload the active model from this repository before deleting its files."
         ), state}

      true ->
        # Clearing the selection prevents a subsequent API call from silently
        # downloading files which the administrator explicitly removed.
        if selected && selected.repository == model.repository do
          case forget_model() do
            :ok ->
              enqueue("model.delete", name, model.repository, principal, %{state | active: nil})

            _ ->
              {:reply,
               Events.error("storage_error", "Could not clear the saved model selection."), state}
          end
        else
          enqueue("model.delete", name, model.repository, principal, state)
        end
    end
  end

  def handle_call({:unload, _}, _, state),
    do: {:reply, Events.error("forbidden", "Only administrators can unload models."), state}

  def handle_call({:delete, _, _}, _, state),
    do: {:reply, Events.error("forbidden", "Only administrators can delete model files."), state}

  def handle_call({:submit, params, principal}, _, state) do
    input = params["input"]
    texts = if is_binary(input), do: [input], else: input
    model = params["model"] || state.active

    cond do
      !KeyCache.allowed?(principal, "embedding:run") ->
        {:reply, Events.error("forbidden", "embedding:run permission required."), state}

      state.running && lookup(state.running).kind in ["model.unload", "model.delete"] ->
        {:reply, Events.error("model_busy", "Model maintenance is in progress. Retry shortly."),
         state}

      is_nil(state.active) ->
        {:reply,
         Events.error("model_not_loaded", "Select an embedding model in the dashboard first."),
         state}

      model != state.active ->
        {:reply, Events.error("model_not_active", "The requested model is not active."), state}

      !is_list(texts) or length(texts) not in 1..16 ->
        {:reply, Events.error("invalid_input", "Provide a string or 1–16 strings."), state}

      !Enum.all?(texts, &(is_binary(&1) and String.valid?(&1) and byte_size(&1) in 1..4096)) ->
        {:reply, Events.error("invalid_input", "Each input must be UTF-8 text of 1–4096 bytes."),
         state}

      :queue.len(state.pending) >= @max_pending ->
        {:reply, Events.error("queue_full", "The embedding queue is full."), state}

      true ->
        enqueue("embedding", model, texts, principal, state)
    end
  end

  def handle_call({:cancel, id, principal}, _, state) do
    job = lookup(id)

    cond do
      is_nil(job) or (!principal[:admin] and job.owner != KeyCache.owner(principal)) ->
        {:reply, Events.error("not_found", "Request not found."), state}

      job.status != "queued" ->
        {:reply, Events.error("not_cancellable", "Only queued requests can be cancelled."), state}

      true ->
        pending =
          state.pending |> :queue.to_list() |> Enum.reject(&(&1 == id)) |> :queue.from_list()

        job = %{
          job
          | status: "cancelled",
            input: nil,
            finished_at: DateTime.utc_now(),
            expires: System.monotonic_time(:second) + @ttl
        }

        store_job(job)

        state =
          %{state | pending: pending, completed: [id | state.completed]} |> prune() |> publish()

        {:reply, {:ok, public(job)}, state}
    end
  end

  @impl true
  def handle_cast(:refresh_sizes, state) do
    now = System.monotonic_time(:second)

    if state.sizes_task || (state.sizes_requested_at && now - state.sizes_requested_at < 60) do
      {:noreply, state}
    else
      models = state.models
      sizes = state.sizes

      task =
        Task.Supervisor.async_nolink(Supavisor.ServiceTasks, fn ->
          EmbeddingFiles.refresh_metadata(models, sizes)
        end)

      {:noreply, publish(%{state | sizes_task: task, sizes_requested_at: now})}
    end
  end

  @impl true
  def handle_info({ref, sizes}, %{sizes_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {models, error} = catalog(sizes)

    {:noreply,
     publish(%{state | sizes: sizes, sizes_task: nil, models: models, catalog_error: error})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{sizes_task: %{ref: ref}} = state),
    do: {:noreply, publish(%{state | sizes_task: nil})}

  def handle_info({:model_idle, token}, %{idle_timer: {_, token}} = state) do
    state = %{state | idle_timer: nil}

    if state.loaded && !busy?(state) && ModelIdle.expired?(state.last_used) do
      {:reply, _, next} =
        enqueue("model.sleep", state.loaded, nil, %{admin: true, email: "system"}, state)

      {:noreply, next}
    else
      {:noreply, arm_idle(state)}
    end
  end

  def handle_info({:embedding_phase, id, phase}, %{running: id} = state) do
    job = lookup(id)
    store_job(%{job | phase: phase})

    state =
      if phase == "inference",
        do: %{state | loaded: job.model, last_used: ModelIdle.now()},
        else: state

    {:noreply, publish(state)}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}, running: id} = state) do
    Process.demonitor(ref, [:flush])
    job = lookup(id)

    {result, state} =
      case result do
        {:inference, loaded, reply} ->
          {reply, %{state | loaded: loaded, last_used: ModelIdle.now()}}

        reply ->
          {reply, state}
      end

    {status, output, error} =
      case result do
        {:ok, output} -> {"completed", output, nil}
        {:error, error} -> {"failed", nil, error}
      end

    job = %{
      job
      | status: status,
        input: nil,
        result: output,
        error: error,
        finished_at: DateTime.utc_now(),
        expires: System.monotonic_time(:second) + @ttl
    }

    store_job(job)
    state = %{state | task: nil, running: nil, completed: [id | state.completed]}

    state =
      if String.starts_with?(job.kind, "model.") do
        {models, catalog_error} = catalog(state.sizes)

        active =
          case {status, job.kind} do
            {"completed", "model.load"} -> job.model
            _ -> state.active
          end

        loaded =
          case {status, job.kind} do
            {"completed", "model.load"} -> job.model
            {"completed", kind} when kind in ["model.unload", "model.sleep"] -> nil
            _ -> state.loaded
          end

        %{
          state
          | active: active,
            loaded: loaded,
            last_used:
              if(job.kind in ["model.load", "model.unload", "model.sleep"],
                do: ModelIdle.now(),
                else: state.last_used
              ),
            models: models,
            catalog_error: catalog_error,
            selection_error:
              case {status, job.kind} do
                {"completed", "model.load"} -> remember_model(job.model)
                _ -> state.selection_error
              end
        }
      else
        state
      end

    {:noreply, state |> prune() |> run_next() |> arm_idle() |> publish()}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state),
    do: handle_info({ref, {:error, "Worker interrupted. Please retry."}}, state)

  def handle_info(:expire, state) do
    Process.send_after(self(), :expire, 30_000)
    {:noreply, state |> prune() |> publish()}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp enqueue(kind, model, input, principal, state) do
    job = %{
      id: Ecto.UUID.generate(),
      service: "embedding",
      kind: kind,
      model: model,
      owner: KeyCache.owner(principal),
      principal: principal,
      input: input,
      status: "queued",
      phase: nil,
      result: nil,
      error: nil,
      inserted_at: DateTime.utc_now(),
      started_at: nil,
      finished_at: nil,
      expires: nil
    }

    store_job(job)

    state =
      %{
        state
        | pending: :queue.in(job.id, state.pending),
          idle_timer: ModelIdle.cancel(state.idle_timer)
      }
      |> run_next()
      |> publish()

    {:reply, {:ok, public(job)}, state}
  end

  defp run_next(%{task: task} = state) when not is_nil(task), do: state

  defp run_next(state) do
    case :queue.out(state.pending) do
      {:empty, _} ->
        state

      {{:value, id}, pending} ->
        job = lookup(id)
        job = %{job | status: "running", started_at: DateTime.utc_now()}
        store_job(job)
        active = state.active
        loaded = state.loaded
        coordinator = self()

        task =
          Task.Supervisor.async_nolink(Supavisor.ServiceTasks, fn ->
            execute(job, active, loaded, coordinator)
          end)

        %{state | pending: pending, task: task, running: id}
    end
  end

  defp execute(%{kind: "model.load", model: model}, _, _, _) do
    case ExFastembed.load(model) do
      {:ok, dimension} ->
        {:ok, %{model: model, dimension: dimension}}

      {:error, _} ->
        {:error,
         "Model download or initialization failed. Check disk space, memory and access to Hugging Face."}
    end
  rescue
    _ -> {:error, "Model initialization failed."}
  end

  defp execute(%{kind: kind}, _, _, _) when kind in ["model.unload", "model.sleep"] do
    with {:ok, _} <- ExFastembed.unload() do
      {:ok, %{unloaded: true}}
    else
      _ -> {:error, "The native runtime could not unload the model."}
    end
  rescue
    _ -> {:error, "The native runtime could not unload the model."}
  end

  defp execute(%{kind: "model.delete", input: repository}, _, _, _),
    do: EmbeddingFiles.delete_repository(repository)

  defp execute(job, active, loaded, coordinator) do
    cond do
      !KeyCache.allowed?(job.principal, "embedding:run") ->
        {:error, "API key revoked or expired."}

      job.model != active ->
        {:error, "The active model changed while this request was queued."}

      true ->
        case ensure_loaded(job, loaded, coordinator) do
          :ok ->
            send(coordinator, {:embedding_phase, job.id, "inference"})
            {:inference, job.model, infer(job)}

          {:error, _} = error ->
            ModelMetrics.track(:embedding, fn -> error end)
            {:inference, loaded, error}
        end
    end
  rescue
    _ -> {:error, "Embedding inference failed."}
  end

  defp ensure_loaded(%{model: model}, model, _), do: :ok

  defp ensure_loaded(job, _, coordinator) do
    send(coordinator, {:embedding_phase, job.id, "loading_model"})

    with %{cached: true} <- Enum.find(ExFastembed.models(), &(&1.name == job.model)),
         {:ok, _} <- ExFastembed.load(job.model) do
      :ok
    else
      %{cached: false} ->
        {:error, "Model files are missing. Download and activate the model in the dashboard."}

      _ ->
        {:error,
         "Could not reload the selected model from disk. Check its files and available RAM."}
    end
  rescue
    _ -> {:error, "Could not reload the selected model from disk."}
  end

  defp infer(job) do
    ModelMetrics.track(:embedding, fn ->
      case ExFastembed.embed_text(job.input) do
        {:ok, vectors} ->
          {:ok,
           %{
             model: job.model,
             data:
               Enum.with_index(vectors)
               |> Enum.map(fn {vector, index} -> %{index: index, embedding: vector} end),
             input_count: length(job.input)
           }}

        {:error, _} ->
          {:error, "Embedding inference failed."}
      end
    end)
  rescue
    _ -> {:error, "Embedding inference failed."}
  end

  defp saved_model(models) do
    with {:ok, name} <- File.read(selection_path()),
         true <- Enum.any?(models, &(&1.name == name)),
         do: name,
         else: (_ -> nil)
  end

  defp arm_idle(state) do
    timer = ModelIdle.cancel(state.idle_timer)
    timer = if state.loaded && !busy?(state), do: ModelIdle.schedule(state.last_used), else: timer
    %{state | idle_timer: timer}
  end

  defp selection_path do
    Application.fetch_env!(:supavisor, :service_mail_key_dir)
    |> Path.dirname()
    |> Path.join("active-embedding-model")
  end

  defp remember_model(name) do
    path = selection_path()
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, name),
         :ok <- File.rename(temporary, path) do
      nil
    else
      _ ->
        "Model is available, but its selection could not be saved for the next restart. Check the service data directory."
    end
  end

  defp forget_model do
    case File.rm(selection_path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp busy?(state), do: !is_nil(state.task) or !:queue.is_empty(state.pending)

  defp catalog(sizes) do
    {ExFastembed.models()
     |> Enum.filter(&(&1.kind == :embedding))
     |> EmbeddingFiles.enrich(sizes), nil}
  rescue
    _ -> {[], "The FastEmbed native runtime could not be loaded."}
  end

  defp lookup(id) do
    case :ets.lookup(@table, {:job, id}) do
      [{_, job}] -> job
      _ -> nil
    end
  end

  defp store_job(job) do
    :ets.insert(@table, {{:job, job.id}, job})
    Events.request(job.owner, public(job))
  end

  defp public(job, include_result \\ false) do
    info =
      Map.take(job, [
        :id,
        :service,
        :kind,
        :model,
        :status,
        :phase,
        :error,
        :inserted_at,
        :started_at,
        :finished_at
      ])

    if include_result, do: Map.put(info, :result, job.result), else: info
  end

  defp jobs(state),
    do:
      Enum.map(
        if(state.running, do: [state.running], else: []) ++
          :queue.to_list(state.pending) ++ state.completed,
        &lookup/1
      )
      |> Enum.reject(&is_nil/1)

  defp prune(state) do
    now = System.monotonic_time(:second)

    {keep, drop} =
      Enum.split_with(state.completed, fn id ->
        case lookup(id) do
          nil -> false
          job -> job.expires > now
        end
      end)

    {keep, overflow} = Enum.split(keep, @max_results)
    for id <- drop ++ overflow, do: :ets.delete(@table, {:job, id})
    %{state | completed: keep}
  end

  defp publish(state) do
    snapshot = %{
      models: state.models,
      active: state.active,
      loaded: state.loaded,
      memory_state: memory_state(state),
      idle_timeout_seconds: div(ModelIdle.timeout_ms(), 1000),
      queued: :queue.len(state.pending),
      running: if(state.running, do: public(lookup(state.running))),
      jobs: Enum.map(jobs(state), &public/1),
      available: state.catalog_error == nil,
      sizes_loading: not is_nil(state.sizes_task),
      error: state.catalog_error || state.selection_error
    }

    :ets.insert(@table, {:snapshot, snapshot})
    Events.changed()
    state
  end

  defp memory_state(state) do
    job = state.running && lookup(state.running)

    cond do
      job && (job.kind == "model.load" or job.phase == "loading_model") -> "loading"
      job && job.kind in ["model.sleep", "model.unload"] -> "unloading"
      state.loaded -> "loaded"
      state.active -> "standby"
      true -> "unconfigured"
    end
  end
end
