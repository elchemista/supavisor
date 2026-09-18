defmodule Supavisor.Services.MailMessage do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "_supavisor"
  schema "service_mail_messages" do
    field :mailbox_id, Ecto.UUID
    field :owner, :string
    field :direction, :string
    field :status, :string
    field :sender, :string
    field :recipient, :string
    field :subject, :string
    field :content, Supavisor.Encrypted.Binary, redact: true
    field :idempotency_key, :string
    field :request_digest, :binary, redact: true
    field :read_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :lease_until, :utc_datetime_usec
    field :receipt, :map, default: %{}
    field :error, :string
    field :webhook_status, :string, default: "disabled"
    field :webhook_attempts, :integer, default: 0
    field :webhook_next_at, :utc_datetime_usec
    field :webhook_lease_until, :utc_datetime_usec
    field :webhook_error, :string
    timestamps(type: :utc_datetime_usec)
  end
end
