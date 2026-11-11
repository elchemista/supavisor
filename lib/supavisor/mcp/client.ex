defmodule Supavisor.MCP.Client do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix "_supavisor"
  schema "mcp_clients" do
    field :name, :string
    field :redirect_uris, {:array, :string}
    field :auth_method, :string, default: "none"
    field :secret_hash, :string, redact: true
    timestamps(type: :utc_datetime_usec)
  end
end
