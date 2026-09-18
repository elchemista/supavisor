defmodule Supavisor.Backups.Job do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "_supavisor"
  schema "database_backups" do
    field :node_id, :string
    field :host, :string
    field :port, :integer
    field :database, :string
    field :operation, :string
    field :format, :string
    field :restore_mode, :string, default: "add"
    field :ownership, :string, default: "preserve"
    field :status, :string, default: "queued"
    field :stage, :string, default: "Waiting"
    field :created_by, :string
    field :filename, :string
    field :bytes, :integer, default: 0
    field :safety_bytes, :integer, default: 0
    field :sha256, :string
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
