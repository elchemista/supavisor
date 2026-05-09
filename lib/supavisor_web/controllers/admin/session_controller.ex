defmodule SupavisorWeb.Admin.SessionController do
  use SupavisorWeb, :controller

  alias SupavisorWeb.AdminAuth

  def new(conn, _params) do
    if conn.assigns[:current_admin_email] do
      redirect(conn, to: ~p"/admin")
    else
      html(conn, login_page(conn))
    end
  end

  def create(conn, %{"email" => email}) do
    case AdminAuth.deliver_magic_link(email) do
      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not send sign-in link: #{inspect(reason)}")
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

    """
    <!DOCTYPE html>
    <html lang="en" data-theme="supavisor">
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
            <p>Enter your configured admin email to receive a one-time sign-in link.</p>
            #{info}
            #{error}
            <form method="post" action="/admin/login">
              <input type="hidden" name="_csrf_token" value="#{csrf}">
              <label class="field">
                <span>Email</span>
                <input type="email" name="email" required autocomplete="email">
              </label>
              <button type="submit" class="primary-button w-full">Send sign-in link</button>
            </form>
          </section>
        </main>
      </body>
    </html>
    """
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
