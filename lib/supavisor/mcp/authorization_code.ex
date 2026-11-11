defmodule Supavisor.MCP.AuthorizationCode do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix "_supavisor"
  schema "mcp_authorization_codes" do
    field :client_id, :string
    field :admin_email, :string
    field :admin_version, :string
    field :redirect_uri, :string
    field :challenge, :string
    field :resource, :string
    field :scopes, {:array, :string}
    field :tenant_ids, {:array, :string}
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
