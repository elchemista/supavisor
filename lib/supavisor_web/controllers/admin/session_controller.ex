defmodule SupavisorWeb.Admin.SessionController do
  use SupavisorWeb, :controller

  alias SupavisorWeb.{AdminAuth, AdminCap, AdminCredential, AdminLoginLimiter}
  @development Application.compile_env(:supavisor, :env) == :dev

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
        conn |> AdminAuth.log_in_admin(email) |> redirect(to: ~p"/admin/postgres")

      params["method"] == "magic_link" and AdminAuth.email_sign_in_enabled?() ->
        send_magic_link(conn, email)

      true ->
        case AdminCredential.authenticate(email, params["password"]) do
          {:ok, version} ->
            AdminLoginLimiter.succeeded(email)
            conn |> AdminAuth.log_in_admin(email, version) |> redirect(to: ~p"/admin")

          _ ->
            login_error(conn, "Invalid email or password.", 401)
        end
    end
  end

  def create(conn, _), do: login_error(conn, "Invalid email or password.", 401)

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
            "Password saved. You can now sign in without email delivery. Other sessions have been signed out."
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

  defp send_magic_link(conn, email) do
    case AdminAuth.deliver_magic_link(email) do
      {:error, _reason} ->
        conn
        |> put_flash(
          :error,
          "Could not send the sign-in link. Check the email delivery configuration."
        )
        |> then(&html(&1, login_page(&1)))

      _ ->
        conn
        |> put_flash(
          :info,
          "If that email is configured for admin access, a sign-in link has been sent."
        )
        |> then(&html(&1, login_page(&1)))
    end
  end

  def verify(conn, %{"token" => token}) do
    case AdminAuth.verify_magic_link(token) do
      {:ok, email} ->
        destination =
          if AdminCredential.configured?(email),
            do: ~p"/admin",
            else: ~p"/admin/authorization#password"

        conn
        |> AdminAuth.log_in_admin(email)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: destination)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That sign-in link is invalid or expired.")
        |> redirect(to: ~p"/admin/login")
    end
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
        do:
          "Sign in to the PostgreSQL console on this computer. No email delivery needed locally.",
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

    email_login =
      if not local? and AdminAuth.email_sign_in_enabled?() do
        """
        <details class="login-alternative">
          <summary>Sign in with an email link</summary>
          <form method="post" action="/admin/login" data-cap-form>
            <input type="hidden" name="_csrf_token" value="#{csrf}">
            <input type="hidden" name="method" value="magic_link">
            <label class="field"><span>Email</span><input type="email" name="email" required maxlength="254" autocomplete="email"></label>
            #{captcha}
            <button type="submit" class="secondary-button w-full">Send sign-in link</button>
          </form>
        </details>
        """
      else
        ""
      end

    setup_note =
      if local?,
        do: "",
        else:
          ~s(<p class="login-help">First time here? Open the secure setup link provided by your server administrator to choose your password.</p>)

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
            #{email_login}
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
      conn.host in ["localhost", "127.0.0.1", "::1"] and
      Application.get_env(:supavisor, Supavisor.Mailer)[:adapter] == Swoosh.Adapters.Local
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
