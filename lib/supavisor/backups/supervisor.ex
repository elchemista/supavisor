defmodule Supavisor.Backups.Supervisor do
  use Supervisor
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    # A coordinator restart also stops its command task. Closing the task's port
    # tells the helper to terminate the PostgreSQL process and roll back restores.
    Supervisor.init([{Task.Supervisor, name: Supavisor.Backups.Tasks}, Supavisor.Backups.Worker],
      strategy: :one_for_all
    )
  end
end
