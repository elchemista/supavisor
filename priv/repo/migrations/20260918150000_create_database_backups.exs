defmodule Supavisor.Repo.Migrations.CreateDatabaseBackups do
  use Ecto.Migration

  def change do
    create table(:database_backups, primary_key: false, prefix: "_supavisor") do
      add(:id, :uuid, primary_key: true)
      add(:node_id, :string, null: false)
      add(:host, :string, null: false)
      add(:port, :integer, null: false)
      add(:database, :string, null: false)
      add(:operation, :string, null: false)
      add(:format, :string, null: false)
      add(:restore_mode, :string, null: false, default: "add")
      add(:ownership, :string, null: false, default: "preserve")
      add(:status, :string, null: false, default: "queued")
      add(:stage, :string, null: false, default: "Waiting")
      add(:created_by, :string, null: false)
      add(:filename, :string, null: false)
      add(:bytes, :bigint, null: false, default: 0)
      add(:safety_bytes, :bigint, null: false, default: 0)
      add(:sha256, :string)
      add(:error, :text)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      index(:database_backups, [:node_id, :host, :port, :database, :inserted_at],
        prefix: "_supavisor"
      )
    )

    create(index(:database_backups, [:node_id, :status], prefix: "_supavisor"))
  end
end
