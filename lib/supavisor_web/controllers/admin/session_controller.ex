defmodule SupavisorWeb.Admin.SessionController do
  use SupavisorWeb, :controller

  alias SupavisorWeb.{AdminAuth, AdminCap, AdminCredential, AdminLoginLimiter}
  @development Application.compile_env(:supavisor, :env) == :dev

  plug :require_credentials_store when action in [:new, :create, :password]

  def index(conn, _params), do: redirect(conn, to: ~p"/admin")

  def new(conn, _params) do
    if conn.assigns[:current_admin_email] do
      redirect(conn, to: ~p"/admin")
    else
      html(conn, login_page(conn))
    end
  end

  def create(conn, %{"email" => email} = params) when is_binary(email) do
    cond do
      byte_size(email) > 254 ->
        login_error(conn, "Invalid email or password.", 401)

      not AdminLoginLimiter.allow?(conn.remote_ip, email) ->
        login_error(conn, "Too many sign-in attempts. Try again in 15 minutes.", 429)

      AdminCap.verify(conn, params["cap-token"]) != :ok ->
        login_error(conn, "Please complete the anti-bot verification and try again.", 422)

      local_access?(conn) and AdminAuth.admin_email?(email) ->
        conn |> AdminAuth.log_in_admin(email) |> AdminAuth.redirect_after_login("/admin/postgres")

      true ->
        case AdminCredential.authenticate(email, params["password"]) do
          {:ok, version} ->
            AdminLoginLimiter.succeeded(email)
            conn |> AdminAuth.log_in_admin(email, version) |> AdminAuth.redirect_after_login()

          {:error, :credentials_unavailable} ->
            AdminAuth.credentials_unavailable(conn)

          _ ->
            login_error(conn, "Invalid email or password.", 401)
        end
    end
  end

  def create(conn, _), do: login_error(conn, "Invalid email or password.", 401)

  defp require_credentials_store(conn, _) do
    if AdminCredential.available?(), do: conn, else: AdminAuth.credentials_unavailable(conn)
  end

  def password(conn, %{"password" => params}) when is_map(params) do
    email = conn.assigns.current_admin_email

    if AdminLoginLimiter.allow?(conn.remote_ip, email) do
      case AdminCredential.save_password(email, params) do
        {:ok, version} ->
          AdminLoginLimiter.succeeded(email)

          conn
          |> AdminAuth.log_in_admin(email, version)
          |> put_flash(
            :info,
            "Password saved. Other sessions have been signed out."
          )
          |> redirect(to: ~p"/admin/authorization")

        {:error, message} ->
          conn |> put_flash(:error, message) |> redirect(to: ~p"/admin/authorization")
      end
    else
      conn
      |> put_flash(:error, "Too many attempts. Try again in 15 minutes.")
      |> redirect(to: ~p"/admin/authorization")
    end
  end

  def password(conn, _), do: redirect(conn, to: ~p"/admin/authorization")

  defp login_error(conn, message, status) do
    conn |> put_status(status) |> put_flash(:error, message) |> then(&html(&1, login_page(&1)))
  end

  def delete(conn, _params) do
    conn
    |> AdminAuth.log_out_admin()
    |> redirect(to: ~p"/admin/login")
  end

  defp login_page(conn) do
    csrf = get_csrf_token()
    info = flash_markup(conn, :info)
    error = flash_markup(conn, :error)
    captcha = captcha_markup()

    local? = local_access?(conn)

    description =
      if local?,
        do: "Sign in to the PostgreSQL console on this computer.",
        else: "Sign in with your administrator email and password."

    github =
      if match?({:ok, _}, SupavisorWeb.AdminSettings.github_config()) do
        ~s(<div class="login-divider"><span>or</span></div><form method="post" action="/admin/auth/github" data-cap-form><input type="hidden" name="_csrf_token" value="#{csrf}">#{captcha}<button type="submit" class="secondary-button github-login"><span class="hero-code-bracket"></span>Continue with GitHub</button></form>)
      else
        ""
      end

    button = if local?, do: "Sign in locally", else: "Sign in"
    email = if local?, do: List.first(AdminAuth.admin_emails()) || "", else: ""
    email = email |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    password_field =
      if local? do
        ""
      else
        ~s(<label class="field"><span>Password</span><input type="password" name="password" required maxlength="128" autocomplete="current-password"></label>)
      end

    setup_note =
      if local?,
        do: "",
        else:
          ~s(<p class="login-help">First time here? Ask your server administrator to generate your initial password with supavisor-admin-password.</p>)

    """
    <!DOCTYPE html>
    <html lang="en" data-theme="supavisor-dark">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="csrf-token" content="#{csrf}">
        <title>Supavisor Admin Login</title>
        <link rel="icon" href="/favicon.svg" type="image/svg+xml">
        <link rel="stylesheet" href="/assets/app.css">
        <script defer src="/assets/login.js"></script>
      </head>
      <body>
        <main class="login-shell">
          <section class="login-panel">
            <h1>Supavisor Admin</h1>
            <p>#{description}</p>
            #{info}
            #{error}
            <form method="post" action="/admin/login" data-cap-form>
              <input type="hidden" name="_csrf_token" value="#{csrf}">
              <input type="hidden" name="method" value="password">
              <label class="field">
                <span>Email</span>
                <input type="email" name="email" value="#{email}" required maxlength="254" autocomplete="username">
              </label>
              #{password_field}
              #{captcha}
              <button type="submit" class="primary-button w-full">#{button}</button>
            </form>
            #{github}
            #{setup_note}
          </section>
        </main>
      </body>
    </html>
    """
  end

  defp captcha_markup do
    """
    <div class="login-verification">
      <cap-widget data-cap-api-endpoint="/admin/cap/" data-cap-worker-count="2"
        data-cap-i18n-initial-state="I'm not a robot"
        data-cap-i18n-verifying-label="Verifying…"
        data-cap-i18n-solved-label="Verified"
        data-cap-i18n-error-label="Verification failed. Try again."
        data-cap-i18n-required-label="Complete the anti-bot verification to continue."
        required></cap-widget>
      <p class="captcha-status" role="status" aria-live="polite"></p>
      <noscript><p>Enable JavaScript to complete the anti-bot verification and sign in.</p></noscript>
    </div>
    """
  end

  defp local_access?(conn) do
    @development and
      conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] and
      conn.host in ["localhost", "127.0.0.1", "::1"]
  end

  defp flash_markup(conn, kind) do
    case Phoenix.Flash.get(conn.assigns[:flash] || %{}, kind) do
      nil ->
        ""

      message ->
        message =
          message
          |> Phoenix.HTML.html_escape()
          |> Phoenix.HTML.safe_to_string()

        ~s(<p class="notice notice-#{kind}">#{message}</p>)
    end
  end
end
