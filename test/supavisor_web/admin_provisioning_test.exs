defmodule SupavisorWeb.AdminProvisioningTest do
  use ExUnit.Case, async: false

  alias SupavisorWeb.AdminProvisioning
  alias SupavisorWeb.AdminProvisioningForm

  setup do
    original = Application.fetch_env!(:supavisor, AdminProvisioning)

    on_exit(fn ->
      Application.put_env(:supavisor, AdminProvisioning, original)
    end)

    :ok
  end

  test "validates strict Postgres identifiers" do
    assert :ok = AdminProvisioning.validate_identifier("tenant_db_1")
    assert {:ok, ~s("tenant_db_1")} = AdminProvisioning.quote_identifier("tenant_db_1")

    assert {:error, :invalid_identifier} = AdminProvisioning.validate_identifier("Tenant")
    assert {:error, :invalid_identifier} = AdminProvisioning.validate_identifier("tenant-db")
    assert {:error, :invalid_identifier} = AdminProvisioning.validate_identifier("1tenant")

    assert {:error, :invalid_identifier} =
             AdminProvisioning.validate_identifier(String.duplicate("a", 64))
  end

  test "disabled provisioning blocks before connecting to Postgres" do
    Application.put_env(:supavisor, AdminProvisioning,
      enabled: false,
      provisioner: [username: "postgres", password: "secret"],
      allowed_targets: [{"localhost", 5432}]
    )

    assert {:error, :disabled} = AdminProvisioning.provision(attrs())
  end

  test "missing provisioner config blocks before connecting to Postgres" do
    Application.put_env(:supavisor, AdminProvisioning,
      enabled: true,
      provisioner: [username: "postgres"],
      allowed_targets: [{"localhost", 5432}]
    )

    assert {:error, :not_configured} = AdminProvisioning.provision(attrs())
  end

  test "target allow-list blocks before connecting to Postgres" do
    Application.put_env(:supavisor, AdminProvisioning,
      enabled: true,
      provisioner: [username: "postgres", password: "secret"],
      allowed_targets: [{"localhost", 5432}]
    )

    assert {:error, :target_not_allowed} =
             AdminProvisioning.provision(%{attrs() | host: "db.internal"})
  end

  test "form normalizes safe attrs and hides upstream verification when ssl is off" do
    {:ok, attrs} =
      AdminProvisioningForm.to_attrs(%{
        "external_id" => "tenant_a",
        "target_host" => "localhost",
        "target_port" => "5432",
        "database_name" => "tenant_a_db",
        "role_name" => "tenant_a_role",
        "upstream_ssl" => "false",
        "upstream_verify" => "peer"
      })

    assert attrs.database_name == "tenant_a_db"
    assert attrs.role_name == "tenant_a_role"
    assert attrs.upstream_ssl == false
    assert attrs.upstream_verify == nil
    assert attrs.upstream_tls_ca == nil
  end

  test "form rejects unsafe identifiers" do
    assert {:error, errors, _params} =
             AdminProvisioningForm.to_attrs(%{
               "external_id" => "tenant_a",
               "target_host" => "localhost",
               "target_port" => "5432",
               "database_name" => "Tenant-A",
               "role_name" => "tenant_a_role"
             })

    assert errors["database_name"] == ["Database name must be a lowercase Postgres identifier"]
  end

  defp attrs do
    %{
      external_id: "tenant_a",
      host: "localhost",
      port: 5432,
      database_name: "tenant_a_db",
      role_name: "tenant_a_role",
      auth_mode: "stored_users",
      auth_query: nil,
      ip_version: "auto",
      upstream_ssl: false,
      upstream_verify: nil,
      upstream_tls_ca: nil,
      enforce_ssl: false,
      default_pool_size: 15,
      default_max_clients: 1000,
      client_idle_timeout: 0,
      client_heartbeat_interval: 60,
      allow_list: ["0.0.0.0/0", "::/0"]
    }
  end
end
