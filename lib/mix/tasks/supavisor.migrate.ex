defmodule Mix.Tasks.Supavisor.Migrate do
  use Mix.Task

  @shortdoc "Create the metadata schema and run migrations without starting the pooler"
  def run(_args) do
    Mix.Task.run("app.config")
    Supavisor.Release.migrate()
  end
end
