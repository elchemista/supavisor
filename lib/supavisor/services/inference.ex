defmodule Supavisor.Services.Inference do
  @moduledoc "Bounded CPU inference queue shared by REST, WebSocket and the model dashboard."
  use GenServer
  alias Supavisor.Services.{LocalModels, Events, Media}
  alias Supavisor.Services.LocalModels.Models
  alias Supavisor.ServiceAPI.KeyCache
  @table __MODULE__
  @ttl 300
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def submit(service, params, principal),
    do: GenServer.call(__MODULE__, {:submit, service, params, principal})

  def manage(service, action, principal),
    do: GenServer.call(__MODULE__, {:manage, service, action, principal})

  def cancel(id, principal), do: GenServer.call(__MODULE__, {:cancel, id, principal})

  def snapshot do
    case :ets.lookup(@table, :snapshot) do
      [{_, s}] -> s
      _ -> %{queued: 0, running: nil, jobs: []}
    end
  rescue
    _ -> %{queued: 0, running: nil, jobs: []}
  end

  def request(id, principal) do
    case :ets.lookup(@table, id) do
      [{_, %{owner: owner, expires: expiry} = job}] ->
        if owner == KeyCache.owner(principal) and
             (job.status in ["queued", "running"] or expiry > System.monotonic_time(:second)),
           do: {:ok, public(job)},
           else: Events.error("not_found", "Request not found or expired.")

      _ ->
        Events.error("not_found", "Request not found or expired.")
    end
  end

  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    Process.send_after(self(), :expire, 30_000)
    {:ok, publish(%{pending: :queue.new(), task: nil, running: nil})}
  end

  def handle_call({:submit, service, params, principal}, _, state) do
    with :ok <- permitted(principal, Models.scope(service)),
         true <-
           LocalModels.enabled?() || Events.error("unavailable", "Local models are disabled."),
         {:ok, normalized} <- Models.validate(service, params),
         :ok <- audio_access(service, normalized, principal) do
      enqueue(state, service, :infer, normalized, principal)
    else
      {:error, message} when is_binary(message) ->
        {:reply, Events.error("invalid_input", message), state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:manage, service, action, %{admin: true} = principal}, _, state)
      when action in [:load, :unload] do
    cond do
      !LocalModels.enabled?() ->
        {:reply, Events.error("unavailable", "Local models are disabled."), state}

      state.running || !:queue.is_empty(state.pending) ->
        {:reply,
         Events.error(
           "model_busy",
           "Wait for current requests to finish before changing model memory."
         ), state}

      true ->
        enqueue(state, service, action, %{}, principal)
    end
  end

  def handle_call({:manage, _, _, _}, _, state),
    do: {:reply, Events.error("forbidden", "Administrator access required."), state}

  def handle_call({:cancel, id, principal}, _, state) do
    case request(id, principal) do
      {:ok, %{status: "queued"}} ->
        job = lookup(id) |> Map.merge(%{status: "cancelled", payload: nil})
        save(job)

        pending =
          state.pending |> :queue.to_list() |> Enum.reject(&(&1 == id)) |> :queue.from_list()

        {:reply, {:ok, public(job)}, publish(%{state | pending: pending})}

      {:ok, _} ->
        {:reply, Events.error("not_cancellable", "Only queued requests can be cancelled."), state}

      error ->
        {:reply, error, state}
    end
  end

  defp enqueue(state, service, kind, payload, principal) do
    if :queue.len(state.pending) >= 10 do
      {:reply, Events.error("queue_full", "The model queue is full. Retry shortly."), state}
    else
      job = %{
        id: Ecto.UUID.generate(),
        service: service,
        kind: kind,
        model: Models.definition(service).id,
        owner: KeyCache.owner(principal),
        principal: principal,
        status: "queued",
        payload: payload,
        result: nil,
        error: nil,
        inserted_at: DateTime.utc_now(),
        expires: System.monotonic_time(:second) + @ttl
      }

      save(job)
      send(self(), :next)
      {:reply, {:ok, public(job)}, publish(%{state | pending: :queue.in(job.id, state.pending)})}
    end
  end

  def handle_info(:next, %{task: nil} = state) do
    case :queue.out(state.pending) do
      {:empty, _} ->
        {:noreply, state}

      {{:value, id}, pending} ->
        job = lookup(id) |> Map.put(:status, "running")
        save(job)

        task =
          Task.Supervisor.async_nolink(Supavisor.ServiceTasks, fn ->
            with :ok <- permitted(job.principal, Models.scope(job.service)) do
              case job.kind do
                :load ->
                  LocalModels.load_model(job.service)

                :unload ->
                  LocalModels.unload_model(job.service)

                :infer ->
                  Supavisor.Monitoring.ModelMetrics.track(job.service, fn ->
                    LocalModels.infer(job.service, Map.put(job.payload, "owner", job.owner))
                  end)
              end
            end
          end)

        {:noreply, publish(%{state | task: task, running: id, pending: pending})}
    end
  end

  def handle_info(:next, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    job = lookup(state.running)

    changes =
      case result do
        :ok -> %{status: "completed", result: %{model: job.model, memory: "released"}}
        {:ok, data} -> %{status: "completed", result: data}
        {:error, %{message: message}} -> %{status: "failed", error: message}
        {:error, message} when is_binary(message) -> %{status: "failed", error: message}
        _ -> %{status: "failed", error: "Model operation failed."}
      end

    job
    |> Map.merge(changes)
    |> Map.merge(%{payload: nil, principal: nil, expires: System.monotonic_time(:second) + @ttl})
    |> save()

    send(self(), :next)
    {:noreply, publish(%{state | task: nil, running: nil})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state),
    do: handle_info({ref, {:error, "Model operation was interrupted."}}, state)

  def handle_info(:expire, state) do
    Process.send_after(self(), :expire, 30_000)

    done =
      jobs()
      |> Enum.filter(&(&1.status not in ["queued", "running"]))
      |> Enum.sort_by(& &1.expires, :desc)

    for {job, index} <- Enum.with_index(done),
        index >= 30 or job.expires < System.monotonic_time(:second),
        do: :ets.delete(@table, job.id)

    {:noreply, publish(state)}
  end

  defp audio_access(:stt, params, principal) do
    case Media.fetch_owned(params["audio_id"], KeyCache.owner(principal), "stt:run") do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp audio_access(_, _, _), do: :ok

  defp permitted(principal, scope),
    do:
      if(KeyCache.allowed?(principal, scope),
        do: :ok,
        else: Events.error("forbidden", "#{scope} permission required.")
      )

  defp lookup(id), do: :ets.lookup_element(@table, id, 2)
  defp jobs, do: for({id, job} <- :ets.tab2list(@table), is_binary(id), do: job)

  defp public(job),
    do: Map.take(job, [:id, :service, :kind, :model, :status, :result, :error, :inserted_at])

  defp save(job) do
    :ets.insert(@table, {job.id, job})
    Events.request(job.owner, public(job))
    job
  end

  defp publish(state) do
    jobs =
      jobs()
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.map(&(public(&1) |> Map.delete(:result)))

    :ets.insert(
      @table,
      {:snapshot, %{queued: :queue.len(state.pending), running: state.running, jobs: jobs}}
    )

    Events.changed()
    state
  end
end
