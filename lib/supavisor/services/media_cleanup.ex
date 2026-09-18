defmodule Supavisor.Services.MediaCleanup do
  @moduledoc "Oban retention sweep for Supavisor's private audio and temporary files."
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3500]
  @impl Oban.Worker
  def perform(%Oban.Job{}),
    do:
      (
        Supavisor.Services.Media.cleanup()
        :ok
      )
end
