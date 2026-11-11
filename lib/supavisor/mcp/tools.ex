defmodule Supavisor.MCP.Tools do
  @moduledoc "The MCP database tool catalog and its authorization boundary."
  alias Supavisor.MCP.{Auth, Database}
  alias SupavisorWeb.{AdminProvisioning, AdminProvisioningForm}

  @tenant %{
    type: "string",
    minLength: 1,
    maxLength: 255,
    description: "Supavisor tenant external ID"
  }
  @identifier %{type: "string", pattern: "^[a-z_][a-z0-9_]{0,62}$"}

  def list(grant) do
    catalog() |> Enum.filter(&(&1.scope in grant.scopes)) |> Enum.map(&Map.delete(&1, :scope))
  end

  def call(grant, name, args) when is_binary(name) and is_map(args) do
    case Enum.find(catalog(), &(&1.name == name)) do
      nil ->
        {:error, :unknown_tool}

      tool ->
        cond do
          tool.scope not in grant.scopes ->
            {:error, "This connection has not been granted #{tool.scope}."}

          Enum.any?(tool.inputSchema.required, &(not Map.has_key?(args, &1))) ->
            {:error, "Required tool arguments are missing."}

          Enum.any?(Map.keys(args), &(not Map.has_key?(tool.inputSchema.properties, &1))) ->
            {:error, "Unknown tool argument."}

          not Enum.all?(args, fn {key, value} ->
            valid_argument?(value, tool.inputSchema.properties[key])
          end) ->
            {:error, "Invalid tool argument types or values."}

          true ->
            execute(grant, name, args)
        end
    end
  end

  def call(_, _, _), do: {:error, "Invalid tool arguments."}

  defp execute(grant, "list_databases", _), do: Database.list(grant)

  defp execute(grant, "describe_database", %{"tenant_id" => id}) when is_binary(id),
    do: Database.describe(grant, id)

  defp execute(grant, "migration_history", %{"tenant_id" => id}) when is_binary(id),
    do: Database.history(grant, id)

  defp execute(grant, "read_query", %{"tenant_id" => id, "sql" => sql} = args) when is_binary(id),
    do:
      Database.query(grant, id, sql, Map.get(args, "parameters", []), Map.get(args, "limit", 100))

  defp execute(grant, "apply_migration", %{
         "tenant_id" => id,
         "name" => name,
         "statements" => statements
       })
       when is_binary(id),
       do: Database.migrate(grant, id, name, statements)

  defp execute(grant, "create_database", params) do
    # Provisioning uses only configured server targets and generates the owner password.
    # The password is deliberately never included in MCP results.
    with true <- params["external_id"] != "*",
         true <-
           Enum.all?(params, fn {_key, value} ->
             is_binary(value) or is_integer(value) or is_boolean(value)
           end),
         {:ok, attrs} <-
           params
           |> Map.put_new("external_id", params["database_name"])
           |> Map.put_new("role_name", params["database_name"])
           |> Map.new(fn {k, v} -> {k, to_string(v)} end)
           |> AdminProvisioningForm.to_attrs(),
         {:ok, result} <- AdminProvisioning.provision(attrs),
         result_grant when result_grant == :ok or elem(result_grant, 0) == :ok <-
           Auth.grant_tenant(grant, result.tenant_external_id) do
      {:ok, Map.take(result, [:tenant_external_id, :database_name, :role_name])}
    else
      {:error, errors, _} when is_map(errors) ->
        {:error, "Invalid provisioning fields: #{Enum.join(Map.keys(errors), ", ")}."}

      {:error, _} ->
        {:error,
         "Could not provision the database. Check the configured provisioner, allowed target, and unique database/role/tenant names."}

      _ ->
        {:error, "Invalid database creation arguments."}
    end
  end

  defp execute(_, _, _), do: {:error, "Invalid tool arguments."}

  defp catalog do
    [
      tool(
        "list_databases",
        "List databases authorized for this connection.",
        "db:read",
        %{},
        [],
        true
      ),
      tool(
        "describe_database",
        "List schema columns (up to 200) in an authorized database.",
        "db:read",
        %{"tenant_id" => @tenant},
        ["tenant_id"],
        true
      ),
      tool(
        "read_query",
        "Run one read-only SELECT/WITH as the tenant role. Maximum 200 rows; values are bounded to 4096 characters.",
        "db:read",
        %{
          "tenant_id" => @tenant,
          "sql" => %{type: "string", maxLength: 65_536},
          "parameters" => %{type: "array", maxItems: 100},
          "limit" => %{type: "integer", minimum: 1, maximum: 200, default: 100}
        },
        ["tenant_id", "sql"],
        true
      ),
      tool(
        "migration_history",
        "List up to 200 migrations applied through this MCP, newest first, including SQL, checksum, time and administrator.",
        "db:read",
        %{"tenant_id" => @tenant},
        ["tenant_id"],
        true
      ),
      tool(
        "create_database",
        "Create a PostgreSQL database, dedicated owner role and Supavisor tenant on a configured allowed target. Requires provisioning enabled. Returns no credentials; the new database joins this grant.",
        "db:create",
        %{
          "external_id" => @tenant,
          "database_name" => @identifier,
          "role_name" => @identifier,
          "target_host" => %{type: "string"},
          "target_port" => %{type: "integer", minimum: 1, maximum: 65_535},
          "upstream_ssl" => %{
            type: "boolean",
            description: "Use TLS for tenant upstream connections"
          },
          "upstream_verify" => %{type: "string", enum: ["none", "peer"]},
          "upstream_tls_ca" => %{
            type: "string",
            description: "PEM CA certificate required for peer verification"
          },
          "enforce_ssl" => %{
            type: "boolean",
            description: "Require TLS for pooler client connections"
          }
        },
        ["database_name"],
        false
      ),
      tool(
        "apply_migration",
        "Apply a named migration atomically as the tenant role and record its SQL/checksum/actor. One SQL statement per array entry. Repeating identical name and SQL is idempotent; failure rolls back schema and history. No transaction control or role/database administration.",
        "db:migrate",
        %{
          "tenant_id" => @tenant,
          "name" => %{type: "string", minLength: 1, maxLength: 128},
          "statements" => %{
            type: "array",
            minItems: 1,
            maxItems: 100,
            items: %{type: "string", maxLength: 65_536}
          }
        },
        ["tenant_id", "name", "statements"],
        false
      )
    ]
  end

  defp valid_argument?(value, %{type: "string"} = schema) when is_binary(value) do
    size = String.length(value)

    size >= Map.get(schema, :minLength, 0) and size <= Map.get(schema, :maxLength, 262_144) and
      (not Map.has_key?(schema, :pattern) or Regex.match?(Regex.compile!(schema.pattern), value)) and
      (not Map.has_key?(schema, :enum) or value in schema.enum)
  end

  defp valid_argument?(value, %{type: "integer"} = schema) when is_integer(value),
    do: value >= Map.get(schema, :minimum, value) and value <= Map.get(schema, :maximum, value)

  defp valid_argument?(value, %{type: "boolean"}), do: is_boolean(value)

  defp valid_argument?(value, %{type: "array"} = schema) when is_list(value) do
    length(value) >= Map.get(schema, :minItems, 0) and
      length(value) <= Map.get(schema, :maxItems, 100) and
      (not Map.has_key?(schema, :items) or Enum.all?(value, &valid_argument?(&1, schema.items)))
  end

  defp valid_argument?(_, _), do: false

  defp tool(name, description, scope, properties, required, read_only) do
    %{
      name: name,
      description: description,
      scope: scope,
      inputSchema: %{
        type: "object",
        properties: properties,
        required: required,
        additionalProperties: false
      },
      annotations: %{
        readOnlyHint: read_only,
        destructiveHint: not read_only,
        openWorldHint: false
      }
    }
  end
end
