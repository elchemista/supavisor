defmodule SupavisorWeb.OAuthController do
  use SupavisorWeb, :controller

  import Ecto.Query
  alias Supavisor.MCP.Auth
  alias Supavisor.Repo
  alias Supavisor.Tenants.Tenant
  alias SupavisorWeb.AdminAuth

  plug SupavisorWeb.MCPOrigin
  plug :no_store
  plug :limit_authorization when action in [:authorize, :approve]

  def metadata(conn, _params), do: json(conn, Auth.metadata(conn.assigns.mcp_origin))

  def resource_metadata(conn, _params),
    do: json(conn, Auth.resource_metadata(conn.assigns.mcp_origin))

  def register(conn, params) do
    if Auth.rate_limit(conn.remote_ip, :register) do
      case Auth.register(params) do
        {:ok, response} -> conn |> put_status(:created) |> json(response)
        {:error, error} -> oauth_error(conn, error)
      end
    else
      oauth_error(conn, "temporarily_unavailable", 429)
    end
  end

  def authorize(conn, params) do
    case Auth.validate_authorization(params, conn.assigns.mcp_resource) do
      {:ok, client, request} ->
        case current_admin(conn) do
          {:ok, email} ->
            case Auth.create_consent(email) do
              {:ok, nonce} ->
                consent =
                  Phoenix.Token.sign(SupavisorWeb.Endpoint, "mcp consent", %{
                    request: request,
                    nonce: nonce
                  })

                conn
                |> put_session(:mcp_consent_nonce, nonce)
                |> html(consent_page(client, request, consent))

              _ ->
                oauth_error(conn, "temporarily_unavailable", 503)
            end

          :error ->
            conn
            |> put_session(:admin_return_to, "/oauth/authorize?" <> URI.encode_query(request))
            |> redirect(to: "/admin/login")
        end

      {:error, error} ->
        oauth_error(conn, error)
    end
  end

  def approve(conn, params) do
    with {:ok, email} <- current_admin(conn),
         consent when is_binary(consent) and byte_size(consent) <= 16_384 <- params["consent"],
         {:ok, %{request: request, nonce: nonce}} <-
           Phoenix.Token.verify(SupavisorWeb.Endpoint, "mcp consent", consent, max_age: 600),
         true <- is_binary(nonce) and nonce == get_session(conn, :mcp_consent_nonce),
         {:ok, _client, request} <-
           Auth.validate_authorization(request, conn.assigns.mcp_resource),
         :ok <- Auth.consume_consent(email, nonce) do
      conn = delete_session(conn, :mcp_consent_nonce)

      if params["decision"] == "deny" do
        redirect_response(conn, request, %{"error" => "access_denied"})
      else
        with "approve" <- params["decision"],
             {:ok, ids} <- selected_tenants(params),
             {:ok, code} <-
               Auth.issue_code(
                 request,
                 email,
                 Map.get(params, "scopes", []),
                 ids,
                 conn.assigns.mcp_resource
               ) do
          redirect_response(conn, request, %{"code" => code})
        else
          _ -> oauth_error(conn, "invalid_request")
        end
      end
    else
      _ -> oauth_error(conn, "invalid_request")
    end
  end

  def token(conn, params) do
    if Auth.rate_limit(conn.remote_ip, :token) do
      with {:ok, credentials} <- client_credentials(conn, params),
           {:ok, response} <- Auth.exchange(credentials, conn.assigns.mcp_resource) do
        json(conn, response)
      else
        {:error, "invalid_client"} -> oauth_error(conn, "invalid_client", 401)
        {:error, error} -> oauth_error(conn, error)
      end
    else
      oauth_error(conn, "temporarily_unavailable", 429)
    end
  end

  def revoke(conn, params) do
    if Auth.rate_limit(conn.remote_ip, :token) do
      with {:ok, credentials} <- client_credentials(conn, params),
           :ok <- Auth.revoke(credentials) do
        send_resp(conn, 200, "")
      else
        {:error, error} -> oauth_error(conn, error, 401)
      end
    else
      oauth_error(conn, "temporarily_unavailable", 429)
    end
  end

  defp limit_authorization(conn, _) do
    if Auth.rate_limit(conn.remote_ip, :authorize),
      do: conn,
      else: conn |> oauth_error("temporarily_unavailable", 429) |> halt()
  end

  defp no_store(conn, _) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp current_admin(conn), do: conn |> get_session() |> AdminAuth.authenticate_session()

  defp selected_tenants(%{"all_databases" => "true"}), do: {:ok, ["*"]}

  defp selected_tenants(params) do
    ids = Map.get(params, "tenant_ids", [])

    if is_list(ids) and length(ids) <= 500 and
         Enum.all?(ids, &(is_binary(&1) and byte_size(&1) <= 255 and &1 != "*")) do
      existing = Repo.all(from t in Tenant, where: t.external_id in ^ids, select: t.external_id)

      if Enum.all?(ids, &(&1 in existing)),
        do: {:ok, Enum.uniq(ids)},
        else: {:error, :invalid_tenants}
    else
      {:error, :invalid_tenants}
    end
  end

  defp client_credentials(conn, params) do
    params = Map.delete(params, "_auth_method")

    case get_req_header(conn, "authorization") do
      [] ->
        {:ok,
         Map.put(
           params,
           "_auth_method",
           if(params["client_secret"], do: "client_secret_post", else: "none")
         )}

      ["Basic " <> value] ->
        with {:ok, credentials} <- Base.decode64(value),
             [id, secret] <- String.split(credentials, ":", parts: 2),
             true <- params["client_secret"] == nil,
             true <- params["client_id"] in [nil, URI.decode_www_form(id)] do
          {:ok,
           Map.merge(params, %{
             "client_id" => URI.decode_www_form(id),
             "client_secret" => URI.decode_www_form(secret),
             "_auth_method" => "client_secret_basic"
           })}
        else
          _ -> {:error, "invalid_client"}
        end

      _ ->
        {:error, "invalid_client"}
    end
  end

  defp redirect_response(conn, request, response) do
    uri = URI.parse(request["redirect_uri"])
    query = if uri.query, do: URI.decode_query(uri.query), else: %{}

    response =
      if request["state"], do: Map.put(response, "state", request["state"]), else: response

    redirect(conn,
      external: URI.to_string(%{uri | query: URI.encode_query(Map.merge(query, response))})
    )
  end

  defp oauth_error(conn, error, status \\ 400),
    do: conn |> put_status(status) |> json(%{error: error})

  defp consent_page(client, request, consent) do
    scopes = String.split(request["scope"], " ")

    descriptions = %{
      "db:read" => "Read database schemas, rows, and migration history",
      "db:create" => "Create new databases and database roles",
      "db:migrate" => "Apply SQL migrations (may change or delete data)"
    }

    scope_fields =
      Enum.map_join(scopes, "\n", fn scope ->
        checked = if scope == "db:read", do: " checked", else: ""

        ~s(<label class="field"><span><input type="checkbox" name="scopes[]" value="#{escape(scope)}"#{checked}> #{escape(descriptions[scope])}</span></label>)
      end)

    tenants =
      Repo.all(
        from t in Tenant,
          where: t.external_id != "*",
          order_by: t.external_id,
          limit: 500,
          select: {t.external_id, t.db_database}
      )

    tenant_fields =
      Enum.map_join(tenants, "\n", fn {id, database} ->
        ~s|<label class="field"><span><input type="checkbox" name="tenant_ids[]" value="#{escape(id)}"> #{escape(id)} (#{escape(database)})</span></label>|
      end)

    csrf = escape(get_csrf_token())

    """
    <!DOCTYPE html>
    <html lang="en" data-theme="supavisor-dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Authorize database access</title><link rel="stylesheet" href="/assets/app.css"></head>
    <body><main class="login-shell"><section class="login-panel mcp-consent">
      <h1>Authorize database access</h1>
      <p><strong>#{escape(client.name)}</strong> requests access to your Supavisor databases.</p>
      <p>Return address: <code>#{escape(request["redirect_uri"])}</code></p>
      <form method="post" action="/oauth/authorize">
        <input type="hidden" name="_csrf_token" value="#{csrf}">
        <input type="hidden" name="consent" value="#{escape(consent)}">
        <h2>Permissions</h2><div class="mcp-scope-list">#{scope_fields}</div>
        <h2>Databases</h2><p>Choose which existing databases this application may access. New databases created by this connection are added automatically.</p>
        <div class="mcp-tenant-list">#{tenant_fields}</div>
        <label class="field"><span><input type="checkbox" name="all_databases" value="true"> Allow all current and future databases</span></label>
        <p>You can revoke this connection from the MCP page in the admin console. Approve only applications you trust.</p>
        <button type="submit" name="decision" value="approve" class="primary-button w-full">Allow selected access</button>
        <button type="submit" name="decision" value="deny" class="secondary-button w-full">Deny</button>
      </form>
    </section></main></body></html>
    """
  end

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
