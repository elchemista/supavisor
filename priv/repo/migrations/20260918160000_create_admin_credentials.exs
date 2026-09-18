defmodule Supavisor.Repo.Migrations.CreateAdminCredentials do
  use Ecto.Migration

  def change do
    create table(:admin_credentials, primary_key: false, prefix: "_supavisor") do
      add :email, :text, primary_key: true
      add :password_hash, :text, null: false
      add :session_version, :uuid, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
