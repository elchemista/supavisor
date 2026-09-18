defmodule Supavisor.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :supavisor

  @doc "Generates a fresh administrator password through release RPC, without email delivery."
  def reset_admin_password(email \\ nil) do
    email =
      email ||
        case SupavisorWeb.AdminAuth.admin_emails() do
          [only_admin] -> only_admin
          _ -> raise "Specify an administrator email: bin/reset-admin-password EMAIL"
        end

    case SupavisorWeb.AdminCredential.reset_password(email) do
      {:ok, password} ->
        IO.puts("Administrator: #{String.downcase(String.trim(email))}")
        IO.puts("New password: #{password}")
        IO.puts("Previous sessions have been invalidated. Store this password securely.")
        :ok

      {:error, message} ->
        raise message
    end
  end

  def migrate do
    ensure_ssl_started()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          # Pre-migration seeds create the schema, which is necessary to run the migrations
          Application.app_dir(:supavisor)
          |> Path.join("priv/repo/seeds_before_migration.exs")
          |> Code.eval_file()

          Ecto.Migrator.run(repo, :up, all: true, prefix: "_supavisor")
        end)
    end
  end

  def rollback(repo, version) do
    ensure_ssl_started()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(
        repo,
        &Ecto.Migrator.run(&1, :down, to: version, prefix: "_supavisor")
      )
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp ensure_ssl_started do
    Application.ensure_all_started(:ssl)
  end
end
