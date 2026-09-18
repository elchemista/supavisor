defmodule Supavisor.Backups.Worker do
  use GenServer
  import Ecto.Query
  alias Supavisor.{Backups, Repo}
  alias Supavisor.Backups.{Job, Runner}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    File.mkdir_p!(Backups.root())
    File.chmod!(Backups.root(), 0o700)
    Process.send_after(self(), :recover, 100)
    {:ok, %{task: nil, job: nil, result: nil, ready: false}}
  end

  @impl true
  def handle_call({:enqueue, attrs, actor, upload}, _, state) do
    result = Backups.admit(attrs, actor, upload)
    send(self(), :tick)
    {:reply, result, state}
  end

  def handle_call({:cancel, id, actor}, _, state) do
    result =
      with true <- Backups.admin?(actor), %Job{} = job <- Backups.get(id) do
        cond do
          job.status == "queued" ->
            case Backups.update(job,
                   status: "cancelled",
                   stage: "Cancelled",
                   finished_at: DateTime.utc_now()
                 ) do
              {:ok, _} ->
                cleanup_inputs(job)
                :ok

              _ ->
                {:error, "Could not cancel this operation. Try again."}
            end

          state.job && state.job.id == id && state.task ->
            send(state.task.pid, :cancel)
            :ok

          true ->
            {:error, "This operation has already finished."}
        end
      else
        _ -> {:error, "Operation not found or administrator access revoked."}
      end

    {:reply, result, state}
  rescue
    _ ->
      {:reply, {:error, "Could not cancel this operation. Check database availability."}, state}
  end

  def handle_call({:delete, id, actor}, _, state) do
    result =
      with true <- Backups.admin?(actor),
           %Job{} = job <- Backups.get(id),
           true <- job.status not in ["queued", "running"] do
        case File.rm_rf(Backups.job_dir(job.id)) do
          {:ok, _} ->
            Repo.delete!(job)
            Backups.changed()
            :ok

          _ ->
            {:error, "Could not remove backup files. Check directory permissions."}
        end
      else
        _ -> {:error, "Only finished operations can be removed."}
      end

    {:reply, result, state}
  rescue
    _ ->
      {:reply, {:error, "Could not remove this history entry. Check database availability."},
       state}
  end

  @impl true
  def handle_cast({:stage, id, stage}, %{job: %{id: id}} = state) do
    case Backups.update(state.job, stage: stage) do
      {:ok, job} -> {:noreply, %{state | job: job}}
      _ -> {:noreply, state}
    end
  rescue
    _ -> {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info(:recover, state) do
    jobs =
      Repo.all(
        from j in Job,
          where: j.node_id == ^Backups.node_id() and j.status in ["queued", "running"]
      )

    for job <- jobs do
      if job.status == "running" or job.operation == "import" do
        safety =
          case File.stat(Path.join(Backups.job_dir(job.id), "safety.dump")) do
            {:ok, stat} -> stat.size
            _ -> 0
          end

        {:ok, _} =
          Backups.update(job,
            status: "failed",
            stage: "Interrupted",
            safety_bytes: safety,
            error:
              "Server restarted during this operation. Check the destination before retrying an import; any available safety backup is retained.",
            finished_at: DateTime.utc_now()
          )

        cleanup_inputs(job)
      end
    end

    clean_abandoned_uploads()
    Process.send_after(self(), :cleanup, 3_600_000)
    Process.send_after(self(), :poll, 10_000)
    {:noreply, next(%{state | ready: true})}
  rescue
    _ ->
      Process.send_after(self(), :recover, 5000)
      {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    clean_abandoned_uploads()
    Process.send_after(self(), :cleanup, 3_600_000)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, 10_000)
    {:noreply, next(state)}
  end

  def handle_info(:tick, state), do: {:noreply, next(state)}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, next(%{state | task: nil, result: result})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state) do
    {:noreply,
     next(%{
       state
       | task: nil,
         result: %{
           status: "failed",
           error: "Worker interrupted. Check the destination before retrying."
         }
     })}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp next(%{ready: false} = state), do: state

  defp next(%{result: result, job: job} = state) when not is_nil(result) do
    safety =
      case File.stat(Path.join(Backups.job_dir(job.id), "safety.dump")) do
        {:ok, stat} -> stat.size
        _ -> 0
      end

    fields =
      result
      |> Map.put(:safety_bytes, safety)
      |> Map.put(:finished_at, DateTime.utc_now())
      |> Map.put(:stage, if(result.status == "completed", do: "Completed", else: "Stopped"))

    case Backups.update(job, Map.to_list(fields)) do
      {:ok, _} ->
        cleanup_inputs(job)
        next(%{state | result: nil, job: nil})

      _ ->
        state
    end
  rescue
    _ -> state
  end

  defp next(%{task: task} = state) when not is_nil(task), do: state

  defp next(state) do
    case Repo.one(
           from j in Job,
             where: j.node_id == ^Backups.node_id() and j.status == "queued",
             order_by: j.inserted_at,
             limit: 1
         ) do
      nil ->
        state

      job ->
        {:ok, job} =
          Backups.update(job,
            status: "running",
            stage: "Starting",
            started_at: DateTime.utc_now()
          )

        coordinator = self()

        task =
          Task.Supervisor.async_nolink(Supavisor.Backups.Tasks, fn ->
            Runner.run(job, coordinator)
          end)

        %{state | task: task, job: job}
    end
  rescue
    _ -> state
  end

  defp cleanup_inputs(job) do
    for filename <- [
          "upload",
          "input.dump",
          "export.partial",
          "safety.partial",
          "export.tmp.dump"
        ] do
      File.rm(Path.join(Backups.job_dir(job.id), filename))
    end
  end

  defp clean_abandoned_uploads do
    # Completed uploads not consumed before leaving the page expire after one day.
    for path <- Path.wildcard(Path.join([Backups.root(), ".uploads", "*"])) do
      case File.stat(path, time: :posix) do
        {:ok, stat} -> if System.os_time(:second) - stat.mtime > 86_400, do: File.rm(path)
        _ -> :ok
      end
    end
  end
end
