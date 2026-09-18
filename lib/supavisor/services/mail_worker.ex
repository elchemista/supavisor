defmodule Supavisor.Services.MailWorker do
  @moduledoc "Durable SMTP and webhook queues; ambiguous SMTP deliveries are never automatically retried."
  use GenServer
  import Ecto.Query
  alias Supavisor.Repo
  alias Supavisor.Services.{Mail, MailMessage, MailDelivery, Events}
  @table __MODULE__
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def snapshot do
    case :ets.lookup(@table, :stats) do
      [{_, stats}] -> stats
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    Process.send_after(self(), :tick, 1000)
    Process.send_after(self(), :cleanup, 60_000)
    Process.send_after(self(), :recover, 30_000)
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 3_000)
    {:noreply, run(state)}
  end

  def handle_info(:wake, state), do: {:noreply, run(state)}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, tasks} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(job.timer)
        job = Map.put(job, :result, result)
        {:noreply, run(%{state | tasks: Map.put(tasks, ref, job)})}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {job, tasks} ->
        Process.cancel_timer(job.timer)
        job = Map.put(job, :result, interrupted(job.kind))
        {:noreply, run(%{state | tasks: Map.put(tasks, ref, job)})}
    end
  end

  def handle_info({:timeout, ref}, state) do
    case state.tasks[ref] do
      nil ->
        {:noreply, state}

      job ->
        Process.exit(job.pid, :kill)
        {:noreply, state}
    end
  end

  def handle_info(:recover, state) do
    Process.send_after(self(), :recover, 30_000)
    state = flush_results(state)
    recover_leases()
    {:noreply, run(state)}
  end

  def handle_info(:cleanup, state) do
    Process.send_after(self(), :cleanup, 3_600_000)
    days = Application.get_env(:supavisor, :service_mail_retention_days, 0)

    if days > 0 do
      cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

      {count, _} =
        Repo.delete_all(
          from m in MailMessage,
            where:
              m.inserted_at < ^cutoff and m.status not in ["queued", "sending"] and
                m.webhook_status not in ["pending", "sending", "retrying"]
        )

      if count > 0, do: Events.changed()
    end

    {:noreply, run(state)}
  rescue
    _ -> {:noreply, state}
  end

  defp run(state) do
    state = state |> flush_results() |> fill(:smtp) |> fill(:webhook)
    refresh_stats()
    state
  end

  # Keep completed receipts in memory until storage recovers. Never redeliver SMTP
  # merely because persisting the receipt failed.
  defp flush_results(state) do
    tasks =
      Map.reject(state.tasks, fn {_ref, job} ->
        if Map.has_key?(job, :result) do
          try do
            finish(job, job.result)
            true
          rescue
            _ -> false
          end
        else
          false
        end
      end)

    %{state | tasks: tasks}
  end

  defp fill(state, kind) do
    if Enum.count(state.tasks, fn {_, job} -> job.kind == kind end) < 2 do
      case start_next(kind) do
        nil -> state
        {ref, job} -> fill(%{state | tasks: Map.put(state.tasks, ref, job)}, kind)
      end
    else
      state
    end
  end

  defp start_next(kind) do
    case claim(kind) do
      nil ->
        nil

      message ->
        task =
          Task.Supervisor.async_nolink(Supavisor.ServiceTasks, fn ->
            if kind == :smtp,
              do: MailDelivery.deliver(message),
              else: MailDelivery.webhook(message)
          end)

        timeout = if kind == :smtp, do: 120_000, else: 20_000

        job = %{
          kind: kind,
          id: message.id,
          pid: task.pid,
          lease: if(kind == :smtp, do: message.lease_until, else: message.webhook_lease_until),
          timer: Process.send_after(self(), {:timeout, task.ref}, timeout)
        }

        Events.request(message.owner, Mail.summary(message))
        {task.ref, job}
    end
  rescue
    _ -> nil
  end

  defp refresh_stats do
    stats = Mail.stats()
    previous = snapshot()
    :ets.insert(@table, {:stats, stats})
    if stats != previous, do: Events.changed()
  rescue
    _ -> :ok
  end

  defp recover_leases do
    now = DateTime.utc_now()

    {smtp, _} =
      Repo.update_all(
        from(m in MailMessage, where: m.status == "sending" and m.lease_until < ^now),
        set: [
          status: "uncertain",
          error: "Worker interrupted; acceptance unknown. Review before resending.",
          finished_at: now,
          lease_until: nil
        ]
      )

    {failed, _} =
      Repo.update_all(
        from(m in MailMessage,
          where:
            m.webhook_status == "sending" and m.webhook_lease_until < ^now and
              m.webhook_attempts >= 5
        ),
        set: [
          webhook_status: "failed",
          webhook_error: "Worker interrupted after the last attempt.",
          webhook_lease_until: nil
        ]
      )

    {retrying, _} =
      Repo.update_all(
        from(m in MailMessage,
          where:
            m.webhook_status == "sending" and m.webhook_lease_until < ^now and
              m.webhook_attempts < 5
        ),
        set: [webhook_status: "retrying", webhook_next_at: now, webhook_lease_until: nil]
      )

    if smtp + failed + retrying > 0, do: Events.changed()
  rescue
    _ -> :ok
  end

  defp claim(kind) do
    now = DateTime.utc_now()

    query =
      if kind == :smtp,
        do: from(m in MailMessage, where: m.status == "queued"),
        else:
          from(m in MailMessage,
            where:
              m.webhook_status in ["pending", "retrying"] and
                (is_nil(m.webhook_next_at) or m.webhook_next_at <= ^now)
          )

    {:ok, message} =
      Repo.transaction(fn ->
        case Repo.one(
               from m in query, order_by: m.inserted_at, limit: 1, lock: "FOR UPDATE SKIP LOCKED"
             ) do
          nil ->
            nil

          message ->
            fields =
              if kind == :smtp,
                do: [
                  status: "sending",
                  started_at: now,
                  lease_until: DateTime.add(now, 150, :second)
                ],
                else: [
                  webhook_status: "sending",
                  webhook_attempts: message.webhook_attempts + 1,
                  webhook_lease_until: DateTime.add(now, 30, :second)
                ]

            Repo.update!(Ecto.Changeset.change(message, fields))
        end
      end)

    message
  end

  defp finish(%{kind: :smtp, id: id, lease: lease}, {status, error, receipt}) do
    Repo.update_all(
      from(m in MailMessage,
        where: m.id == ^id and m.status == "sending" and m.lease_until == ^lease
      ),
      set: [
        status: to_string(status),
        error: error,
        receipt: receipt,
        finished_at: DateTime.utc_now(),
        lease_until: nil
      ]
    )

    notify(id)
  end

  defp finish(%{kind: :webhook, id: id, lease: lease}, {status, error}) do
    message = Repo.get!(MailMessage, id)
    retry? = status == :retry and message.webhook_attempts < 5

    final_status =
      if retry?, do: "retrying", else: if(status == :retry, do: "failed", else: to_string(status))

    next_at =
      if retry?,
        do:
          DateTime.add(
            DateTime.utc_now(),
            30 * Integer.pow(2, message.webhook_attempts - 1),
            :second
          )

    Repo.update_all(
      from(m in MailMessage,
        where: m.id == ^id and m.webhook_status == "sending" and m.webhook_lease_until == ^lease
      ),
      set: [
        webhook_status: final_status,
        webhook_error: error,
        webhook_next_at: next_at,
        webhook_lease_until: nil
      ]
    )

    notify(id)
  end

  defp notify(id) do
    case Repo.get(MailMessage, id) do
      nil -> :ok
      message -> Events.request(message.owner, Mail.summary(message))
    end
  end

  defp interrupted(:smtp), do: {:uncertain, "Delivery interrupted. Review before resending.", %{}}
  defp interrupted(:webhook), do: {:retry, "Webhook delivery interrupted."}
end
