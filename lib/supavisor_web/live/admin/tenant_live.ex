defmodule SupavisorWeb.Admin.TenantLive do
  use SupavisorWeb, :live_view

  alias SupavisorWeb.AdminConnection

  alias Supavisor.Tenants
  alias SupavisorWeb.{AdminTenantForm, AdminPostgres, AdminProvisioning}

  @impl true
  def mount(params, _session, socket) do
    targets =
      Enum.map(AdminProvisioning.allowed_targets(), fn
        {host, port} -> {host, port}
        %{host: host, port: port} -> {host, port}
      end)

    tenant =
      if socket.assigns.live_action == :edit,
        do: Tenants.get_tenant_by_external_id(params["external_id"])

    if socket.assigns.live_action == :edit and is_nil(tenant) do
      {:ok, socket |> put_flash(:error, "Connection not found.") |> redirect(to: ~p"/admin")}
    else
      form =
        if tenant,
          do: AdminTenantForm.from_tenant(tenant),
          else: Map.put(AdminTenantForm.new_params(), "db_database", params["db_database"] || "")

      requested = {params["db_host"], to_string(params["db_port"] || "")}

      index =
        Enum.find_index(targets, fn {host, port} ->
          if tenant,
            do: host == tenant.db_host and port == tenant.db_port,
            else: {host, to_string(port)} == requested
        end)

      selected =
        cond do
          index != nil -> to_string(index)
          tenant -> "existing"
          targets != [] -> "0"
          true -> "unavailable"
        end

      socket =
        assign(socket,
          page_title: if(tenant, do: "Edit connection", else: "Connect existing database"),
          tenant: tenant,
          params: form,
          errors: %{},
          targets: targets,
          selected_server: selected,
          catalog: nil,
          catalog_loading: false,
          catalog_error: nil,
          catalog_task: nil,
          suggested_name: nil,
          suggested_user: nil,
          created: nil,
          show_connection_url: false,
          pooler_host: AdminConnection.host()
        )

      {:ok, socket |> set_server_address() |> load_catalog()}
    end
  end

  @impl true
  def handle_params(_, uri, socket) do
    {:noreply, assign(socket, :pooler_host, AdminConnection.host(URI.parse(uri).host))}
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
    socket = assign(socket, :params, merge_params(previous, params))

    socket =
      case event["_target"] do
        ["connection_server"] -> select_server(socket, event["connection_server"])
        ["tenant", "db_database"] -> suggest_database(socket)
        ["tenant", "users", index, "db_user"] -> sync_user_alias(socket, previous, index)
        _ -> socket
      end

    {:noreply, set_server_address(socket)}
  end

  def handle_event("refresh-catalog", _params, socket), do: {:noreply, load_catalog(socket, true)}

  def handle_event("toggle-connection-url", _, socket) do
    {:noreply, update(socket, :show_connection_url, &(!&1))}
  end

  def handle_event("recover", %{"tenant" => _} = event, socket) do
    {:noreply, socket} = handle_event("validate", Map.put(event, "_target", []), socket)

    {:noreply,
     select_server(socket, event["connection_server"] || socket.assigns.selected_server, false)}
  end

  def handle_event("save", %{"tenant" => params}, socket) do
    socket =
      socket
      |> assign(:params, merge_params(socket.assigns.params, params))
      |> set_server_address()
      |> suggest_database()

    params =
      if socket.assigns.tenant,
        do: Map.put(socket.assigns.params, "external_id", socket.assigns.tenant.external_id),
        else: socket.assigns.params

    with {:ok, params} <- selected_database_params(params, socket),
         {:ok, attrs} <- AdminTenantForm.to_attrs(params, socket.assigns.tenant) do
      save_tenant(socket, attrs)
    else
      {:error, errors, params} -> {:noreply, assign(socket, params: params, errors: errors)}
    end
  end

  defp merge_params(previous, incoming) do
    previous
    |> Map.merge(incoming)
    |> Map.put(
      "users",
      Map.new(Map.get(incoming, "users", previous["users"]), fn {index, user} ->
        {index, Map.merge(get_in(previous, ["users", index]) || %{}, user)}
      end)
    )
    |> AdminTenantForm.normalize_params()
  end

  @impl true
  def handle_async({:tenant_catalog, _} = task, result, socket) do
    if task == socket.assigns.catalog_task do
      socket =
        case result do
          {:ok, {:ok, catalog}} ->
            socket
            |> assign(
              catalog: catalog,
              catalog_loading: false,
              catalog_error: nil,
              catalog_task: nil
            )
            |> suggest_database()

          _ ->
            assign(socket,
              catalog_loading: false,
              catalog_task: nil,
              catalog_error:
                "Could not read the database list. Check the server connection, then try again."
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

  defp set_server_address(%{assigns: %{tenant: tenant}} = socket) when not is_nil(tenant) do
    update(
      socket,
      :params,
      &Map.merge(&1, %{"db_host" => tenant.db_host, "db_port" => to_string(tenant.db_port)})
    )
  end

  defp set_server_address(socket) do
    {host, port} = server(socket) || {"", ""}
    update(socket, :params, &Map.merge(&1, %{"db_host" => host, "db_port" => to_string(port)}))
  end

  defp select_server(socket, selected, reset_database \\ true)

  defp select_server(%{assigns: %{tenant: tenant}} = socket, _selected, _reset)
       when not is_nil(tenant), do: socket

  defp select_server(socket, selected, reset_database) do
    valid =
      selected in Enum.map(Enum.with_index(socket.assigns.targets), fn {_, index} ->
        to_string(index)
      end)

    if valid and selected != socket.assigns.selected_server do
      socket = assign(socket, selected_server: selected, catalog: nil, catalog_error: nil)

      socket =
        if reset_database,
          do: update(socket, :params, &Map.put(&1, "db_database", "")),
          else: socket

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

  defp suggest_database(%{assigns: %{tenant: tenant}} = socket) when not is_nil(tenant),
    do: socket

  defp suggest_database(socket) do
    params =
      case {socket.assigns.params["db_database"], socket.assigns.catalog.databases} do
        {"", [database]} -> Map.put(socket.assigns.params, "db_database", database.name)
        _ -> socket.assigns.params
      end

    database = Enum.find(socket.assigns.catalog.databases, &(&1.name == params["db_database"]))

    if database do
      suggested_name = database.name |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/u, "_")
      name = params["external_id"]

      params =
        if name in [nil, "", socket.assigns.suggested_name],
          do: Map.put(params, "external_id", suggested_name),
          else: params

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
      assign(socket, :params, params)
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

  defp selected_database_params(params, %{assigns: %{tenant: tenant}} = socket)
       when not is_nil(tenant) do
    if params["db_database"] == tenant.db_database do
      {:ok, params}
    else
      validate_database_selection(params, socket)
    end
  end

  defp selected_database_params(params, socket), do: validate_database_selection(params, socket)

  defp validate_database_selection(params, socket) do
    cond do
      socket.assigns.catalog_loading or is_nil(socket.assigns.catalog) ->
        {:error, %{base: ["Wait for the database list to load, then select a database."]}, params}

      is_nil(server(socket)) ->
        {:error,
         %{
           base: [
             "No PostgreSQL server is available. Check this server's database configuration."
           ]
         }, params}

      not Enum.any?(socket.assigns.catalog.databases, &(&1.name == params["db_database"])) ->
        {:error, %{"db_database" => ["Select an existing database from the list."]}, params}

      not Enum.all?(sorted_users(params), fn {_, user} ->
        user["db_user"] in socket.assigns.catalog.roles
      end) ->
        {:error, %{base: ["Choose a login role from the server list."]}, params}

      true ->
        {:ok, params}
    end
  end

  defp database_options(nil, current), do: keep_selected_option([], current, "database")

  defp database_options(catalog, current) do
    options = Enum.map(catalog.databases, &{"#{&1.name} · #{&1.owner}", &1.name})
    keep_selected_option(options, current, "database")
  end

  defp role_options(nil, current), do: keep_selected_option([], current, "role")

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
         |> assign(
           created: connection_result(tenant, attrs, socket.assigns.pooler_host),
           errors: %{}
         )
         |> update(:params, fn params ->
           Map.update!(
             params,
             "users",
             &Map.new(&1, fn {index, user} -> {index, Map.put(user, "db_password", "")} end)
           )
         end)}

      {:error, changeset} ->
        {:noreply, assign(socket, errors: AdminTenantForm.errors_from_changeset(changeset))}
    end
  end

  defp save_tenant(%{assigns: %{tenant: tenant}} = socket, attrs) do
    case Tenants.update_tenant(tenant, attrs) do
      {:ok, tenant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Connection #{tenant.external_id} updated.")
         |> push_navigate(to: ~p"/admin")}

      {:error, changeset} ->
        {:noreply, assign(socket, errors: AdminTenantForm.errors_from_changeset(changeset))}
    end
  end

  defp connection_result(tenant, attrs, hostname) do
    user = List.first(attrs["users"])

    username =
      if user, do: "#{fallback(user["db_user_alias"], user["db_user"])}.#{tenant.external_id}"

    url =
      if tenant.require_user and user do
        port = if user["mode_type"] == "session", do: session_port(), else: transaction_port()

        AdminConnection.uri(
          "postgresql",
          username,
          user["db_password"],
          tenant.db_database,
          port,
          hostname
        )
      end

    %{name: tenant.external_id, database: tenant.db_database, username: username, url: url}
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

  defp sample_connection_uri(params, pooler_host) do
    AdminConnection.uri(
      "postgresql",
      client_username(params),
      "PASSWORD",
      upstream_database(params),
      transaction_port(),
      pooler_host
    )
  end

  defp sample_ecto_url(params, pooler_host) do
    AdminConnection.uri(
      "ecto",
      client_username(params),
      "PASSWORD",
      upstream_database(params),
      transaction_port(),
      pooler_host
    )
  end

  defp ecto_config_example(params, pooler_host) do
    """
    config :my_app, MyApp.Repo,
      url: "#{sample_ecto_url(params, pooler_host)}",
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
        <p class="eyebrow">Database connection</p>
        <h1>{if @created, do: "Database connected", else: @page_title}</h1>
        <p class="page-subtitle">
          <%= if @created do %>
            Your connection is saved and ready to use.
          <% else %>
            <%= if @tenant do %>
              Update the saved connection. Leave the password blank to keep the current one.
            <% else %>
              Choose a database and enter its login password. The server and connection settings are filled in automatically.
            <% end %>
          <% end %>
        </p>
      </div>
      <.link class="secondary-button" navigate={~p"/admin"}><span class="hero-arrow-left-mini"></span>Back</.link>
    </div>

    <.notice :for={message <- error(@errors, :base)} kind="error">{message}</.notice>
    <p :if={!@tenant and is_nil(@created)} class="field-help">Need a new database instead? <.link navigate={~p"/admin/provision"}>Create a database</.link> and its login automatically.</p>

    <section :if={@created} id="tenant-connected" class="form-section form-section-primary">
      <div class="form-section-heading"><span class="step-marker"><span class="hero-check"></span></span><div><h2>{@created.database}</h2><p>Saved as {@created.name}.</p></div></div>
      <div :if={@created.url}>
        <p>Copy this URL into your application's database settings. It includes the password you just entered.</p>
        <label class="field"><span>Connection URL</span><input id="connected-database-url" type={if @show_connection_url, do: "text", else: "password"} value={@created.url} readonly autocomplete="off" /></label>
        <div class="form-actions">
          <button type="button" class="primary-button" data-copy-target="#connected-database-url"><span class="hero-clipboard-document"></span>Copy connection URL</button>
          <button type="button" class="secondary-button" phx-click="toggle-connection-url">{if @show_connection_url, do: "Hide URL", else: "Show URL"}</button>
        </div>
        <p class="field-help">Client username: <code>{@created.username}</code>. Copy the URL now; the saved password is not shown again.</p>
        <p data-copy-feedback role="status" aria-live="polite"></p>
      </div>
      <p :if={is_nil(@created.url)} class="field-help">Your PostgreSQL authentication query is configured. Applications sign in with their own database roles; the manager password is kept private.</p>
      <div class="form-actions"><.link class="secondary-button" navigate={~p"/admin"}>View connections</.link><.link class="secondary-button" navigate={~p"/admin/tenants/new"}>Connect another database</.link></div>
    </section>

    <form :if={is_nil(@created)} id="tenant-form" class="tenant-form" phx-change="validate" phx-auto-recover="recover" phx-submit="save">
      <input type="hidden" name="tenant[db_host]" value={@params["db_host"]} />
      <input type="hidden" name="tenant[db_port]" value={@params["db_port"]} />
      <input :if={!is_nil(@tenant) or length(@targets) <= 1} type="hidden" name="connection_server" value={@selected_server} />
      <section class="form-section form-section-primary">
        <div class="form-section-heading">
          <span class="step-marker"><span class="hero-circle-stack"></span></span>
          <div><h2>Choose your database</h2><p>We read available databases and login roles directly from your server.</p></div>
        </div>
        <div class="form-grid">
          <.input :if={!@tenant and length(@targets) > 1} type="select" label="Server" name="connection_server" value={@selected_server}
            options={Enum.map(Enum.with_index(@targets), fn {{host, _port}, index} -> {"Server #{index + 1} · #{host}", to_string(index)} end)} />
          <.input :if={@selected_server != "existing"} type="select" label="Database" name="tenant[db_database]" value={@params["db_database"]}
            options={database_options(@catalog, @params["db_database"])} disabled={@catalog_loading or is_nil(@catalog)} required errors={error(@errors, "db_database")} />
          <div :if={@selected_server == "existing"} class="field"><span>Database</span><strong>{@params["db_database"]}</strong><input type="hidden" name="tenant[db_database]" value={@params["db_database"]} /></div>
          <.input label="Connection name" name="tenant[external_id]" value={@params["external_id"]} placeholder="Suggested from the database" readonly={@live_action == :edit} required errors={error(@errors, "external_id")} />
        </div>
        <p class="field-help">The connection name identifies this database in Supavisor. The database owner is selected as the login when possible.</p>
        <div :if={@selected_server not in ["existing", "unavailable"]} class="database-picker-status">
          <span role="status" aria-live="polite">{cond do
            @catalog_loading -> "Loading databases…"
            @catalog -> "#{length(@catalog.databases)} databases available"
            true -> "Database list unavailable"
          end}</span>
          <button id="refresh-database-catalog" type="button" class="secondary-button database-refresh-button" phx-click="refresh-catalog" disabled={@catalog_loading} aria-busy={to_string(@catalog_loading)}>
            <span class={["hero-arrow-path", @catalog_loading && "is-spinning"]} aria-hidden="true"></span>{if @catalog_error, do: "Try again", else: "Refresh list"}
          </button>
        </div>
        <p :if={@catalog_error} class="notice notice-error" role="alert">{@catalog_error}</p>
        <p :if={@selected_server == "unavailable"} class="notice notice-error" role="alert">The server's PostgreSQL connection is unavailable. Check its database configuration, then reload this page.</p>
      </section>

      <section class="form-section">
        <div class="form-section-heading"><span class="step-marker"><span class="hero-key"></span></span><div><h2>Database login</h2><p>PostgreSQL keeps passwords private. Enter the existing login password once; Supavisor stores it encrypted.</p></div></div>
        <div :for={{index, user} <- sorted_users(@params)} class="form-grid">
          <input type="hidden" name={"tenant[users][#{index}][id]"} value={user["id"]} />
          <.input :if={@catalog} type="select" label={if @params["auth_mode"] == "auth_query", do: "Manager role", else: "Login role"} name={"tenant[users][#{index}][db_user]"} value={user["db_user"]} options={role_options(@catalog, user["db_user"])} required />
          <.input :if={is_nil(@catalog)} label="Login role" name={"tenant[users][#{index}][db_user]"} value={user["db_user"]} readonly={is_nil(@tenant)} required />
          <.input label="Password" type="password" name={"tenant[users][#{index}][db_password]"} value={user["db_password"]} placeholder={if user["id"] in [nil, ""], do: "Password for the selected login", else: "Leave blank to keep current password"} autocomplete="new-password" required={user["id"] in [nil, ""]} />
        </div>
      </section>

      <details id="tenant-advanced" class="form-section" open={map_size(@errors) > 0}>
        <summary class="advanced-summary">
          <span class="hero-adjustments-horizontal-mini"></span>
          Advanced options
        </summary>
        <p class="advanced-help">
          The defaults work for most applications. Change these only when your database or application needs different authentication, pooling, or network settings.
        </p>
        <div class="form-grid">
          <.input type="select" label="Authentication" name="tenant[auth_mode]" value={@params["auth_mode"]}
            options={[{"Saved database login", "stored_users"}, {"PostgreSQL authentication query", "auth_query"}]} />
          <.input :if={@params["auth_mode"] == "auth_query"} type="textarea" label="Auth query" name="tenant[auth_query]" value={@params["auth_query"]} rows="3" errors={error(@errors, "auth_query")} />
        </div>
        <h3>Login options</h3>
        <p class="field-help">Use the same role name for clients by default. Additional logins and separate pool settings are optional.</p>
        <div :for={{index, user} <- sorted_users(@params)} class="form-grid user-row">
          <strong>{user["db_user"] || "Database login"}</strong>
          <.input label="Client username" name={"tenant[users][#{index}][db_user_alias]"} value={user["db_user_alias"]} placeholder={user["db_user"]} />
          <.input type="select" label="Pool mode" name={"tenant[users][#{index}][mode_type]"} value={user["mode_type"]} options={[{"Transaction", "transaction"}, {"Session", "session"}]} />
          <.input label="Pool size" type="number" name={"tenant[users][#{index}][pool_size]"} value={user["pool_size"]} />
          <.input label="Checkout timeout ms" type="number" name={"tenant[users][#{index}][pool_checkout_timeout]"} value={user["pool_checkout_timeout"]} />
          <.input label="Max clients" type="number" name={"tenant[users][#{index}][max_clients]"} value={user["max_clients"]} />
          <.input type="checkbox" label="Manager for authentication queries" name={"tenant[users][#{index}][is_manager]"} checked={user["is_manager"] == "true"} />
          <button :if={map_size(@params["users"]) > 1} type="button" class="danger-button" phx-click="remove-user" phx-value-index={index}>Remove login</button>
        </div>
        <button type="button" class="secondary-button" phx-click="add-user"><span class="hero-user-plus-mini"></span>Add another login</button>
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
        <button type="submit" class="primary-button" disabled={!@tenant and (@catalog_loading or is_nil(@catalog))}><span class="hero-check-mini"></span>{if @tenant, do: "Save changes", else: "Connect database"}</button>
        <.link class="secondary-button" navigate={~p"/admin"}>Cancel</.link>
      </div>
    </form>

    <details :if={is_nil(@created)} id="tenant-connection-help" class="form-section connection-help-panel">
      <summary class="advanced-summary"><span class="hero-code-bracket"></span>How your application connects</summary>
      <p class="field-help">Use this connection URL in your application after saving. Replace PASSWORD with the selected login's password.</p>
      <p :if={private_pool?()} class="field-help">This pool is private on this server. Remote applications need an SSH tunnel or a private network connection.</p>
      <div class="connection-recipe"><div><span>Database</span><code>{upstream_database(@params)}</code></div><div><span>Username</span><code>{client_username(@params)}</code></div><div><span>Transaction port</span><code>{transaction_port()}</code></div><div><span>Session port</span><code>{session_port()}</code></div></div>
      <label class="field"><span>Example connection URL</span><input readonly value={sample_connection_uri(@params, @pooler_host)} /></label>
      <div class="code-example-panel"><span>Elixir / Ecto example</span><pre><code>{ecto_config_example(@params, @pooler_host)}</code></pre></div>
    </details>
    """
  end
end
