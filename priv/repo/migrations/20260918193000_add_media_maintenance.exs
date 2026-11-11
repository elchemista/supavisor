defmodule Supavisor.Repo.Migrations.AddMediaMaintenance do
  use Ecto.Migration

  # Historical migration retained for installations that already recorded it.
  # The retired media services no longer need Oban or its housekeeping tables.
  # Existing tables are deliberately preserved when upgrading or rolling back.
  def up, do: :ok
  def down, do: :ok
end
