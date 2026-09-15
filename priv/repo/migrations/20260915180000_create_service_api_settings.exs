defmodule Supavisor.Repo.Migrations.CreateServiceApiSettings do
  use Ecto.Migration

  def change do
    create table(:service_api_settings, primary_key: false, prefix: "_supavisor") do
      add :id, :string, primary_key: true
      add :token_digest, :binary
      add :token_fingerprint, :string
      add :generation, :uuid, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
