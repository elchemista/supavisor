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

  def init(action), do: action

  def call(conn, :fetch_current_admin), do: fetch_current_admin(conn)
  def call(conn, :require_authenticated_admin), do: require_authenticated_admin(conn)

  def on_mount(:default, _params, session, socket) do
    case current_admin_from_session(session) do
      {:ok, email} ->
        {:cont, Phoenix.Component.assign(socket, :current_admin_email, email)}

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

  def log_in_admin(conn, email) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_email_key, normalize_email(email))
    |> put_session(@session_authenticated_at_key, now_seconds())
  end

  def log_out_admin(conn) do
    conn
    |> configure_session(drop: true)
  end

  def deliver_magic_link(email) do
    email = normalize_email(email)

    if admin_email?(email) do
      nonce = random_nonce()
      ttl = magic_link_ttl_seconds()
      cache_key = magic_link_cache_key(nonce)

      with {:ok, true} <- Cachex.put(Supavisor.Cache, cache_key, email, ttl: ttl * 1000),
           token <- sign_magic_link_token(email, nonce),
           url <- magic_link_url(token),
           {:ok, _metadata} <- AdminEmail.magic_link(email, url, ttl) |> Mailer.deliver() do
        {:ok, :sent}
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      :ok
    end
  end

  def verify_magic_link(token) do
    with {:ok, %{"email" => email, "nonce" => nonce}} <-
           Phoenix.Token.verify(Endpoint, @magic_link_salt, token,
             max_age: magic_link_ttl_seconds()
           ),
         {:ok, ^email} <- Cachex.get(Supavisor.Cache, magic_link_cache_key(nonce)),
         {:ok, _deleted?} <- Cachex.del(Supavisor.Cache, magic_link_cache_key(nonce)) do
      {:ok, email}
    else
      _ -> {:error, :invalid_or_expired}
    end
  end

  def admin_email?(email) do
    email = normalize_email(email)
    email in admin_emails()
  end

  def admin_emails do
    __MODULE__
    |> config()
    |> Keyword.get(:admin_emails, [])
    |> Enum.map(&normalize_email/1)
  end

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
