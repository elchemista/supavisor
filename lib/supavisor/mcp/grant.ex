defmodule Supavisor.MCP.Grant do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @schema_prefix "_supavisor"
  schema "mcp_grants" do
    field :client_id, :string
    field :admin_email, :string
    field :admin_version, :string
    field :scopes, {:array, :string}, default: []
    field :tenant_ids, {:array, :string}, default: []
    field :resource, :string
    field :access_hash, :string, redact: true
    field :refresh_hash, :string, redact: true
    field :used_refresh_hashes, {:array, :string}, default: [], redact: true
    field :expires_at, :utc_datetime_usec
    field :refresh_expires_at, :utc_datetime_usec
    field :client_name, :string, virtual: true
    timestamps(type: :utc_datetime_usec)
  end
end
