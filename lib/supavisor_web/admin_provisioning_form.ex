defmodule SupavisorWeb.AdminProvisioningForm do
  @moduledoc false

  alias Supavisor.Helpers
  alias SupavisorWeb.AdminProvisioning
  alias SupavisorWeb.AdminForm

  @default_auth_query "SELECT rolname, rolpassword FROM pg_authid WHERE rolname=$1"

  def new_params do
    {host, port} = AdminProvisioning.default_target()

    %{
      "external_id" => "",
      "target_host" => host,
      "target_port" => to_string(port),
      "database_name" => "",
      "role_name" => "",
      "auth_mode" => "stored_users",
      "auth_query" => @default_auth_query,
      "ip_version" => "auto",
      "upstream_ssl" => "false",
      "upstream_verify" => "none",
      "upstream_tls_ca" => "",
      "enforce_ssl" => "false",
      "default_pool_size" => "15",
      "default_max_clients" => "1000",
      "client_idle_timeout" => "0",
      "client_heartbeat_interval" => "60",
      "allow_list" => "0.0.0.0/0\n::/0"
    }
  end

  def normalize_params(params) do
    Map.merge(new_params(), params || %{})
  end

  def to_attrs(params) do
    params = normalize_params(params)
    errors = collect_errors(params)

    if errors == %{} do
      {:ok, build_attrs(params)}
    else
      {:error, errors, params}
    end
  end

  def errors_from_reason(:disabled),
    do: %{base: ["Database provisioning is disabled in application config."]}

  def errors_from_reason(:not_configured),
    do: %{
      base: ["Database provisioning needs provisioner credentials and allowed targets in config."]
    }

  def errors_from_reason(:target_not_allowed),
    do: %{base: ["That host and port are not in the allowed provisioning targets."]}

  def errors_from_reason(:tenant_exists),
    do: %{base: ["A tenant with that external ID already exists."]}

  def errors_from_reason(:database_exists),
    do: %{base: ["That database already exists. Pick a new database name."]}

  def errors_from_reason(:role_exists),
    do: %{base: ["That role already exists. Pick a new role name."]}

  def errors_from_reason(:invalid_identifier),
    do: %{base: ["Database and role names must be lowercase Postgres identifiers."]}

  def errors_from_reason(:unsupported_auth_mode),
    do: %{
      base: [
        "Provision new databases with a stored user. Configure an existing manager separately for auth-query authentication."
      ]
    }

  def errors_from_reason(:connection_failed),
    do: %{
      base: [
        "Could not connect to PostgreSQL. Check the server address and provisioner credentials."
      ]
    }

  def errors_from_reason({:tenant_changeset, changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    %{base: ["Could not save Supavisor metadata: #{inspect(errors)}"]}
  end

  def errors_from_reason({:postgres, %Postgrex.Error{postgres: %{message: message}}}),
    do: %{base: ["Postgres rejected the provisioning SQL: #{message}"]}

  def errors_from_reason({:postgres, %DBConnection.ConnectionError{}}),
    do: %{
      base: ["Could not connect to the target Postgres server with the configured provisioner."]
    }

  def errors_from_reason(_reason),
    do: %{base: ["Provisioning failed. Nothing pre-existing was modified."]}

  defp collect_errors(params) do
    %{}
    |> require_present(params, "external_id", "Tenant external ID is required")
    |> require_present(params, "target_host", "Target host is required")
    |> require_integer(params, "target_port", "Target port must be a number")
    |> require_identifier(
      params,
      "database_name",
      "Database name must be a lowercase Postgres identifier"
    )
    |> require_identifier(
      params,
      "role_name",
      "Role name must be a lowercase Postgres identifier"
    )
    |> require_integer(params, "default_pool_size", "Default pool size must be a number")
    |> require_integer(params, "default_max_clients", "Default max clients must be a number")
    |> require_integer(params, "client_idle_timeout", "Client idle timeout must be a number")
    |> require_integer(params, "client_heartbeat_interval", "Heartbeat interval must be a number")
    |> require_auth_query(params)
    |> require_upstream_tls_ca(params)
    |> AdminForm.integer(params, "target_port", 1, 65_535)
    |> AdminForm.integer(params, "default_pool_size", 1)
    |> AdminForm.integer(params, "default_max_clients", 1)
    |> AdminForm.integer(params, "client_idle_timeout", 0)
    |> AdminForm.integer(params, "client_heartbeat_interval", 1)
    |> AdminForm.choice(params, "auth_mode", ["stored_users"])
    |> AdminForm.choice(params, "ip_version", ["auto", "v4", "v6"])
    |> AdminForm.choice(params, "upstream_verify", ["none", "peer"])
  end

  defp require_present(errors, params, field, message) do
    if blank?(params[field]), do: add_error(errors, field, message), else: errors
  end

  defp require_integer(errors, params, field, message) do
    case parse_optional_integer(params[field]) do
      {:ok, _} -> errors
      :error -> add_error(errors, field, message)
    end
  end

  defp require_identifier(errors, params, field, message) do
    case AdminProvisioning.validate_identifier(params[field]) do
      :ok -> errors
      {:error, _reason} -> add_error(errors, field, message)
    end
  end

  defp require_auth_query(errors, %{"auth_mode" => "auth_query", "auth_query" => auth_query}) do
    if blank?(auth_query),
      do: add_error(errors, "auth_query", "Auth query is required"),
      else: errors
  end

  defp require_auth_query(errors, _params), do: errors

  defp require_upstream_tls_ca(errors, params) do
    if truthy?(params["upstream_ssl"]) and params["upstream_verify"] == "peer" do
      case parse_upstream_tls_ca(params["upstream_tls_ca"]) do
        {:ok, _cert} ->
          errors

        {:error, :blank} ->
          add_error(errors, "upstream_tls_ca", "CA certificate is required for peer verification")

        {:error, _reason} ->
          add_error(errors, "upstream_tls_ca", "CA certificate must be a PEM certificate")
      end
    else
      errors
    end
  end

  defp build_attrs(params) do
    upstream_ssl = truthy?(params["upstream_ssl"])

    %{
      external_id: params["external_id"],
      host: params["target_host"],
      port: parse_integer!(params["target_port"]),
      database_name: params["database_name"],
      role_name: params["role_name"],
      auth_mode: params["auth_mode"],
      auth_query: blank_to_nil(params["auth_query"]),
      ip_version: params["ip_version"],
      upstream_ssl: upstream_ssl,
      upstream_verify: if(upstream_ssl, do: params["upstream_verify"], else: nil),
      upstream_tls_ca: parse_upstream_tls_ca!(params),
      enforce_ssl: truthy?(params["enforce_ssl"]),
      default_pool_size: parse_integer!(params["default_pool_size"]),
      default_max_clients: parse_integer!(params["default_max_clients"]),
      client_idle_timeout: parse_integer!(params["client_idle_timeout"]),
      client_heartbeat_interval: parse_integer!(params["client_heartbeat_interval"]),
      allow_list: parse_allow_list(params["allow_list"])
    }
  end

  defp parse_upstream_tls_ca!(
         %{"upstream_ssl" => upstream_ssl, "upstream_verify" => "peer"} = params
       )
       when upstream_ssl == "true" do
    {:ok, cert} = parse_upstream_tls_ca(params["upstream_tls_ca"])
    cert
  end

  defp parse_upstream_tls_ca!(_params), do: nil

  defp parse_upstream_tls_ca(value) do
    cond do
      blank?(value) -> {:error, :blank}
      true -> Helpers.cert_to_bin(value)
    end
  end

  defp parse_allow_list(value) do
    value
    |> to_string()
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp parse_integer!(value) do
    {:ok, integer} = parse_optional_integer(value)
    integer
  end

  defp parse_optional_integer(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_optional_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp truthy?(value), do: to_string(value) == "true"
  defp blank?(value), do: value in [nil, ""]
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

  defp add_error(errors, field, message) do
    Map.update(errors, field, [message], &[message | &1])
  end
end
