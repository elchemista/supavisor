defmodule SupavisorWeb.Admin.ProvisionLive do
  use SupavisorWeb, :live_view

  alias SupavisorWeb.{AdminConnection, AdminProvisioning, AdminProvisioningForm}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Create database",
       params: AdminProvisioningForm.new_params() |> Map.put("server", "0"),
       errors: %{},
       connection_host: AdminConnection.host(),
       servers: server_options(),
       provisioning_available: AdminProvisioning.available?(),
       provision_result: nil
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :connection_host, AdminConnection.host(URI.parse(uri).host))}
  end

  @impl true
  def handle_event("validate", %{"provision" => params}, socket) do
    {:noreply,
     assign(socket, params: AdminProvisioningForm.normalize_params(params), errors: %{})}
  end

  def handle_event("save", %{"provision" => params}, socket) do
    with true <- AdminProvisioning.available?(),
         {:ok, attrs} <- AdminProvisioningForm.console_attrs(params),
         {:ok, result} <- AdminProvisioning.provision(attrs) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "#{result.database_name} is ready. Copy your connection URL to start using it."
       )
       |> assign(provision_result: result, errors: %{})}
    else
      false ->
        {:noreply,
         assign(socket,
           errors: AdminProvisioningForm.errors_from_reason(:not_configured),
           provisioning_available: AdminProvisioning.available?()
         )}

      {:error, errors, _resolved_params} when is_map(errors) ->
        {:noreply,
         assign(socket, params: AdminProvisioningForm.normalize_params(params), errors: errors)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           params: AdminProvisioningForm.normalize_params(params),
           errors: AdminProvisioningForm.errors_from_reason(reason)
         )}
    end
  end

  defp server_options do
    AdminProvisioning.allowed_targets()
    |> Enum.with_index()
    |> Enum.map(fn
      {{host, _port}, index} ->
        {"Server #{index + 1} · #{host}", to_string(index)}

      {%{host: host} = target, index} ->
        {Map.get(target, :name, "Server #{index + 1} · #{host}"), to_string(index)}
    end)
  end

  defp error(errors, field), do: Map.get(errors, field, [])

  defp advanced_errors?(errors),
    do: Enum.any?(Map.keys(errors), &(&1 not in ["database_name", "server", :base]))

  defp name(params),
    do: if(params["database_name"] in [nil, ""], do: "my_app", else: params["database_name"])

  defp owner_name(params),
    do: if(params["role_name"] in [nil, ""], do: name(params), else: params["role_name"])

  defp connection_name(params),
    do: if(params["external_id"] in [nil, ""], do: name(params), else: params["external_id"])

  defp transaction_port, do: Application.get_env(:supavisor, :proxy_port_transaction, 6543)
  defp session_port, do: Application.get_env(:supavisor, :proxy_port_session, 5432)

  defp connect_username(result), do: "#{result.role_name}.#{result.tenant_external_id}"

  defp connect_uri(result, host) do
    AdminConnection.uri(
      "postgresql",
      connect_username(result),
      result.generated_password,
      result.database_name,
      transaction_port(),
      host
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page-title-row">
      <div>
        <p class="eyebrow">PostgreSQL</p>
        <h1>{@page_title}</h1>
        <p class="page-subtitle">Choose a name. We create the database, its owner account and your pooled connection automatically.</p>
      </div>
      <.link class="secondary-button" navigate={~p"/admin/postgres"}><span class="hero-arrow-left-mini"></span>Back to databases</.link>
    </div>

    <.notice :for={message <- error(@errors, :base)} kind="error">{message}</.notice>
    <.notice :for={message <- error(@errors, "server")} kind="error">{message}</.notice>

    <section :if={@provision_result} class="form-section success-panel" id="provision-success">
      <div class="form-section-heading">
        <span class="step-marker step-marker-success"><span class="hero-check-mini"></span></span>
        <div><h2>Database is ready</h2><p>Your database and Supavisor connection have been created. Paste this URL into your app to connect.</p></div>
      </div>
      <label class="field"><span>Connection URL</span><input id="provision-connection-url" readonly value={connect_uri(@provision_result, @connection_host)} /></label>
      <div class="form-actions">
        <button type="button" class="primary-button" data-copy-target="#provision-connection-url"><span class="hero-clipboard-document"></span>Copy connection URL</button>
        <.link class="secondary-button" navigate={~p"/admin/postgres"}>View databases</.link>
      </div>
      <p class="copy-feedback" data-copy-feedback role="status"></p>
      <p class="form-note">The generated password is shown only here. Save this URL before leaving; the password is stored encrypted.</p>
      <details class="form-section">
        <summary class="advanced-summary">Connection details</summary>
        <div class="connection-recipe">
          <div><span>Host</span><code>{@connection_host}</code></div>
          <div><span>Transaction pool port</span><code>{transaction_port()}</code></div>
          <div><span>Session pool port</span><code>{session_port()}</code></div>
          <div><span>Database</span><code>{@provision_result.database_name}</code></div>
          <div><span>Username</span><code>{connect_username(@provision_result)}</code></div>
          <div><span>Password</span><code>{@provision_result.generated_password}</code></div>
        </div>
        <p class="field-help">Use the transaction port for your app. Use the session port for tools that need a stable PostgreSQL session.</p>
        <.link class="text-button" navigate={~p"/admin/tenants/#{@provision_result.tenant_external_id}/edit"}>Edit connection settings</.link>
      </details>
    </section>

    <section :if={!@provisioning_available} class="form-section provision-disabled">
      <div class="form-section-heading">
        <span class="step-marker step-marker-warning"><span class="hero-exclamation-triangle-mini"></span></span>
        <div><h2>Database creation is unavailable</h2><p>The server needs a PostgreSQL account with permission to create databases and owner accounts. Ask the server administrator to finish this setup.</p></div>
      </div>
      <.link class="secondary-button" navigate={~p"/admin/tenants/new"}>Connect an existing database</.link>
    </section>

    <form :if={@provisioning_available and @provision_result == nil} id="provision-form" class="tenant-form" phx-change="validate" phx-submit="save">
      <section class="form-section form-section-primary">
        <div class="form-section-heading"><span class="step-marker"><span class="hero-circle-stack-mini"></span></span><div><h2>Name your database</h2><p>The PostgreSQL server is already configured. No host, port or connection URL is needed.</p></div></div>
        <div class="form-grid">
          <.input label="Database name" name="provision[database_name]" value={@params["database_name"]} placeholder="my_app" required maxlength="63" errors={error(@errors, "database_name")} />
          <.input :if={length(@servers) > 1} type="select" label="Server" name="provision[server]" value={@params["server"] || "0"} options={@servers} errors={error(@errors, "server")} />
        </div>
        <p class="field-help">Use lowercase letters, numbers and underscores; start with a letter or underscore.</p>
        <div class="creation-preview"><strong>Created for you</strong><ul>
          <li>Database <code>{name(@params)}</code></li>
          <li>Owner account <code>{owner_name(@params)}</code> with a secure generated password</li>
          <li>Supavisor connection <code>{connection_name(@params)}</code>, ready to use in your app</li>
        </ul></div>
      </section>

      <details id="provision-advanced" class="form-section" open={advanced_errors?(@errors)}>
        <summary class="advanced-summary"><span class="hero-adjustments-horizontal-mini"></span>Advanced settings (optional)</summary>
        <p class="advanced-help">The defaults work for a new database. Change these only when your app needs different names, TLS or pooling limits.</p>
        <div class="form-grid">
          <.input label="Connection name" name="provision[external_id]" value={@params["external_id"]} placeholder={name(@params)} errors={error(@errors, "external_id")} />
          <.input label="Database owner username" name="provision[role_name]" value={@params["role_name"]} placeholder={name(@params)} maxlength="63" errors={error(@errors, "role_name")} />
        </div>
        <p class="field-help">Leave names empty to use the database name. The owner account and its password are created automatically.</p>
        <div class="form-grid">
          <.input type="checkbox" label="Use TLS from Supavisor to PostgreSQL" name="provision[upstream_ssl]" checked={@params["upstream_ssl"] == "true"} />
          <.input type="select" label="Verify PostgreSQL certificate" name="provision[upstream_verify]" value={@params["upstream_verify"]} options={[{"None", "none"}, {"Peer", "peer"}]} />
          <.input type="checkbox" label="Require clients to use TLS" name="provision[enforce_ssl]" checked={@params["enforce_ssl"] == "true"} />
          <.input :if={@params["upstream_ssl"] == "true" and @params["upstream_verify"] == "peer"} type="textarea" label="PostgreSQL CA certificate" name="provision[upstream_tls_ca]" value={@params["upstream_tls_ca"]} rows="8" errors={error(@errors, "upstream_tls_ca")} />
          <.input type="select" label="IP version" name="provision[ip_version]" value={@params["ip_version"]} options={[{"Auto", "auto"}, {"IPv4", "v4"}, {"IPv6", "v6"}]} />
          <.input label="Pool size" type="number" name="provision[default_pool_size]" value={@params["default_pool_size"]} errors={error(@errors, "default_pool_size")} />
          <.input label="Maximum clients" type="number" name="provision[default_max_clients]" value={@params["default_max_clients"]} errors={error(@errors, "default_max_clients")} />
          <.input label="Client idle timeout" type="number" name="provision[client_idle_timeout]" value={@params["client_idle_timeout"]} errors={error(@errors, "client_idle_timeout")} />
          <.input label="Heartbeat interval" type="number" name="provision[client_heartbeat_interval]" value={@params["client_heartbeat_interval"]} errors={error(@errors, "client_heartbeat_interval")} />
          <.input type="textarea" label="Allowed client IP ranges" name="provision[allow_list]" value={@params["allow_list"]} rows="4" />
        </div>
      </details>

      <div class="form-actions">
        <button type="submit" class="primary-button" phx-disable-with="Creating database…"><span class="hero-circle-stack-mini"></span>Create database</button>
        <.link class="secondary-button" navigate={~p"/admin/postgres"}>Cancel</.link>
      </div>
    </form>
    """
  end
end
