defmodule SupavisorWeb.Admin.ProvisionLive do
  use SupavisorWeb, :live_view

  alias SupavisorWeb.AdminProvisioning
  alias SupavisorWeb.AdminProvisioningForm

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Provision database",
       params: AdminProvisioningForm.new_params(),
       errors: %{},
       provisioning_available: AdminProvisioning.available?(),
       provision_result: nil
     )}
  end

  @impl true
  def handle_event("validate", %{"provision" => params}, socket) do
    {:noreply, assign(socket, params: AdminProvisioningForm.normalize_params(params))}
  end

  def handle_event("save", %{"provision" => params}, socket) do
    with true <- AdminProvisioning.available?(),
         {:ok, attrs} <- AdminProvisioningForm.to_attrs(params),
         {:ok, result} <- AdminProvisioning.provision(attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Provisioned #{result.database_name}. Save the password now.")
       |> assign(provision_result: result)}
    else
      false ->
        {:noreply,
         assign(socket,
           errors: AdminProvisioningForm.errors_from_reason(:not_configured),
           provisioning_available: AdminProvisioning.available?()
         )}

      {:error, errors, params} when is_map(errors) ->
        {:noreply, assign(socket, params: params, errors: errors)}

      {:error, reason} ->
        {:noreply, assign(socket, errors: AdminProvisioningForm.errors_from_reason(reason))}
    end
  end

  defp error(errors, field), do: Map.get(errors, field, [])

  defp ssl_warning(params) do
    cond do
      params["upstream_ssl"] != "true" ->
        "Upstream SSL is off. Supavisor will connect to Postgres without TLS."

      params["upstream_verify"] != "peer" ->
        "Upstream TLS is enabled without peer verification."

      true ->
        nil
    end
  end

  defp filled?(value), do: value not in [nil, ""]

  defp transaction_port do
    Application.get_env(:supavisor, :proxy_port_transaction, 6543)
  end

  defp session_port do
    Application.get_env(:supavisor, :proxy_port_session, 5432)
  end

  defp connect_username(%{role_name: role_name, tenant_external_id: external_id}) do
    "#{role_name}.#{external_id}"
  end

  defp connect_uri(%{database_name: database_name, generated_password: password} = result) do
    username = connect_username(result)

    "postgresql://#{username}:#{URI.encode_www_form(password)}@localhost:#{transaction_port()}/#{database_name}"
  end

  defp ecto_uri(%{database_name: database_name, generated_password: password} = result) do
    username = connect_username(result)

    "ecto://#{username}:#{URI.encode_www_form(password)}@localhost:#{transaction_port()}/#{database_name}"
  end

  defp ecto_config_result(result) do
    """
    config :vext, MyApp.Repo,
      url: "#{ecto_uri(result)}",
      stacktrace: true,
      show_sensitive_data_on_connection_error: true,
      pool_size: 10
    """
  end

  defp provision_connection_name(params), do: fallback(params["external_id"], "my_app")
  defp provision_database(params), do: fallback(params["database_name"], "my_app_db")
  defp provision_user(params), do: fallback(params["role_name"], "my_app_user")

  defp provision_client_username(params) do
    "#{provision_user(params)}.#{provision_connection_name(params)}"
  end

  defp provision_sample_uri(params) do
    "postgresql://#{provision_client_username(params)}:GENERATED_PASSWORD@localhost:#{transaction_port()}/#{provision_database(params)}"
  end

  defp provision_ecto_uri(params) do
    "ecto://#{provision_client_username(params)}:GENERATED_PASSWORD@localhost:#{transaction_port()}/#{provision_database(params)}"
  end

  defp provision_ecto_config(params) do
    """
    config :vext, MyApp.Repo,
      url: "#{provision_ecto_uri(params)}",
      stacktrace: true,
      show_sensitive_data_on_connection_error: true,
      pool_size: 10
    """
  end

  defp fallback(value, fallback) when value in [nil, ""], do: fallback
  defp fallback(value, _fallback), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page-title-row">
      <div>
        <p class="eyebrow">Provisioning</p>
        <h1><%= @page_title %></h1>
        <p class="page-subtitle">
          Create a new Postgres database and database user, then create the Supavisor connection for it.
        </p>
      </div>
      <.link class="secondary-button" navigate={~p"/admin"}>
        <span class="hero-arrow-left-mini"></span>
        Back
      </.link>
    </div>

    <.notice :for={message <- error(@errors, :base)} kind="error"><%= message %></.notice>

    <section :if={@provision_result} class="form-section success-panel">
      <div class="form-section-heading">
        <span class="step-marker step-marker-success">
          <span class="hero-check-mini"></span>
        </span>
        <div>
          <div class="heading-with-badge">
            <h2>Database is ready</h2>
            <.badge variant="warning" icon="hero-exclamation-triangle-mini">
              Password shown once
            </.badge>
          </div>
          <p>
            Supavisor stores this password encrypted. The dashboard will not show it again.
          </p>
        </div>
      </div>

      <div class="connection-recipe">
        <div>
          <span>Connect to Supavisor host</span>
          <code>localhost</code>
        </div>
        <div>
          <span>Transaction pool port</span>
          <code><%= transaction_port() %></code>
        </div>
        <div>
          <span>Session pool port</span>
          <code><%= session_port() %></code>
        </div>
        <div>
          <span>Database</span>
          <code><%= @provision_result.database_name %></code>
        </div>
        <div>
          <span>Username</span>
          <code><%= connect_username(@provision_result) %></code>
        </div>
        <div>
          <span>Password</span>
          <code><%= @provision_result.generated_password %></code>
        </div>
      </div>

      <label class="field">
        <span>Connection URL</span>
        <input readonly value={connect_uri(@provision_result)} />
      </label>

      <div class="code-example-panel">
        <span>Elixir / Ecto example</span>
        <pre><code><%= ecto_config_result(@provision_result) %></code></pre>
      </div>

      <div class="form-actions">
        <.link class="primary-button" navigate={~p"/admin"}>Back to tenants</.link>
        <.link class="secondary-button" navigate={~p"/admin/tenants/#{@provision_result.tenant_external_id}/edit"}>
          Edit connection
        </.link>
      </div>
    </section>

    <section :if={!@provisioning_available} class="form-section provision-disabled">
      <div class="form-section-heading">
        <span class="step-marker step-marker-warning">
          <span class="hero-exclamation-triangle-mini"></span>
        </span>
        <div>
          <h2>Provisioning disabled</h2>
          <p>
            Enable <code>SupavisorWeb.AdminProvisioning</code> in config with provisioner credentials and allowed targets.
          </p>
        </div>
      </div>
    </section>

    <.stepper
      :if={@provisioning_available and @provision_result == nil}
      current={1}
      steps={[
        "Connection",
        "Server",
        "Auth",
        "SSL",
        "Review"
      ]}
    />

    <form
      :if={@provisioning_available}
      hidden={@provision_result != nil}
      id="provision-form"
      class="tenant-form"
      phx-change="validate"
      phx-submit="save"
    >
      <section class="form-section form-section-primary">
        <div class="form-section-heading">
          <span class="step-marker">1</span>
          <div>
            <h2>Connection and database</h2>
            <p>The connection name is used by Supavisor. The database and username are created in Postgres.</p>
          </div>
        </div>

        <div class="form-grid">
          <.input
            label="Supavisor connection name"
            name="provision[external_id]"
            value={@params["external_id"]}
            placeholder="my_app"
            required
            errors={error(@errors, "external_id")}
          />
          <.input
            label="Database name to create"
            name="provision[database_name]"
            value={@params["database_name"]}
            placeholder="my_app_db"
            required
            errors={error(@errors, "database_name")}
          />
          <.input
            label="Database username to create"
            name="provision[role_name]"
            value={@params["role_name"]}
            placeholder="my_app_user"
            required
            errors={error(@errors, "role_name")}
          />
        </div>

        <div class="creation-preview">
          <strong>What this will create</strong>
          <ul>
            <li>
              Supavisor connection:
              <code><%= if filled?(@params["external_id"]), do: @params["external_id"], else: "my_app" %></code>
            </li>
            <li>
              Postgres database:
              <code><%= if filled?(@params["database_name"]), do: @params["database_name"], else: "my_app_db" %></code>
            </li>
            <li>
              Postgres username:
              <code><%= if filled?(@params["role_name"]), do: @params["role_name"], else: "my_app_user" %></code>
            </li>
            <li>
              Generated password:
              <code>shown once after create</code>
            </li>
          </ul>
        </div>
      </section>

      <section class="form-section">
        <div class="form-section-heading">
          <span class="step-marker">2</span>
          <div>
            <h2>Postgres server</h2>
            <p>Choose where the new database will be created. Only servers allowed in config can be used.</p>
          </div>
        </div>

        <div class="form-grid">
          <.input
            label="Postgres host"
            name="provision[target_host]"
            value={@params["target_host"]}
            required
            errors={error(@errors, "target_host")}
          />
          <.input
            label="Postgres port"
            type="number"
            name="provision[target_port]"
            value={@params["target_port"]}
            required
            errors={error(@errors, "target_port")}
          />
        </div>
      </section>

      <section class="form-section">
        <div class="form-section-heading">
          <span class="step-marker">3</span>
          <div>
            <h2>Authentication</h2>
            <p>A strong database password is generated automatically. It is stored encrypted and shown once after create.</p>
          </div>
        </div>

        <div class="auth-mode-group">
          <label class={"auth-mode-card #{if @params["auth_mode"] == "stored_users", do: "is-selected"}"}>
            <input
              type="radio"
              name="provision[auth_mode]"
              value="stored_users"
              checked={@params["auth_mode"] == "stored_users"}
            />
            <span>
              <strong>Stored database user</strong>
              <small>Use the created Postgres username and generated password as the client login.</small>
            </span>
          </label>

          <label class={"auth-mode-card #{if @params["auth_mode"] == "auth_query", do: "is-selected"}"}>
            <input
              type="radio"
              name="provision[auth_mode]"
              value="auth_query"
              checked={@params["auth_mode"] == "auth_query"}
            />
            <span>
              <strong>Auth query</strong>
              <small>Use the created Postgres username as the manager that checks other users in Postgres.</small>
            </span>
          </label>
        </div>

        <div :if={@params["auth_mode"] == "auth_query"} class="form-grid form-grid-wide">
          <.input
            type="textarea"
            label="Auth query"
            name="provision[auth_query]"
            value={@params["auth_query"]}
            rows="3"
            errors={error(@errors, "auth_query")}
          />
          <p class="form-note">
            The provisioned manager role must have permission to run this query.
          </p>
        </div>
      </section>

      <section class="form-section">
        <div class="form-section-heading">
          <span class="step-marker">4</span>
          <div>
            <h2>SSL</h2>
            <p>Choose how Supavisor connects upstream and whether clients must use TLS.</p>
          </div>
        </div>

        <p :if={ssl_warning(@params)} class="security-warning"><%= ssl_warning(@params) %></p>

        <div class="form-grid">
          <.input
            type="checkbox"
            label="Use TLS from Supavisor to Postgres"
            name="provision[upstream_ssl]"
            checked={@params["upstream_ssl"] == "true"}
          />
          <.input
            type="select"
            label="Verify Postgres certificate"
            name="provision[upstream_verify]"
            value={@params["upstream_verify"]}
            options={[{"None", "none"}, {"Peer", "peer"}]}
          />
          <.input
            type="checkbox"
            label="Require clients to use SSL"
            name="provision[enforce_ssl]"
            checked={@params["enforce_ssl"] == "true"}
          />
        </div>

        <div
          :if={@params["upstream_ssl"] == "true" and @params["upstream_verify"] == "peer"}
          class="form-grid form-grid-wide"
        >
          <.input
            type="textarea"
            label="Upstream CA certificate"
            name="provision[upstream_tls_ca]"
            value={@params["upstream_tls_ca"]}
            rows="8"
            errors={error(@errors, "upstream_tls_ca")}
          />
        </div>
      </section>

      <section class="form-section connection-help-panel">
        <div class="form-section-heading">
          <span class="step-marker">5</span>
          <div>
            <h2>How you will connect</h2>
            <p>
              After creation, your app connects to Supavisor. Use
              <code>database_username.connection_name</code> as the username.
            </p>
          </div>
        </div>

        <div class="connection-recipe">
          <div>
            <span>Supavisor host</span>
            <code>localhost</code>
          </div>
          <div>
            <span>Transaction pool port</span>
            <code><%= transaction_port() %></code>
          </div>
          <div>
            <span>Session pool port</span>
            <code><%= session_port() %></code>
          </div>
          <div>
            <span>Database</span>
            <code><%= provision_database(@params) %></code>
          </div>
          <div>
            <span>Username</span>
            <code><%= provision_client_username(@params) %></code>
          </div>
          <div>
            <span>Password</span>
            <code>generated after create</code>
          </div>
        </div>

        <label class="field">
          <span>Example connection URL</span>
          <input readonly value={provision_sample_uri(@params)} />
        </label>

        <div class="code-example-panel">
          <span>Elixir / Ecto example</span>
          <pre><code><%= provision_ecto_config(@params) %></code></pre>
        </div>
      </section>

      <details class="form-section">
        <summary class="advanced-summary">
          <span class="hero-adjustments-horizontal-mini"></span>
          Advanced pooling and network settings
        </summary>
        <p class="advanced-help">
          Most setups can leave these alone. SSL controls how Supavisor talks to Postgres and whether clients must use TLS.
        </p>
        <div class="form-grid">
          <.input
            type="select"
            label="IP version"
            name="provision[ip_version]"
            value={@params["ip_version"]}
            options={[{"Auto", "auto"}, {"IPv4", "v4"}, {"IPv6", "v6"}]}
          />
          <.input
            label="Default pool size"
            type="number"
            name="provision[default_pool_size]"
            value={@params["default_pool_size"]}
            errors={error(@errors, "default_pool_size")}
          />
          <.input
            label="Default max clients"
            type="number"
            name="provision[default_max_clients]"
            value={@params["default_max_clients"]}
            errors={error(@errors, "default_max_clients")}
          />
          <.input
            label="Client idle timeout"
            type="number"
            name="provision[client_idle_timeout]"
            value={@params["client_idle_timeout"]}
            errors={error(@errors, "client_idle_timeout")}
          />
          <.input
            label="Heartbeat interval"
            type="number"
            name="provision[client_heartbeat_interval]"
            value={@params["client_heartbeat_interval"]}
            errors={error(@errors, "client_heartbeat_interval")}
          />
          <.input
            type="textarea"
            label="Allowed client IP CIDRs"
            name="provision[allow_list]"
            value={@params["allow_list"]}
            rows="4"
          />
        </div>
      </details>

      <div class="form-actions">
        <button type="submit" class="primary-button">
          <span class="hero-circle-stack-mini"></span>
          Provision database
        </button>
        <.link class="secondary-button" navigate={~p"/admin"}>Cancel</.link>
      </div>
    </form>
    """
  end
end
