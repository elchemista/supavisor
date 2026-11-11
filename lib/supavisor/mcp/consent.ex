defmodule Supavisor.MCP.Consent do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix "_supavisor"
  schema "mcp_consents" do
    field :admin_email, :string
    field :expires_at, :utc_datetime_usec
  end
end
