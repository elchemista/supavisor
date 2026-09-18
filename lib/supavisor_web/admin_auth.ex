defmodule SupavisorWeb.AdminAuth do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias Supavisor.Mailer
  alias SupavisorWeb.AdminEmail
  alias SupavisorWeb.Endpoint

  @magic_link_salt "admin magic link"
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

    conn
    |> configure_session(renew: true)
    |> put_session(@session_email_key, normalize_email(email))
    |> put_session(@session_authenticated_at_key, now_seconds())
    |> put_session(@session_version_key, version)
  end

  def log_out_admin(conn) do
    conn
    |> configure_session(drop: true)
  end

  def deliver_magic_link(email) do
    case create_magic_link(email) do
      {:ok, url} ->
        case AdminEmail.magic_link(normalize_email(email), url, magic_link_ttl_seconds())
             |> Mailer.deliver() do
          {:ok, _metadata} -> {:ok, :sent}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_allowed} ->
        :ok

      error ->
        error
    end
  end

  def email_sign_in_enabled?,
    do: Application.get_env(:supavisor, :admin_email_login_enabled, false)

  @doc "Create a one-time link for an allowed admin, also usable from a release RPC console."
  def create_magic_link(email) do
    email = normalize_email(email)

    if admin_email?(email) do
      nonce = random_nonce()
      ttl = magic_link_ttl_seconds()
      cache_key = magic_link_cache_key(nonce)

      with {:ok, true} <- Cachex.put(Supavisor.Cache, cache_key, email, ttl: ttl * 1000) do
        {:ok, magic_link_url(sign_magic_link_token(email, nonce))}
      end
    else
      {:error, :not_allowed}
    end
  end

  def verify_magic_link(token) do
    with {:ok, %{"email" => email, "nonce" => nonce}} <-
           Phoenix.Token.verify(Endpoint, @magic_link_salt, token,
             max_age: magic_link_ttl_seconds()
           ),
         true <- admin_email?(email),
         {:ok, ^email} <- Cachex.take(Supavisor.Cache, magic_link_cache_key(nonce)) do
      {:ok, email}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

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

  def magic_link_ttl_seconds do
    __MODULE__
    |> config()
    |> Keyword.fetch!(:magic_link_ttl_seconds)
  end

  def email_from do
    __MODULE__
    |> config()
    |> Keyword.fetch!(:email_from)
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
         true <-
           Map.get(session, @session_version_key) ==
             SupavisorWeb.AdminCredential.session_version(email),
         true <- now_seconds() - authenticated_at <= session_ttl_seconds() do
      {:ok, email}
    else
      _ -> :error
    end
  end

  defp sign_magic_link_token(email, nonce) do
    Phoenix.Token.sign(Endpoint, @magic_link_salt, %{"email" => email, "nonce" => nonce})
  end

  defp magic_link_url(token), do: base_url() <> "/admin/magic/" <> URI.encode_www_form(token)

  defp magic_link_cache_key(nonce), do: {:admin_magic_link_nonce, nonce}

  defp random_nonce do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
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
