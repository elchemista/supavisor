defmodule Mix.Tasks.Supavisor.Admin.ResetPassword do
  use Mix.Task
  @shortdoc "Generate a new administrator password without email delivery"
  @moduledoc """
  Run `mix supavisor.admin.reset_password [ADMIN_EMAIL]` from a source checkout.

  This starts the application, generates a fresh password, prints it once and
  invalidates earlier administrator sessions. The email must already be on the
  administrator allowlist. With exactly one administrator, the email is optional.

  On a running production release, use `sudo supavisor-admin-password [ADMIN_EMAIL]`
  instead, so the command uses the service's runtime configuration and cache.
  """

  @impl true
  def run(args) do
    email =
      case args do
        [] -> nil
        [email] -> email
        _ -> Mix.raise("Usage: mix supavisor.admin.reset_password [ADMIN_EMAIL]")
      end

    Mix.Task.run("app.start")
    Supavisor.Release.reset_admin_password(email)
  end
end
