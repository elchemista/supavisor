defmodule SupavisorWeb.AdminEmail do
  @moduledoc false

  import Swoosh.Email

  alias SupavisorWeb.AdminAuth

  def magic_link(email, url, ttl_seconds) do
    new()
    |> to(email)
    |> from(AdminAuth.email_from())
    |> subject("Your Supavisor admin sign-in link")
    |> text_body("""
    Use this link to sign in to Supavisor Admin:

    #{url}

    This link expires in #{div(ttl_seconds, 60)} minutes and can be used once.
    """)
    |> html_body("""
    <p>Use this link to sign in to Supavisor Admin:</p>
    <p><a href="#{url}" target="_top">Sign in to Supavisor Admin</a></p>
    <p>This link expires in #{div(ttl_seconds, 60)} minutes and can be used once.</p>
    """)
  end
end
