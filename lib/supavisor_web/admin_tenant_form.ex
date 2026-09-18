defmodule SupavisorWeb.AdminTenantForm do
  @moduledoc false

  alias Supavisor.Tenants.Tenant
  alias SupavisorWeb.AdminForm

  @default_auth_query "SELECT rolname, rolpassword FROM pg_authid WHERE rolname=$1"

  def new_params do
    %{
      "external_id" => "",
      "db_host" => "localhost",
      "db_port" => "5432",
      "db_database" => "postgres",
      "auth_mode" => "stored_users",
      "auth_query" => @default_auth_query,
      "default_parameter_status" => "{}",
      "ip_version" => "auto",
      "upstream_ssl" => "false",
      "upstream_verify" => "none",
      "enforce_ssl" => "false",
      "default_pool_size" => "15",
      "sni_hostname" => "",
      "default_max_clients" => "1000",
      "client_idle_timeout" => "0",
      "client_heartbeat_interval" => "60",
      "allow_list" => "0.0.0.0/0\n::/0",
      "availability_zone" => "",
      "feature_flags" => "{}",
      "use_jit" => "false",
      "jit_api_url" => "",
      "users" => %{"0" => default_user_params()}
    }
  end

  def from_tenant(%Tenant{} = tenant) do
    %{
      "external_id" => tenant.external_id,
      "db_host" => tenant.db_host,
      "db_port" => to_string(tenant.db_port || ""),
      "db_database" => tenant.db_database,
      "auth_mode" => if(tenant.require_user, do: "stored_users", else: "auth_query"),
      "auth_query" => tenant.auth_query || @default_auth_query,
      "default_parameter_status" => encode_map(tenant.default_parameter_status),
      "ip_version" => to_string(tenant.ip_version || :auto),
      "upstream_ssl" => to_string(tenant.upstream_ssl || false),
      "upstream_verify" => to_string(tenant.upstream_verify || :none),
      "enforce_ssl" => to_string(tenant.enforce_ssl || false),
      "default_pool_size" => to_string(tenant.default_pool_size || 15),
      "sni_hostname" => tenant.sni_hostname || "",
      "default_max_clients" => to_string(tenant.default_max_clients || 1000),
      "client_idle_timeout" => to_string(tenant.client_idle_timeout || 0),
      "client_heartbeat_interval" => to_string(tenant.client_heartbeat_interval || 60),
      "allow_list" => Enum.join(tenant.allow_list || ["0.0.0.0/0", "::/0"], "\n"),
      "availability_zone" => tenant.availability_zone || "",
      "feature_flags" => encode_map(tenant.feature_flags || %{}),
      "use_jit" => to_string(tenant.use_jit || false),
      "jit_api_url" => tenant.jit_api_url || "",
      "users" => users_from_tenant(tenant)
    }
  end

  def add_user(params) do
    users = Map.get(params, "users", %{})
    next_index = users |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> -1 end)
    put_in(params, ["users"], Map.put(users, to_string(next_index + 1), default_user_params()))
  end

  def remove_user(params, index) do
    users =
      params
      |> Map.get("users", %{})
      |> Map.delete(to_string(index))

    put_in(params, ["users"], users)
  end

  def to_attrs(params, existing \\ nil) do
    params = normalize_params(params)
    errors = collect_errors(params) |> validate_user_credentials(params, existing)

    if errors == %{} do
      {:ok, build_attrs(params, existing)}
    else
      {:error, errors, params}
    end
  end

  def errors_from_changeset(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    %{base: ["Could not save tenant: #{inspect(errors)}"]}
  end

  defp validate_user_credentials(errors, params, existing) do
    saved =
      case existing do
        %Tenant{users: users} -> Map.new(users, &{&1.id, &1})
        _ -> %{}
      end

    Enum.reduce(normalized_user_rows(params), errors, fn user, errors ->
      previous = Map.get(saved, user["id"])

      cond do
        not blank?(user["id"]) and is_nil(previous) ->
          add_error(errors, :base, "That user row no longer exists. Reload this page.")

        blank?(user["db_password"]) and (is_nil(previous) or previous.db_user != user["db_user"]) ->
          add_error(errors, :base, "Enter the password for the selected PostgreSQL login role.")

        true ->
          errors
      end
    end)
  end

  defp default_user_params do
    %{
      "id" => "",
      "db_user_alias" => "",
      "db_user" => "",
      "db_password" => "",
      "is_manager" => "false",
      "mode_type" => "transaction",
      "pool_size" => "15",
      "pool_checkout_timeout" => "60000",
      "max_clients" => ""
    }
  end

  defp users_from_tenant(%Tenant{users: users}) do
    users
    |> Enum.with_index()
    |> Map.new(fn {user, index} ->
      {to_string(index),
       %{
         "id" => user.id,
         "db_user_alias" => user.db_user_alias || user.db_user,
         "db_user" => user.db_user,
         "db_password" => "",
         "is_manager" => to_string(user.is_manager || false),
         "mode_type" => to_string(user.mode_type || :transaction),
         "pool_size" => to_string(user.pool_size || 15),
         "pool_checkout_timeout" => to_string(user.pool_checkout_timeout || 60_000),
         "max_clients" => to_string(user.max_clients || "")
       }}
    end)
    |> ensure_user_row()
  end

  defp ensure_user_row(users) when map_size(users) == 0, do: %{"0" => default_user_params()}
  defp ensure_user_row(users), do: users

  def normalize_params(params) do
    new_params()
    |> Map.merge(params || %{})
    |> Map.update!("users", fn users ->
      users
      |> case do
        users when is_map(users) -> users
        _ -> %{}
      end
      |> Enum.map(fn {index, user} ->
        {to_string(index), Map.merge(default_user_params(), user)}
      end)
      |> Map.new()
    end)
  end

  defp collect_errors(params) do
    %{}
    |> require_present(params, "external_id", "External ID is required")
    |> require_present(params, "db_host", "Database host is required")
    |> require_present(params, "db_database", "Database name is required")
    |> require_integer(params, "db_port", "Database port must be a number")
    |> require_json_map(
      params,
      "default_parameter_status",
      "Default parameter status must be JSON object"
    )
    |> require_json_map(params, "feature_flags", "Feature flags must be a JSON object")
    |> require_auth_query(params)
    |> require_users(params)
    |> AdminForm.integer(params, "db_port", 1, 65_535)
    |> AdminForm.integer(params, "default_pool_size", 1)
    |> AdminForm.integer(params, "default_max_clients", 1)
    |> AdminForm.integer(params, "client_idle_timeout", 0)
    |> AdminForm.integer(params, "client_heartbeat_interval", 1)
    |> AdminForm.choice(params, "auth_mode", ["stored_users", "auth_query"])
    |> validate_user_numbers(params)
  end

  defp validate_user_numbers(errors, params) do
    Enum.reduce(normalized_user_rows(params), errors, fn user, errors ->
      user_errors =
        %{}
        |> AdminForm.integer(user, "pool_size", 1)
        |> AdminForm.integer(user, "pool_checkout_timeout", 1)
        |> AdminForm.integer(user, "max_clients", 0, 2_147_483_647, true)

      if user_errors == %{},
        do: errors,
        else:
          add_error(
            errors,
            :base,
            "User pool size and checkout timeout must be positive integers; max clients must be zero or greater"
          )
    end)
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

  defp require_json_map(errors, params, field, message) do
    case parse_json_map(params[field]) do
      {:ok, _map} -> errors
      :error -> add_error(errors, field, message)
    end
  end

  defp require_auth_query(errors, %{"auth_mode" => "auth_query", "auth_query" => auth_query}) do
    if blank?(auth_query),
      do: add_error(errors, "auth_query", "Auth query is required"),
      else: errors
  end

  defp require_auth_query(errors, _params), do: errors

  defp require_users(errors, params) do
    users = normalized_user_rows(params)

    cond do
      users == [] ->
        add_error(errors, :base, "Add at least one database user")

      Enum.any?(users, &blank?(&1["db_user"])) ->
        add_error(errors, :base, "Every user row needs a database user")

      Enum.any?(users, &blank?(&1["pool_size"])) ->
        add_error(errors, :base, "Every user row needs a pool size")

      true ->
        errors
    end
  end

  defp build_attrs(params, existing) do
    require_user = params["auth_mode"] == "stored_users"
    upstream_ssl = truthy?(params["upstream_ssl"])

    %{
      "default_parameter_status" => parse_json_map!(params["default_parameter_status"]),
      "external_id" => params["external_id"],
      "db_host" => params["db_host"],
      "db_port" => parse_integer!(params["db_port"]),
      "db_database" => params["db_database"],
      "ip_version" => params["ip_version"],
      "upstream_ssl" => upstream_ssl,
      "upstream_verify" => if(upstream_ssl, do: params["upstream_verify"], else: nil),
      "enforce_ssl" => truthy?(params["enforce_ssl"]),
      "require_user" => require_user,
      "auth_query" => if(require_user, do: nil, else: params["auth_query"]),
      "default_pool_size" => parse_integer!(params["default_pool_size"]),
      "sni_hostname" => blank_to_nil(params["sni_hostname"]),
      "default_max_clients" => parse_integer!(params["default_max_clients"]),
      "client_idle_timeout" => parse_integer!(params["client_idle_timeout"]),
      "client_heartbeat_interval" => parse_integer!(params["client_heartbeat_interval"]),
      "allow_list" => parse_allow_list(params["allow_list"]),
      "availability_zone" => blank_to_nil(params["availability_zone"]),
      "feature_flags" => parse_json_map!(params["feature_flags"]),
      "use_jit" => truthy?(params["use_jit"]),
      "jit_api_url" => blank_to_nil(params["jit_api_url"]),
      "users" => build_users(params, existing)
    }
  end

  defp build_users(params, existing) do
    existing_passwords =
      existing
      |> case do
        %Tenant{users: users} -> Map.new(users, &{&1.id, &1.db_password})
        _ -> %{}
      end

    params
    |> normalized_user_rows()
    |> Enum.map(fn user ->
      user =
        user
        |> put_optional_integer("max_clients")
        |> Map.put("pool_size", parse_integer!(user["pool_size"]))
        |> Map.put("pool_checkout_timeout", parse_integer!(user["pool_checkout_timeout"]))
        |> Map.put("is_manager", truthy?(user["is_manager"]))

      case {user["id"], user["db_password"]} do
        {id, password} when id not in [nil, ""] and password in [nil, ""] ->
          Map.put(user, "db_password", Map.fetch!(existing_passwords, id))

        _ ->
          user
      end
    end)
  end

  defp normalized_user_rows(params) do
    params
    |> Map.get("users", %{})
    |> Enum.sort_by(fn {index, _} -> String.to_integer(to_string(index)) end)
    |> Enum.map(fn {_index, user} -> user end)
    |> Enum.reject(fn user ->
      blank?(user["id"]) and blank?(user["db_user"]) and blank?(user["db_password"])
    end)
  end

  defp put_optional_integer(user, field) do
    case parse_optional_integer(user[field]) do
      {:ok, nil} -> Map.put(user, field, nil)
      {:ok, value} -> Map.put(user, field, value)
      :error -> user
    end
  end

  defp parse_allow_list(value) do
    value
    |> to_string()
    |> String.split(~r/[\n,]/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp parse_json_map!(value) do
    {:ok, map} = parse_json_map(value)
    map
  end

  defp parse_json_map(value) do
    case JSON.decode(to_string(value || "{}")) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp parse_integer!(value) do
    {:ok, value} = parse_optional_integer(value)
    value
  end

  defp parse_optional_integer(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_optional_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp encode_map(value) when is_map(value), do: JSON.encode!(value)
  defp encode_map(_), do: "{}"

  defp truthy?(value), do: to_string(value) == "true"

  defp blank?(value), do: value in [nil, ""]

  defp blank_to_nil(value) do
    if blank?(value), do: nil, else: value
  end

  defp add_error(errors, field, message) do
    Map.update(errors, field, [message], &[message | &1])
  end
end
