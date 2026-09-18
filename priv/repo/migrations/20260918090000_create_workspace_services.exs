defmodule Supavisor.Repo.Migrations.CreateWorkspaceServices do
  use Ecto.Migration

  def change do
    create table(:service_api_keys, primary_key: false, prefix: "_supavisor") do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :digest, :binary, null: false
      add :fingerprint, :string, null: false
      add :scopes, {:array, :string}, null: false
      add :transports, {:array, :string}, null: false
      add :mailbox_ids, {:array, :uuid}, null: false, default: []
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:service_api_keys, [:digest], prefix: "_supavisor")

    execute(
      """
      INSERT INTO _supavisor.service_api_keys
        (id, name, digest, fingerprint, scopes, transports, inserted_at, updated_at)
      SELECT generation, 'Existing service token', token_digest, token_fingerprint,
        ARRAY['embedding:read','embedding:run','mail:read','mail:send'],
        ARRAY['rest','websocket'], inserted_at, updated_at
      FROM _supavisor.service_api_settings WHERE token_digest IS NOT NULL
      """,
      "SELECT 1"
    )

    create table(:service_mailboxes, primary_key: false, prefix: "_supavisor") do
      add :id, :uuid, primary_key: true
      add :name, :string, null: false
      add :address, :string, null: false
      add :hostname, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :delivery_mode, :string, null: false, default: "local"
      add :dkim_enabled, :boolean, null: false, default: false
      add :dkim_selector, :string, null: false, default: "mail"
      add :webhook_enabled, :boolean, null: false, default: false
      add :webhook_url, :text
      add :webhook_token, :binary
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:service_mailboxes, [:address], prefix: "_supavisor")

    create table(:service_mail_messages, primary_key: false, prefix: "_supavisor") do
      add :id, :uuid, primary_key: true

      add :mailbox_id,
          references(:service_mailboxes, type: :uuid, prefix: "_supavisor", on_delete: :restrict),
          null: false

      add :owner, :string, null: false
      add :direction, :string, null: false
      add :status, :string, null: false
      add :sender, :string, null: false
      add :recipient, :string, null: false
      add :subject, :text, null: false
      add :content, :binary, null: false
      add :idempotency_key, :string
      add :request_digest, :binary
      add :read_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :lease_until, :utc_datetime_usec
      add :receipt, :map, null: false, default: %{}
      add :error, :text
      add :webhook_status, :string, null: false, default: "disabled"
      add :webhook_attempts, :integer, null: false, default: 0
      add :webhook_next_at, :utc_datetime_usec
      add :webhook_lease_until, :utc_datetime_usec
      add :webhook_error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:service_mail_messages, [:mailbox_id, :inserted_at], prefix: "_supavisor")
    create index(:service_mail_messages, [:status, :inserted_at], prefix: "_supavisor")

    create index(:service_mail_messages, [:webhook_status, :webhook_next_at],
             prefix: "_supavisor"
           )

    create unique_index(:service_mail_messages, [:owner, :idempotency_key],
             prefix: "_supavisor",
             where: "idempotency_key IS NOT NULL"
           )
  end
end
