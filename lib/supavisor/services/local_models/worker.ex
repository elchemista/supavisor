defmodule Supavisor.Services.LocalModels.Worker do
  @moduledoc false
  use GenServer
  alias Supavisor.Services.LocalModels
  alias Supavisor.Services.ModelIdle
  alias Supavisor.Services.LocalModels.{Catalog, Runtime}
  @max_graphs 4

  def name(:stt), do: Supavisor.Services.LocalModels.STT
  def name(:tts), do: Supavisor.Services.LocalModels.TTS
  def name(:ai_model), do: Supavisor.Services.LocalModels.AI

  def child_spec(service), do: %{id: name(service), start: {__MODULE__, :start_link, [service]}}
  def start_link(service), do: GenServer.start_link(__MODULE__, service, name: name(service))

  def snapshot(service) do
    case :ets.lookup(name(service), :snapshot) do
      [{_, value}] -> value
      _ -> empty()
    end
  rescue
    ArgumentError -> empty()
  end

  defp empty,
    do: %{
      loaded: %{},
      busy: nil,
      error: nil,
      available: false,
      limit: @max_graphs,
      idle_timeout_seconds: div(ModelIdle.timeout_ms(), 1000)
    }

  @impl true
  def init(service) do
    :ets.new(name(service), [:named_table, :protected, :set, read_concurrency: true])

    state = %{
      service: service,
      loaded: %{},
      task: nil,
      operation: nil,
      caller: nil,
      error: nil,
      idle_timer: nil
    }

    {:ok, publish(state)}
  end

  @impl true
  def handle_call(_, _, %{task: task} = state) when not is_nil(task),
    do:
      {:reply, {:error, "This model worker is busy. Retry when the current operation finishes."},
       state}

  def handle_call(message, from, state) do
    if LocalModels.enabled?(),
      do: dispatch(message, from, state),
      else: {:reply, {:error, "Local ONNX runtime is disabled in this environment."}, state}
  end

  defp dispatch({:bundle, :unload, _}, _, state) do
    files = Supavisor.Services.LocalModels.Models.definition(state.service).graphs

    state =
      %{state | loaded: Map.drop(state.loaded, files), error: nil} |> arm_idle() |> publish()

    send(self(), :collect)
    {:reply, :ok, state}
  end

  defp dispatch({:bundle, kind, params}, from, state) do
    definition = Supavisor.Services.LocalModels.Models.definition(state.service)
    service = state.service
    loaded = state.loaded

    start_operation(state, from, :bundle, definition.id, fn ->
      entries =
        Enum.reduce_while(definition.graphs, {:ok, %{}}, fn file, {:ok, entries} ->
          result =
            case Map.fetch(loaded, file) do
              {:ok, entry} -> {:ok, entry}
              :error -> with {:ok, path} <- Catalog.resolve(service, file), do: Runtime.load(path)
            end

          case result do
            {:ok, entry} -> {:cont, {:ok, Map.put(entries, file, entry)}}
            error -> {:halt, error}
          end
        end)

      case entries do
        {:ok, entries} ->
          result =
            if kind == :load,
              do: {:ok, %{model: definition.id}},
              else: definition.adapter.run(entries, params)

          {:bundle_result, entries, result}

        error ->
          error
      end
    end)
  end

  defp dispatch({:load, file}, from, state) do
    cond do
      Map.has_key?(state.loaded, file) ->
        state = state |> touch(file) |> arm_idle() |> publish()
        {:reply, {:ok, metadata(state.loaded[file])}, state}

      map_size(state.loaded) >= @max_graphs ->
        {:reply,
         {:error,
          "Unload a graph first. At most #{@max_graphs} graphs can be loaded per service."},
         state}

      true ->
        case Catalog.resolve(state.service, file) do
          {:ok, path} -> start_operation(state, from, :load, file, fn -> Runtime.load(path) end)
          error -> {:reply, error, state}
        end
    end
  end

  defp dispatch({:unload, file}, _, state) do
    state =
      %{state | loaded: Map.delete(state.loaded, file), error: nil} |> arm_idle() |> publish()

    # Collect after the callback has dropped the final session reference.
    send(self(), :collect)
    {:reply, :ok, state}
  end

  defp dispatch({:run, file, inputs}, from, state) do
    with :ok <- validate_inputs(inputs, state.service) do
      case Map.get(state.loaded, file) do
        %{model: model} ->
          start_operation(state, from, :run, file, fn -> Runtime.run(model, inputs) end)

        nil when map_size(state.loaded) >= @max_graphs ->
          {:reply,
           {:error,
            "Unload a graph first. At most #{@max_graphs} graphs can be loaded per service."},
           state}

        nil ->
          case Catalog.resolve(state.service, file) do
            {:ok, path} ->
              start_operation(state, from, :load_run, file, fn ->
                with {:ok, entry} <- Runtime.load(path),
                     do: {:loaded_and_ran, entry, Runtime.run(entry.model, inputs)}
              end)

            error ->
              {:reply, error, state}
          end
      end
    else
      error -> {:reply, error, state}
    end
  end

  # Decoder exports may have a pair of cache tensors for every transformer layer.
  # This is an input ceiling, not reserved memory or an automatically built cache.
  defp input_limits(:ai_model), do: {256, 256}
  defp input_limits(_), do: {64, 64}

  defp validate_inputs(inputs, service) do
    tensors = if is_tuple(inputs), do: Tuple.to_list(inputs), else: [inputs]
    {max_tensors, max_mib} = input_limits(service)

    cond do
      length(tensors) not in 1..max_tensors or !Enum.all?(tensors, &is_struct(&1, Nx.Tensor)) ->
        {:error,
         "Pass an Nx tensor or a tuple of up to #{max_tensors} tensors in ONNX input order."}

      Enum.any?(tensors, &(&1.vectorized_axes != [])) ->
        {:error, "Use ordinary tensor dimensions; devectorize Nx inputs before ONNX inference."}

      Enum.sum(Enum.map(tensors, &Nx.byte_size/1)) > max_mib * 1024 * 1024 ->
        {:error, "Tensor inputs exceed the #{max_mib} MiB limit."}

      true ->
        :ok
    end
  end

  defp start_operation(state, from, kind, file, fun) do
    task = Task.Supervisor.async_nolink(Supavisor.ServiceTasks, fun)
    operation = %{kind: kind, file: file}

    {:noreply,
     publish(%{
       state
       | task: task,
         caller: from,
         operation: operation,
         error: nil,
         idle_timer: ModelIdle.cancel(state.idle_timer)
     })}
  end

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {reply, state} =
      case {state.operation.kind, result} do
        {:bundle, {:bundle_result, entries, reply}} ->
          entries =
            Map.new(entries, fn {file, entry} ->
              {file,
               Map.merge(entry, %{
                 loaded_at: Map.get(entry, :loaded_at, DateTime.utc_now()),
                 last_used: ModelIdle.now(),
                 last_used_at: DateTime.utc_now()
               })}
            end)

          {reply, %{state | loaded: Map.merge(state.loaded, entries)}}

        {:load, {:ok, entry}} ->
          state = put_entry(state, entry)
          {{:ok, metadata(state.loaded[state.operation.file])}, state}

        {:load_run, {:loaded_and_ran, entry, reply}} ->
          {reply, put_entry(state, entry)}

        {_, {:error, error}} ->
          {result, %{state | error: error}}

        {_, _} ->
          {result, state}
      end

    state = if state.operation.kind == :run, do: touch(state, state.operation.file), else: state

    state =
      case reply do
        {:error, error} -> %{state | error: error}
        _ -> state
      end

    caller = state.caller
    state = %{state | task: nil, caller: nil, operation: nil} |> arm_idle() |> publish()
    GenServer.reply(caller, reply)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state),
    do:
      handle_info(
        {ref, {:error, "The ONNX worker was interrupted. Retry loading the graph."}},
        state
      )

  def handle_info(:collect, state) do
    :erlang.garbage_collect(self())
    {:noreply, state}
  end

  def handle_info({:model_idle, token}, %{idle_timer: {_, token}, task: nil} = state) do
    loaded = Map.reject(state.loaded, fn {_, entry} -> ModelIdle.expired?(entry.last_used) end)
    state = %{state | loaded: loaded, idle_timer: nil} |> arm_idle() |> publish()
    send(self(), :collect)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{task: %Task{pid: pid}}), do: Process.exit(pid, :kill)
  def terminate(_, _), do: :ok

  defp put_entry(state, entry) do
    entry = Map.put(entry, :loaded_at, DateTime.utc_now())

    %{state | loaded: Map.put(state.loaded, state.operation.file, entry)}
    |> touch(state.operation.file)
  end

  defp touch(state, file) do
    %{
      state
      | loaded:
          Map.update!(
            state.loaded,
            file,
            &Map.merge(&1, %{last_used: ModelIdle.now(), last_used_at: DateTime.utc_now()})
          )
    }
  end

  defp arm_idle(state) do
    timer = ModelIdle.cancel(state.idle_timer)

    timer =
      if map_size(state.loaded) > 0 && is_nil(state.task) do
        state.loaded
        |> Map.values()
        |> Enum.map(& &1.last_used)
        |> Enum.min()
        |> ModelIdle.schedule()
      else
        timer
      end

    %{state | idle_timer: timer}
  end

  defp metadata(entry), do: Map.take(entry, [:inputs, :outputs, :loaded_at, :last_used_at])

  defp publish(state) do
    snapshot = %{
      loaded: Map.new(state.loaded, fn {file, entry} -> {file, metadata(entry)} end),
      busy: state.operation,
      error: state.error,
      available: LocalModels.enabled?(),
      limit: @max_graphs,
      idle_timeout_seconds: div(ModelIdle.timeout_ms(), 1000)
    }

    :ets.insert(name(state.service), {:snapshot, snapshot})

    Phoenix.PubSub.broadcast(
      Supavisor.PubSub,
      "admin:local_models",
      {:local_models_changed, state.service}
    )

    state
  end
end
