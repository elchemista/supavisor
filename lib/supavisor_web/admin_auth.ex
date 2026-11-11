defmodule SupavisorWeb.AdminAuth do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  @session_email_key "admin_email"
  @session_authenticated_at_key "admin_authenticated_at"
  @session_version_key "admin_session_version"

  def init(action), do: action

  def authenticate_session(session) when is_map(session), do: current_admin_from_session(session)
  def authenticate_session(_), do: :error

  def call(conn, :fetch_current_admin), do: fetch_current_admin(conn)
  def call(conn, :require_authenticated_admin), do: require_authenticated_admin(conn)

  def on_mount(:default, _params, session, socket) do
    case current_admin_from_session(session) do
      {:ok, email} ->
        socket =
          socket
          |> Phoenix.Component.assign(:current_admin_email, email)
          |> Phoenix.LiveView.attach_hook(:admin_session_check, :handle_event, fn _event,
                                                                                  _params,
                                                                                  socket ->
            case current_admin_from_session(session) do
              {:ok, _} -> {:cont, socket}
              :error -> {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
            end
          end)

        socket =
          Phoenix.LiveView.attach_hook(
            socket,
            :admin_navigation_check,
            :handle_params,
            fn _params, _uri, socket ->
              case current_admin_from_session(session) do
                {:ok, _} -> {:cont, socket}
                :error -> {:halt, Phoenix.LiveView.redirect(socket, to: "/admin/login")}
              end
            end
          )

        {:cont, socket}

      :error ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Sign in to continue.")
          |> Phoenix.LiveView.redirect(to: "/admin/login")

        {:halt, socket}
    end
  end

  def fetch_current_admin(conn) do
    case current_admin_from_session(conn) do
      {:ok, email} -> assign(conn, :current_admin_email, email)
      :error -> assign(conn, :current_admin_email, nil)
    end
  end

  def require_authenticated_admin(conn) do
    case conn.assigns[:current_admin_email] do
      email when is_binary(email) ->
        conn

      _ ->
        conn
        |> put_flash(:error, "Sign in to continue.")
        |> redirect(to: "/admin/login")
        |> halt()
    end
  end

  def log_in_admin(conn, email, version \\ :current) do
    version =
      if version == :current,
        do: SupavisorWeb.AdminCredential.session_version(email),
        else: version

    case version do
      {:error, :credentials_unavailable} ->
        credentials_unavailable(conn)

      _ ->
        conn
        |> configure_session(renew: true)
        |> put_session(@session_email_key, normalize_email(email))
        |> put_session(@session_authenticated_at_key, now_seconds())
        |> put_session(@session_version_key, version)
    end
  end

  def credentials_unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "5")
    |> put_resp_content_type("text/plain")
    |> send_resp(
      503,
      "Administrator sign-in is temporarily unavailable. Check the metadata database and run mix supavisor.migrate (or bin/migrate for a release)."
    )
    |> halt()
  end

  def log_out_admin(conn) do
    conn
    |> configure_session(drop: true)
  end

  def redirect_after_login(conn, fallback \\ "/admin")
  def redirect_after_login(%Plug.Conn{halted: true} = conn, _fallback), do: conn

  def redirect_after_login(conn, fallback) do
    return_to = get_session(conn, :admin_return_to)

    destination =
      if valid_authorization_return?(return_to), do: return_to, else: fallback

    conn
    |> delete_session(:admin_return_to)
    |> redirect(to: destination)
  end

  defp valid_authorization_return?(value) when is_binary(value) and byte_size(value) <= 16_384 do
    case URI.parse(value) do
      %URI{scheme: nil, host: nil, path: "/oauth/authorize", fragment: nil, userinfo: nil} ->
        not String.contains?(value, ["\r", "\n", "\\"])

      _ ->
        false
    end
  end

  defp valid_authorization_return?(_), do: false

  def admin_email?(email) do
    email = normalize_email(email)
    email in admin_emails()
  end

  def admin_emails, do: SupavisorWeb.AdminSettings.admin_emails()

  def session_ttl_seconds do
    __MODULE__
    |> config()
    |> Keyword.fetch!(:session_ttl_seconds)
  end

  def base_url do
    __MODULE__
    |> config()
    |> Keyword.fetch!(:base_url)
    |> String.trim_trailing("/")
  end

  defp current_admin_from_session(%Plug.Conn{} = conn) do
    conn
    |> get_session()
    |> current_admin_from_session()
  end

  defp current_admin_from_session(session) when is_map(session) do
    with email when is_binary(email) <- session[@session_email_key],
         authenticated_at when is_integer(authenticated_at) <-
           session[@session_authenticated_at_key],
         true <- admin_email?(email),
         version when is_nil(version) or is_binary(version) <-
           SupavisorWeb.AdminCredential.session_version(email),
         true <-
           Map.get(session, @session_version_key) == version,
         true <- now_seconds() - authenticated_at <= session_ttl_seconds() do
      {:ok, email}
    else
      _ -> :error
    end
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(_), do: ""

  defp now_seconds, do: System.system_time(:second)

  defp config(module), do: Application.fetch_env!(:supavisor, module)
end
