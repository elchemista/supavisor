defmodule SupavisorWeb.Admin.SessionController do
  use SupavisorWeb, :controller

  alias SupavisorWeb.AdminAuth
  @development Application.compile_env(:supavisor, :env) == :dev

  def index(conn, _params), do: redirect(conn, to: ~p"/admin")

  def new(conn, _params) do
    if conn.assigns[:current_admin_email] do
      redirect(conn, to: ~p"/admin")
    else
      html(conn, login_page(conn))
    end
  end

  def create(conn, %{"email" => email}) do
    if local_access?(conn) and AdminAuth.admin_email?(email) do
      conn
      |> AdminAuth.log_in_admin(email)
      |> redirect(to: ~p"/admin/postgres")
    else
      send_magic_link(conn, email)
    end
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
        conn
        |> AdminAuth.log_in_admin(email)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: ~p"/admin")

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

    local? = local_access?(conn)

    description =
      if local?,
        do:
          "Sign in to the PostgreSQL console on this computer. No email delivery needed locally.",
        else: "Enter your configured admin email to receive a one-time sign-in link."

    github =
      if match?({:ok, _}, SupavisorWeb.AdminSettings.github_config()) do
        ~s(<div class="login-divider"><span>or</span></div><form method="post" action="/admin/auth/github"><input type="hidden" name="_csrf_token" value="#{csrf}"><button type="submit" class="secondary-button github-login"><span class="hero-code-bracket"></span>Continue with GitHub</button></form>)
      else
        ""
      end

    button = if local?, do: "Sign in locally", else: "Send sign-in link"
    email = if local?, do: List.first(AdminAuth.admin_emails()) || "", else: ""
    email = email |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    """
    <!DOCTYPE html>
    <html lang="en" data-theme="supavisor-dark">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Supavisor Admin Login</title>
        <link rel="stylesheet" href="/assets/app.css">
      </head>
      <body>
        <main class="login-shell">
          <section class="login-panel">
            <h1>Supavisor Admin</h1>
            <p>#{description}</p>
            #{info}
            #{error}
            <form method="post" action="/admin/login">
              <input type="hidden" name="_csrf_token" value="#{csrf}">
              <label class="field">
                <span>Email</span>
                <input type="email" name="email" value="#{email}" required autocomplete="email">
              </label>
              <button type="submit" class="primary-button w-full">#{button}</button>
            </form>
            #{github}
          </section>
        </main>
      </body>
    </html>
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
