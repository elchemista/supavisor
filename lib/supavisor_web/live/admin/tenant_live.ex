defmodule SupavisorWeb.Admin.TenantLive do
  use SupavisorWeb, :live_view

  alias SupavisorWeb.AdminConnection

  alias Supavisor.Tenants
  alias SupavisorWeb.{AdminTenantForm, AdminPostgres, AdminProvisioning}

  @impl true
  def mount(params, _session, socket) do
    socket =
      case socket.assigns.live_action do
        :new ->
          assign(socket,
            page_title: "New tenant",
            tenant: nil,
            params:
              Map.merge(
                AdminTenantForm.new_params(),
                Map.take(params, ["db_host", "db_port", "db_database"])
              ),
            errors: %{}
          )

        :edit ->
          tenant = Tenants.get_tenant_by_external_id(params["external_id"])

          if tenant do
            assign(socket,
              page_title: "Edit #{tenant.external_id}",
              tenant: tenant,
              params: AdminTenantForm.from_tenant(tenant),
              errors: %{}
            )
          else
            socket
            |> put_flash(:error, "Tenant not found.")
            |> redirect(to: ~p"/admin")
          end
      end

    targets =
      Enum.map(AdminProvisioning.allowed_targets(), fn
        {host, port} -> {host, port}
        %{host: host, port: port} -> {host, port}
      end)

    socket =
      assign(socket,
        targets: targets,
        catalog: nil,
        catalog_loading: false,
        catalog_error: nil,
        catalog_task: nil,
        suggested_name: nil,
        suggested_user: nil
      )

    if socket.assigns[:params] do
      index =
        Enum.find_index(targets, fn {host, port} ->
          host == socket.assigns.params["db_host"] and
            to_string(port) == socket.assigns.params["db_port"]
        end)

      selected =
        cond do
          index != nil ->
            to_string(index)

          socket.assigns.live_action == :new and not Map.has_key?(params, "db_host") and
              targets != [] ->
            "0"

          true ->
            "manual"
        end

      socket = assign(socket, selected_server: selected)

      socket =
        if socket.assigns.live_action == :new,
          do: update(socket, :params, &Map.put(&1, "db_database", params["db_database"] || "")),
          else: socket

      {:ok, socket |> set_server_address() |> load_catalog()}
    else
      {:ok, assign(socket, selected_server: "manual")}
    end
  end

  @impl true
  def handle_event("add-user", _params, socket) do
    {:noreply, update(socket, :params, &AdminTenantForm.add_user/1)}
  end

  def handle_event("remove-user", %{"index" => index}, socket) do
    {:noreply, update(socket, :params, &AdminTenantForm.remove_user(&1, index))}
  end

  def handle_event("validate", %{"tenant" => params} = event, socket) do
    previous = socket.assigns.params
    params = Map.put_new(params, "db_database", previous["db_database"])

    params =
      if socket.assigns.live_action == :edit do
        Map.put(params, "external_id", socket.assigns.tenant.external_id)
      else
        params
      end

    socket = assign(socket, params: AdminTenantForm.normalize_params(params))

    socket =
      case event["_target"] do
        ["connection_server"] -> select_server(socket, event["connection_server"])
        ["tenant", "db_database"] -> suggest_database(socket)
        ["tenant", "users", index, "db_user"] -> sync_user_alias(socket, previous, index)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("refresh-catalog", _params, socket), do: {:noreply, load_catalog(socket, true)}

  def handle_event("recover", %{"tenant" => _} = event, socket) do
    {:noreply, socket} = handle_event("validate", Map.put(event, "_target", []), socket)
    {:noreply, select_server(socket, event["connection_server"] || "manual", false)}
  end

  def handle_event("save", %{"tenant" => params}, socket) do
    params =
      if socket.assigns.live_action == :edit do
        Map.put(params, "external_id", socket.assigns.tenant.external_id)
      else
        params
      end

    with {:ok, params} <- selected_database_params(params, socket),
         {:ok, attrs} <- AdminTenantForm.to_attrs(params, socket.assigns.tenant) do
      save_tenant(socket, attrs)
    else
      {:error, errors, params} ->
        {:noreply, assign(socket, params: params, errors: errors)}
    end
  end

  @impl true
  def handle_async({:tenant_catalog, _} = task, result, socket) do
    if task == socket.assigns.catalog_task do
      socket =
        case result do
          {:ok, {:ok, catalog}} ->
            socket
            |> assign(catalog: catalog, catalog_loading: false, catalog_error: nil, catalog_task: nil)
            |> suggest_database()

          _ ->
            assign(socket,
              catalog_loading: false,
              catalog_task: nil,
              catalog_error:
                if(socket.assigns.catalog,
                  do: "Could not refresh the list. Your previous selection is still available. Try again.",
                  else: "Could not load databases. Try again, or select Enter connection manually."
                )
            )
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp server(socket) do
    case Integer.parse(socket.assigns.selected_server) do
      {index, ""} when index >= 0 -> Enum.at(socket.assigns.targets, index)
      _ -> nil
    end
  end

  defp set_server_address(socket) do
    case server(socket) do
      {host, port} ->
        update(
          socket,
          :params,
          &Map.merge(&1, %{"db_host" => host, "db_port" => to_string(port)})
        )

      nil ->
        socket
    end
  end

  defp select_server(socket, selected, reset_database \\ true) do
    valid =
      selected == "manual" or
        selected in Enum.map(Enum.with_index(socket.assigns.targets), fn {_, i} ->
          to_string(i)
        end)

    if valid and selected != socket.assigns.selected_server do
      socket = assign(socket, selected_server: selected, catalog: nil, catalog_error: nil)

      socket =
        if selected == "manual" or not reset_database,
          do: socket,
          else: update(socket, :params, &Map.put(&1, "db_database", ""))

      socket |> set_server_address() |> load_catalog()
    else
      socket
    end
  end

  defp load_catalog(socket, refresh \\ false) do
    socket =
      if socket.assigns.catalog_task,
        do: cancel_async(socket, socket.assigns.catalog_task),
        else: socket

    case {server(socket), connected?(socket)} do
      {{host, port}, true} ->
        task = {:tenant_catalog, make_ref()}

        socket
        |> assign(catalog_task: task, catalog_loading: true, catalog_error: nil)
        |> start_async(task, fn -> AdminPostgres.connection_catalog(host, port, refresh) end)

      _ ->
        assign(socket, catalog_task: nil, catalog_loading: false)
    end
  end

  defp suggest_database(%{assigns: %{catalog: nil}} = socket), do: socket
  defp suggest_database(%{assigns: %{live_action: :edit}} = socket), do: socket

  defp suggest_database(socket) do
    database =
      Enum.find(
        socket.assigns.catalog.databases,
        &(&1.name == socket.assigns.params["db_database"])
      )

    if database do
      suggested_name = database.name |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/u, "_")
      name = socket.assigns.params["external_id"]

      params =
        if name in [nil, "", socket.assigns.suggested_name],
          do: Map.put(socket.assigns.params, "external_id", suggested_name),
          else: socket.assigns.params

      {index, user} = List.first(sorted_users(params)) || {nil, nil}
      owner = if database.owner in socket.assigns.catalog.roles, do: database.owner, else: ""

      params =
        if user && user["db_user"] in [nil, "", socket.assigns.suggested_user] do
          password = if user["db_user"] == owner, do: user["db_password"], else: ""

          alias_name =
            if user["db_user_alias"] in [nil, "", user["db_user"]],
              do: owner,
              else: user["db_user_alias"]

          put_in(
            params,
            ["users", index],
            Map.merge(user, %{
              "db_user" => owner,
              "db_user_alias" => alias_name,
              "db_password" => password
            })
          )
        else
          params
        end

      assign(socket, params: params, suggested_name: suggested_name, suggested_user: owner)
    else
      socket
    end
  end

  defp sync_user_alias(socket, previous, index) do
    current = get_in(socket.assigns.params, ["users", index])
    old = get_in(previous, ["users", index]) || %{}

    if current && current["db_user"] != old["db_user"] do
      user = Map.put(current, "db_password", "")

      user =
        if current["db_user_alias"] in [nil, "", old["db_user"]],
          do: Map.put(user, "db_user_alias", current["db_user"]),
          else: user

      update(socket, :params, &put_in(&1, ["users", index], user))
    else
      socket
    end
  end

  defp selected_database_params(params, %{assigns: %{selected_server: "manual"}}),
    do: {:ok, params}

  defp selected_database_params(params, socket) do
    catalog = socket.assigns.catalog

    cond do
      socket.assigns.catalog_loading or is_nil(catalog) ->
        {:error, %{base: ["Wait for the database list, or enter the connection manually."]},
         params}

      not Enum.any?(catalog.databases, &(&1.name == params["db_database"])) ->
        {:error, %{"db_database" => ["Select an existing database from the list."]}, params}

      true ->
        {host, port} = server(socket)
        {:ok, Map.merge(params, %{"db_host" => host, "db_port" => to_string(port)})}
    end
  end

  defp database_options(nil, current), do: keep_selected_option([], current, "database")

  defp database_options(catalog, current) do
    options = Enum.map(catalog.databases, &{"#{&1.name} · #{&1.owner}", &1.name})
    keep_selected_option(options, current, "database")
  end

  defp role_options(catalog, current) do
    keep_selected_option(Enum.map(catalog.roles, &{&1, &1}), current, "role")
  end

  defp keep_selected_option(options, current, kind) do
    options =
      if current not in [nil, ""] and
           not Enum.any?(options, fn {_, value} -> value == current end),
         do: [{"#{current} (current #{kind})", current} | options],
         else: options

    [{"Select #{kind}…", ""} | options]
  end

  defp save_tenant(%{assigns: %{live_action: :new}} = socket, attrs) do
    case Tenants.create_tenant(attrs) do
      {:ok, tenant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tenant #{tenant.external_id} created.")
         |> push_navigate(to: ~p"/admin")}

      {:error, changeset} ->
        {:noreply, assign(socket, errors: AdminTenantForm.errors_from_changeset(changeset))}
    end
  end

  defp save_tenant(%{assigns: %{tenant: tenant}} = socket, attrs) do
    case Tenants.update_tenant(tenant, attrs) do
      {:ok, tenant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tenant #{tenant.external_id} updated.")
         |> push_navigate(to: ~p"/admin")}

      {:error, changeset} ->
        {:noreply, assign(socket, errors: AdminTenantForm.errors_from_changeset(changeset))}
    end
  end

  defp error(errors, field), do: Map.get(errors, field, [])

  defp sorted_users(params) do
    params
    |> Map.get("users", %{})
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
  end

  defp transaction_port do
    Application.get_env(:supavisor, :proxy_port_transaction, 6543)
  end

  defp session_port do
    Application.get_env(:supavisor, :proxy_port_session, 5432)
  end

  defp private_pool? do
    Application.get_env(:supavisor, :proxy_bind_address) in [
      {127, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 1}
    ]
  end

  defp connection_name(params), do: fallback(params["external_id"], "my_app")
  defp upstream_database(params), do: fallback(params["db_database"], "my_app_db")

  defp first_client_user(params) do
    params
    |> Map.get("users", %{})
    |> Enum.sort_by(fn {index, _user} -> String.to_integer(to_string(index)) end)
    |> Enum.map(fn {_index, user} -> fallback(user["db_user_alias"], user["db_user"]) end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> List.first()
    |> fallback("my_app_user")
  end

  defp client_username(params), do: "#{first_client_user(params)}.#{connection_name(params)}"

  defp sample_connection_uri(params) do
    AdminConnection.uri(
      "postgresql",
      client_username(params),
      "PASSWORD",
      upstream_database(params),
      transaction_port()
    )
  end

  defp sample_ecto_url(params) do
    AdminConnection.uri(
      "ecto",
      client_username(params),
      "PASSWORD",
      upstream_database(params),
      transaction_port()
    )
  end

  defp ecto_config_example(params) do
    """
    config :my_app, MyApp.Repo,
      url: "#{sample_ecto_url(params)}",
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
        <p class="eyebrow">Connection</p>
        <h1><%= @page_title %></h1>
        <p class="page-subtitle">
          <%= if @tenant do %>
            Update this connection profile. Leave an existing user's password blank to keep it.
          <% else %>
            Select a database, choose its login role, and add the password to create a connection profile.
          <% end %>
        </p>
      </div>
      <.link class="secondary-button" navigate={~p"/admin"}>
        <span class="hero-arrow-left-mini"></span>
        Back
      </.link>
    </div>

    <.notice :for={message <- error(@errors, :base)} kind="error"><%= message %></.notice>

    <.stepper
      current={1}
      steps={[
        "Database",
        "Connection",
        "Auth",
        "Clients",
        "Users"
      ]}
    />

    <form id="tenant-form" class="tenant-form" phx-change="validate" phx-auto-recover="recover" phx-submit="save">
      <section class="form-section form-section-primary">
        <div class="form-section-heading">
          <span class="step-marker">1</span>
          <div>
            <h2>Choose an existing database</h2>
            <p>
              <%= if @tenant do %>
                Review the server and database. Refreshing the list keeps your current settings.
              <% else %>
                Select your server and database. Connection details and the owner role are filled in for you.
              <% end %>
            </p>
          </div>
        </div>

        <div class="form-grid">
          <.input
            type="select"
            label="PostgreSQL server"
            name="connection_server"
            value={@selected_server}
            options={Enum.map(Enum.with_index(@targets), fn {{host, port}, index} -> {"#{host}:#{port}", to_string(index)} end) ++ [{"Enter connection manually", "manual"}]}
          />
          <.input
            :if={@selected_server != "manual"}
            type="select"
            label="Database"
            name="tenant[db_database]"
            value={@params["db_database"]}
            options={database_options(@catalog, @params["db_database"])}
            disabled={@catalog_loading or is_nil(@catalog)}
            required
            errors={error(@errors, "db_database")}
          />
        </div>
        <div :if={@selected_server != "manual"} class="database-picker-status">
          <span role="status" aria-live="polite">
            <%= cond do %>
              <% @catalog_loading -> %>Loading databases and login roles…
              <% @catalog -> %>{length(@catalog.databases)} databases · {length(@catalog.roles)} login roles
              <% true -> %>Database list unavailable
            <% end %>
          </span>
          <button
            id="refresh-database-catalog"
            type="button"
            class="secondary-button database-refresh-button"
            phx-click="refresh-catalog"
            disabled={@catalog_loading}
            aria-busy={to_string(@catalog_loading)}
          >
            <span class={["hero-arrow-path", @catalog_loading && "is-spinning"]} aria-hidden="true"></span>
            <span>{cond do
              @catalog_loading -> "Refreshing…"
              @catalog_error -> "Try again"
              true -> "Refresh list"
            end}</span>
          </button>
        </div>
        <p :if={@catalog_error} class="notice notice-error" role="alert">{@catalog_error}</p>
        <div class="form-grid">
          <.input
            label="Postgres host"
            name="tenant[db_host]"
            value={@params["db_host"]}
            placeholder="localhost"
            readonly={@selected_server != "manual"}
            required
            errors={error(@errors, "db_host")}
          />
          <.input
            label="Postgres port"
            name="tenant[db_port]"
            type="number"
            value={@params["db_port"]}
            readonly={@selected_server != "manual"}
            required
            errors={error(@errors, "db_port")}
          />
          <.input
            :if={@selected_server == "manual"}
            label="Existing database name"
            name="tenant[db_database]"
            value={@params["db_database"]}
            placeholder="my_app_db"
            required
            errors={error(@errors, "db_database")}
          />
        </div>
      </section>

      <section class="form-section">
        <div class="form-section-heading">
          <span class="step-marker">2</span>
          <div>
            <h2>Supavisor connection name</h2>
            <p>Suggested from the database name. You can change it before saving.</p>
          </div>
        </div>

        <div class="form-grid form-grid-compact">
          <.input
            label="Connection name"
            name="tenant[external_id]"
            value={@params["external_id"]}
            placeholder="my_app"
            readonly={@live_action == :edit}
            required
            errors={error(@errors, "external_id")}
          />
        </div>
      </section>

      <section class="form-section">
        <div class="form-section-heading">
          <span class="step-marker">3</span>
          <div>
            <h2>Authentication</h2>
            <p>Choose whether Supavisor checks saved users or asks Postgres with an auth query.</p>
          </div>
        </div>

        <div class="auth-mode-group">
          <label class={"auth-mode-card #{if @params["auth_mode"] == "stored_users", do: "is-selected"}"}>
            <input
              type="radio"
              name="tenant[auth_mode]"
              value="stored_users"
              checked={@params["auth_mode"] == "stored_users"}
            />
            <span>
              <strong>Stored users</strong>
              <small>Clients use the users below. Passwords are encrypted in Supavisor.</small>
            </span>
          </label>

          <label class={"auth-mode-card #{if @params["auth_mode"] == "auth_query", do: "is-selected"}"}>
            <input
              type="radio"
              name="tenant[auth_mode]"
              value="auth_query"
              checked={@params["auth_mode"] == "auth_query"}
            />
            <span>
              <strong>Auth query</strong>
              <small>Clients are checked against Postgres. The manager user below runs the query.</small>
            </span>
          </label>
        </div>

        <div :if={@params["auth_mode"] == "auth_query"} class="form-grid form-grid-wide">
          <.input
            type="textarea"
            label="Auth query"
            name="tenant[auth_query]"
            value={@params["auth_query"]}
            rows="3"
            errors={error(@errors, "auth_query")}
          />
        </div>
      </section>

      <section class="form-section connection-help-panel">
        <div class="form-section-heading">
          <span class="step-marker">4</span>
          <div>
            <h2>How clients connect</h2>
            <p>
              Connect to Supavisor, not directly to Postgres. The username is
              <code>database_user.connection_name</code>.
            </p>
          </div>
        </div>

        <p :if={private_pool?()} class="field-help">
          This pool is private on this server. Remote applications need an SSH tunnel or a private network connection.
          Creating a tenant does not change your applications' current database connections.
        </p>

        <div class="connection-recipe">
          <div>
            <span>Supavisor host</span>
            <code><%= AdminConnection.host() %></code>
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
            <code><%= upstream_database(@params) %></code>
          </div>
          <div>
            <span>Username</span>
            <code><%= client_username(@params) %></code>
          </div>
          <div>
            <span>Password</span>
            <code><%= if @live_action == :edit, do: "current saved password", else: "password from user row" %></code>
          </div>
        </div>

        <label class="field">
          <span>Example connection URL</span>
          <input readonly value={sample_connection_uri(@params)} />
        </label>

        <div class="code-example-panel">
          <span>Elixir / Ecto example</span>
          <pre><code><%= ecto_config_example(@params) %></code></pre>
        </div>
      </section>

      <section class="form-section">
        <div class="form-section-heading section-title-row">
          <div class="form-section-heading">
            <span class="step-marker">5</span>
            <div>
              <h2><%= if @params["auth_mode"] == "auth_query", do: "Manager user for auth query", else: "Database users clients may use" %></h2>
              <p :if={@params["auth_mode"] == "stored_users"}>
                Select a login role and enter its password. PostgreSQL does not return existing passwords.
              </p>
              <p :if={@params["auth_mode"] == "auth_query"}>
                This user is used by Supavisor to run the auth query; it is not the only client login.
              </p>
            </div>
          </div>
          <button type="button" class="secondary-button" phx-click="add-user">
            <span class="hero-user-plus-mini"></span>
            Add user
          </button>
        </div>

        <div class="user-list">
          <div :for={{index, user} <- sorted_users(@params)} class="user-row">
            <input type="hidden" name={"tenant[users][#{index}][id]"} value={user["id"]} />
            <div class="user-row-title">
              <strong>User <%= String.to_integer(index) + 1 %></strong>
              <span><%= if user["id"] in [nil, ""], do: "new", else: "existing" %></span>
            </div>
            <.input
              :if={@catalog && @selected_server != "manual"}
              type="select"
              label="PostgreSQL login role"
              name={"tenant[users][#{index}][db_user]"}
              value={user["db_user"]}
              options={role_options(@catalog, user["db_user"])}
            />
            <.input
              :if={is_nil(@catalog) or @selected_server == "manual"}
              label="Real Postgres username"
              name={"tenant[users][#{index}][db_user]"}
              value={user["db_user"]}
              placeholder="my_app_user"
            />
            <.input
              label="Client username before dot"
              name={"tenant[users][#{index}][db_user_alias]"}
              value={user["db_user_alias"]}
              placeholder={user["db_user"] || "my_app_user"}
            />
            <.input
              label="Password for this database user"
              type="password"
              name={"tenant[users][#{index}][db_password]"}
              value={user["db_password"]}
              placeholder={if user["id"] in [nil, ""], do: "", else: "Leave blank to keep current password"}
            />
            <.input
              type="select"
              label="Mode"
              name={"tenant[users][#{index}][mode_type]"}
              value={user["mode_type"]}
              options={[{"Transaction", "transaction"}, {"Session", "session"}]}
            />
            <.input
              label="Pool size"
              type="number"
              name={"tenant[users][#{index}][pool_size]"}
              value={user["pool_size"]}
            />
            <.input
              label="Checkout timeout ms"
              type="number"
              name={"tenant[users][#{index}][pool_checkout_timeout]"}
              value={user["pool_checkout_timeout"]}
            />
            <.input label="Max clients" type="number" name={"tenant[users][#{index}][max_clients]"} value={user["max_clients"]} />
            <.input
              type="checkbox"
              label="Manager"
              name={"tenant[users][#{index}][is_manager]"}
              checked={user["is_manager"] == "true"}
            />
            <button
              :if={map_size(@params["users"]) > 1}
              type="button"
              class="danger-button user-remove-button"
              phx-click="remove-user"
              phx-value-index={index}
            >
              <span class="hero-trash-mini"></span>
              Remove
            </button>
          </div>
        </div>
      </section>

      <details class="form-section" open={map_size(@errors) > 0}>
        <summary class="advanced-summary">
          <span class="hero-adjustments-horizontal-mini"></span>
          Advanced pooling, TLS, and network settings
        </summary>
        <p class="advanced-help">
          Most setups can leave these alone. Use TLS settings when Supavisor or Postgres require encrypted connections.
        </p>
        <div class="form-grid">
          <.input
            type="select"
            label="IP version"
            name="tenant[ip_version]"
            value={@params["ip_version"]}
            options={[{"Auto", "auto"}, {"IPv4", "v4"}, {"IPv6", "v6"}]}
          />
          <.input
            type="checkbox"
            label="Use TLS from Supavisor to Postgres"
            name="tenant[upstream_ssl]"
            checked={@params["upstream_ssl"] == "true"}
          />
          <.input
            type="select"
            label="Verify Postgres certificate"
            name="tenant[upstream_verify]"
            value={@params["upstream_verify"]}
            options={[{"None", "none"}, {"Peer", "peer"}]}
          />
          <.input
            type="checkbox"
            label="Require clients to use SSL"
            name="tenant[enforce_ssl]"
            checked={@params["enforce_ssl"] == "true"}
          />
          <.input label="Default pool size" type="number" name="tenant[default_pool_size]" value={@params["default_pool_size"]} errors={error(@errors, "default_pool_size")} />
          <.input label="Default max clients" type="number" name="tenant[default_max_clients]" value={@params["default_max_clients"]} errors={error(@errors, "default_max_clients")} />
          <.input label="Client idle timeout" type="number" name="tenant[client_idle_timeout]" value={@params["client_idle_timeout"]} errors={error(@errors, "client_idle_timeout")} />
          <.input
            label="Heartbeat interval"
            type="number"
            name="tenant[client_heartbeat_interval]"
            value={@params["client_heartbeat_interval"]}
            errors={error(@errors, "client_heartbeat_interval")}
          />
          <.input label="SNI hostname" name="tenant[sni_hostname]" value={@params["sni_hostname"]} />
          <.input
            label="Availability zone"
            name="tenant[availability_zone]"
            value={@params["availability_zone"]}
          />
          <.input type="checkbox" label="Use JIT" name="tenant[use_jit]" checked={@params["use_jit"] == "true"} />
          <.input label="JIT API URL" name="tenant[jit_api_url]" value={@params["jit_api_url"]} />
          <.input
            type="textarea"
            label="Allowed client IP CIDRs"
            name="tenant[allow_list]"
            value={@params["allow_list"]}
            errors={error(@errors, "allow_list")}
            rows="4"
          />
          <.input
            type="textarea"
            label="Default parameter status JSON"
            name="tenant[default_parameter_status]"
            value={@params["default_parameter_status"]}
            rows="4"
            errors={error(@errors, "default_parameter_status")}
          />
          <.input
            type="textarea"
            label="Feature flags JSON"
            name="tenant[feature_flags]"
            value={@params["feature_flags"]}
            rows="4"
            errors={error(@errors, "feature_flags")}
          />
        </div>
      </details>

      <div class="form-actions">
        <button type="submit" class="primary-button">
          <span class="hero-check-mini"></span>
          Save tenant
        </button>
        <.link class="secondary-button" navigate={~p"/admin"}>Cancel</.link>
      </div>
    </form>
    """
  end
end
