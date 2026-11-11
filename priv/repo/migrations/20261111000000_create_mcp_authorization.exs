defmodule Supavisor.Repo.Migrations.CreateMCPAuthorization do
  use Ecto.Migration

  def change do
    create table(:mcp_clients, primary_key: false, prefix: "_supavisor") do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :redirect_uris, {:array, :text}, null: false
      add :auth_method, :text, null: false, default: "none"
      add :secret_hash, :text
      timestamps(type: :utc_datetime_usec)
    end

    create table(:mcp_consents, primary_key: false, prefix: "_supavisor") do
      add :id, :text, primary_key: true
      add :admin_email, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:mcp_consents, [:expires_at], prefix: "_supavisor")

    create table(:mcp_authorization_codes, primary_key: false, prefix: "_supavisor") do
      add :id, :text, primary_key: true
      add :client_id, references(:mcp_clients, type: :text, on_delete: :delete_all), null: false
      add :admin_email, :text, null: false
      add :admin_version, :text
      add :redirect_uri, :text, null: false
      add :challenge, :text, null: false
      add :resource, :text, null: false
      add :scopes, {:array, :text}, null: false
      add :tenant_ids, {:array, :text}, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:mcp_authorization_codes, [:expires_at], prefix: "_supavisor")

    create table(:mcp_grants, primary_key: false, prefix: "_supavisor") do
      add :id, :uuid, primary_key: true
      add :client_id, references(:mcp_clients, type: :text, on_delete: :delete_all), null: false
      add :admin_email, :text, null: false
      add :admin_version, :text
      add :scopes, {:array, :text}, null: false
      add :tenant_ids, {:array, :text}, null: false
      add :resource, :text, null: false
      add :access_hash, :text, null: false
      add :refresh_hash, :text, null: false
      add :used_refresh_hashes, {:array, :text}, null: false, default: []
      add :expires_at, :utc_datetime_usec, null: false
      add :refresh_expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_grants, [:access_hash], prefix: "_supavisor")
    create unique_index(:mcp_grants, [:refresh_hash], prefix: "_supavisor")
    create index(:mcp_grants, [:admin_email], prefix: "_supavisor")
    create index(:mcp_grants, [:refresh_expires_at], prefix: "_supavisor")
  end
end
