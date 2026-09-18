defmodule Supavisor.Repo.Migrations.AddMediaMaintenance do
  use Ecto.Migration
  def up, do: Oban.Migration.up(prefix: "_supavisor", create_schema: false)
  def down, do: Oban.Migration.down(prefix: "_supavisor")
end
