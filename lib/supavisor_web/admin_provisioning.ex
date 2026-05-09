defmodule SupavisorWeb.AdminProvisioning do
  @moduledoc false

  alias Supavisor.Tenants

  @identifier_regex ~r/\A[a-z_][a-z0-9_]{0,62}\z/
  @default_auth_query "SELECT rolname, rolpassword FROM pg_authid WHERE rolname=$1"

  def enabled? do
    config()
    |> Keyword.get(:enabled, false)
  end

  def available? do
    enabled?() and configured?()
  end

  def configured? do
    provisioner = provisioner_config()

    Keyword.get(provisioner, :username) not in [nil, ""] and
      Keyword.get(provisioner, :password) not in [nil, ""] and
      allowed_targets() != []
  end

  def allowed_targets do
    config()
    |> Keyword.get(:allowed_targets, [])
    |> case do
      targets when is_list(targets) -> targets
      _ -> []
    end
  end

  def default_target do
    allowed_targets()
    |> List.first()
    |> case do
      {host, port} -> {host, port}
      %{host: host, port: port} -> {host, port}
      _ -> {"localhost", 5432}
    end
  end

  def provision(attrs) do
    with :ok <- ensure_enabled(),
         :ok <- ensure_configured(),
         :ok <- ensure_allowed_target(attrs.host, attrs.port),
         :ok <- ensure_tenant_missing(attrs.external_id),
         :ok <- validate_identifier(attrs.database_name),
         :ok <- validate_identifier(attrs.role_name) do
      do_provision(attrs)
    end
  end

  def validate_identifier(identifier) when is_binary(identifier) do
    if identifier =~ @identifier_regex do
      :ok
    else
      {:error, :invalid_identifier}
    end
  end

  def validate_identifier(_identifier), do: {:error, :invalid_identifier}

  def quote_identifier(identifier) do
    with :ok <- validate_identifier(identifier) do
      {:ok, ~s("#{identifier}")}
    end
  end

  defp do_provision(attrs) do
    password = generate_password()

    with {:ok, conn} <- connect(attrs),
         result <- provision_objects(conn, attrs, password) do
      stop_conn(conn)
      result
    end
  end

  defp provision_objects(conn, attrs, password) do
    with :ok <- ensure_database_missing(conn, attrs.database_name),
         :ok <- ensure_role_missing(conn, attrs.role_name) do
      create_objects(conn, attrs, password)
    end
  end

  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, :disabled}
  end

  defp ensure_configured do
    if configured?(), do: :ok, else: {:error, :not_configured}
  end

  defp create_objects(conn, attrs, password) do
    case create_role(conn, attrs.role_name, password) do
      :ok -> create_database_object(conn, attrs, password)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_database_object(conn, attrs, password) do
    case create_database(conn, attrs.database_name, attrs.role_name) do
      :ok -> create_metadata(conn, attrs, password)
      {:error, reason} -> rollback(conn, attrs, %{role: true, database: false}, reason)
    end
  end

  defp create_metadata(conn, attrs, password) do
    case create_tenant(attrs, password) do
      :ok ->
        {:ok,
         %{
           tenant_external_id: attrs.external_id,
           database_name: attrs.database_name,
           role_name: attrs.role_name,
           generated_password: password
         }}

      {:error, reason} ->
        rollback(conn, attrs, %{role: true, database: true}, reason)
    end
  end

  defp rollback(conn, attrs, created, reason) do
    cleanup_created(conn, attrs, created)
    {:error, reason}
  end

  defp ensure_allowed_target(host, port) do
    normalized = {to_string(host), port}

    allowed? =
      Enum.any?(allowed_targets(), fn
        {allowed_host, allowed_port} ->
          normalized == {to_string(allowed_host), allowed_port}

        %{host: allowed_host, port: allowed_port} ->
          normalized == {to_string(allowed_host), allowed_port}

        _ ->
          false
      end)

    if allowed?, do: :ok, else: {:error, :target_not_allowed}
  end

  defp ensure_tenant_missing(external_id) do
    if Tenants.get_tenant_by_external_id(external_id) do
      {:error, :tenant_exists}
    else
      :ok
    end
  end

  defp connect(attrs) do
    provisioner = provisioner_config()

    Postgrex.start_link(
      hostname: attrs.host,
      port: attrs.port,
      username: Keyword.fetch!(provisioner, :username),
      password: Keyword.fetch!(provisioner, :password),
      database: Keyword.get(provisioner, :database, "postgres"),
      ssl: Keyword.get(provisioner, :ssl, false),
      ssl_opts: Keyword.get(provisioner, :ssl_opts, []),
      parameters: [application_name: "supavisor_admin_provisioning"]
    )
  end

  defp ensure_database_missing(conn, database_name) do
    case Postgrex.query(conn, "select 1 from pg_database where datname = $1", [database_name]) do
      {:ok, %{num_rows: 0}} -> :ok
      {:ok, _} -> {:error, :database_exists}
      {:error, reason} -> {:error, {:postgres, reason}}
    end
  end

  defp ensure_role_missing(conn, role_name) do
    case Postgrex.query(conn, "select 1 from pg_roles where rolname = $1", [role_name]) do
      {:ok, %{num_rows: 0}} -> :ok
      {:ok, _} -> {:error, :role_exists}
      {:error, reason} -> {:error, {:postgres, reason}}
    end
  end

  defp create_role(conn, role_name, password) do
    with {:ok, role} <- quote_identifier(role_name) do
      sql = "create role #{role} login password #{quote_literal(password)}"
      exec(conn, sql)
    end
  end

  defp create_database(conn, database_name, role_name) do
    with {:ok, database} <- quote_identifier(database_name),
         {:ok, role} <- quote_identifier(role_name) do
      exec(conn, "create database #{database} owner #{role}")
    end
  end

  defp create_tenant(attrs, password) do
    attrs
    |> tenant_attrs(password)
    |> Tenants.create_tenant()
    |> case do
      {:ok, _tenant} -> :ok
      {:error, changeset} -> {:error, {:tenant_changeset, changeset}}
    end
  end

  defp tenant_attrs(attrs, password) do
    require_user = attrs.auth_mode == "stored_users"

    %{
      "default_parameter_status" => %{},
      "external_id" => attrs.external_id,
      "db_host" => attrs.host,
      "db_port" => attrs.port,
      "db_database" => attrs.database_name,
      "ip_version" => attrs.ip_version,
      "upstream_ssl" => attrs.upstream_ssl,
      "upstream_verify" => if(attrs.upstream_ssl, do: attrs.upstream_verify, else: nil),
      "upstream_tls_ca" => attrs.upstream_tls_ca,
      "enforce_ssl" => attrs.enforce_ssl,
      "require_user" => require_user,
      "auth_query" => if(require_user, do: nil, else: attrs.auth_query || @default_auth_query),
      "default_pool_size" => attrs.default_pool_size,
      "default_max_clients" => attrs.default_max_clients,
      "client_idle_timeout" => attrs.client_idle_timeout,
      "client_heartbeat_interval" => attrs.client_heartbeat_interval,
      "allow_list" => attrs.allow_list,
      "feature_flags" => %{},
      "users" => [
        %{
          "db_user" => attrs.role_name,
          "db_user_alias" => attrs.role_name,
          "db_password" => password,
          "pool_size" => attrs.default_pool_size,
          "mode_type" => "transaction",
          "pool_checkout_timeout" => 60_000,
          "is_manager" => attrs.auth_mode == "auth_query"
        }
      ]
    }
  end

  defp cleanup_created(conn, attrs, created) do
    if created.database do
      with {:ok, database} <- quote_identifier(attrs.database_name) do
        _ = exec(conn, "drop database #{database}")
      end
    end

    if created.role do
      with {:ok, role} <- quote_identifier(attrs.role_name) do
        _ = exec(conn, "drop role #{role}")
      end
    end
  end

  defp exec(conn, sql) do
    case Postgrex.query(conn, sql, []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:postgres, reason}}
    end
  end

  defp generate_password do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp quote_literal(value) do
    value = value |> to_string() |> String.replace("'", "''")
    "'#{value}'"
  end

  defp stop_conn(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn)
  end

  defp config do
    Application.get_env(:supavisor, __MODULE__, [])
  end

  defp provisioner_config do
    case Keyword.get(config(), :provisioner, []) do
      provisioner when is_list(provisioner) -> provisioner
      _ -> []
    end
  end
end
