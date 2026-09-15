defmodule Supavisor.Repo.Migrations.CreateAdminSettings do
  use Ecto.Migration

  def change do
    create table(:admin_settings, primary_key: false, prefix: "_supavisor") do
      add :id, :string, primary_key: true
      add :admin_emails, {:array, :string}, null: false, default: []
      add :github_enabled, :boolean, null: false, default: false
      add :github_client_id, :string
      add :github_client_secret, :binary
      add :github_redirect_uri, :string
      timestamps()
    end
  end
end
