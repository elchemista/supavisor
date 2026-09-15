defmodule SupavisorWeb.Admin.AuthorizationLive do
  use SupavisorWeb, :live_view
  alias SupavisorWeb.AdminSettings

  @impl true
  def mount(_params, _session, socket), do: {:ok, load_settings(socket)}

  @impl true
  def handle_event("save_admins", %{"emails" => emails}, socket) do
    case AdminSettings.save_admins(emails, socket.assigns.current_admin_email) do
      {:ok, _} ->
        {:noreply, socket |> load_settings() |> put_flash(:info, "Admin email addresses saved.")}

      {:error, message} when is_binary(message) ->
        {:noreply, socket |> assign(:emails, emails) |> put_flash(:error, message)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save admin email addresses.")}
    end
  end

  def handle_event("save_github", %{"github" => params}, socket) do
    case AdminSettings.save_github(params, socket.assigns.current_admin_email) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_settings()
         |> push_event("clear-github-secret", %{})
         |> put_flash(:info, "GitHub sign-in settings saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
            Enum.reduce(opts, message, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        form =
          Map.merge(
            socket.assigns.github,
            Map.take(params, ["github_enabled", "github_client_id", "github_redirect_uri"])
          )

        {:noreply,
         socket
         |> assign(github: form, errors: errors)
         |> put_flash(:error, "Check the highlighted GitHub settings.")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp load_settings(socket) do
    settings = AdminSettings.get()

    assign(socket,
      emails: Enum.join(settings.admin_emails, "\n"),
      admin_count: length(settings.admin_emails),
      github: %{
        "github_enabled" => to_string(settings.github_enabled),
        "github_client_id" => settings.github_client_id || "",
        "github_redirect_uri" => settings.github_redirect_uri || ""
      },
      enabled: settings.github_enabled,
      secret_saved: is_binary(settings.github_client_secret),
      errors: %{},
      default_callback: SupavisorWeb.AdminAuth.base_url() <> "/admin/auth/github/callback"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-hero"><div><div class="eyebrow"><span class="eyebrow-line"></span> YOUR WORKSPACE, YOUR RULES</div><h1>Authorization<span class="heading-dot">.</span></h1><p class="page-subtitle">Choose who can access your workspace and how they sign in.</p></div><span class="protocol-badge"><%= @admin_count %> <%= if @admin_count == 1, do: "admin", else: "admins" %></span></section>
    <div class="authorization-grid">
      <section class="form-section auth-admins">
        <div class="form-section-heading"><span class="step-marker"><span class="hero-user-group"></span></span><div><h2>Admin email addresses</h2><p>Only these addresses can sign in to the console.</p></div></div>
        <form phx-submit="save_admins" id="admin-emails-form">
          <.input type="textarea" name="emails" value={@emails} label="Allowed administrators" rows="7" spellcheck="false" maxlength="25500" />
          <p class="field-help">One email per line. Keep your current address to preserve your access.</p>
          <div class="signed-in-note"><span class="profile-avatar"><%= String.first(@current_admin_email) |> String.upcase() %></span><div><span>Signed in as</span><strong><%= @current_admin_email %></strong></div></div>
          <button type="submit" class="primary-button" phx-disable-with="Saving…"><span class="hero-check"></span>Save administrators</button>
        </form>
        <p class="service-note"><span class="hero-information-circle"></span>Changes are saved in PostgreSQL and take effect without restarting. Removed administrators lose access on their next request or interaction.</p>
      </section>
      <section class="form-section auth-github">
        <div class="form-section-heading"><span class="step-marker"><span class="hero-code-bracket"></span></span><div><h2>GitHub sign-in</h2><p>Let administrators use their GitHub account.</p></div><span class={["status-badge", !@enabled && "pending"]}><i class="status-dot"></i><%= if @enabled, do: "Enabled", else: "Not enabled" %></span></div>
        <form phx-submit="save_github" id="github-settings-form">
          <.input type="checkbox" name="github[github_enabled]" checked={@github["github_enabled"] == "true"} label="Enable GitHub sign-in" />
          <div class="form-grid form-grid-wide">
            <.input name="github[github_client_id]" value={@github["github_client_id"]} label="Client ID" autocomplete="off" errors={Map.get(@errors, :github_client_id, [])} />
            <.input type="password" name="github[github_client_secret]" value="" label="Client Secret" autocomplete="new-password" placeholder={if @secret_saved, do: "Saved · leave blank to keep it", else: "Paste your GitHub Client Secret"} errors={Map.get(@errors, :github_client_secret, [])} />
            <.input type="url" name="github[github_redirect_uri]" value={@github["github_redirect_uri"]} label="Authorization callback URL" errors={Map.get(@errors, :github_redirect_uri, [])} />
          </div>
          <p class="field-help">The callback URL must exactly match the one in your GitHub OAuth App.</p>
          <div class="form-actions"><button type="submit" class="primary-button" phx-disable-with="Saving…"><span class="hero-check"></span>Save GitHub settings</button></div>
        </form>
        <p class="service-note"><span class="hero-lock-closed"></span>The Client Secret is encrypted in PostgreSQL and never shown again. GitHub must verify an email address from your admin list.</p>
      </section>
    </div>
    <details class="setup-panel data-panel" open>
      <summary><span class="hero-code-bracket"></span>Set up your GitHub OAuth App<span class="hero-chevron-down"></span></summary>
      <div class="setup-content"><ol class="setup-steps"><li><a href="https://github.com/settings/developers" target="_blank" rel="noopener noreferrer">Open GitHub Developer Settings <span class="hero-arrow-up-right"></span></a> and create an OAuth App.</li><li>Set its homepage to your console address and copy the callback URL below.</li><li>Paste the Client ID and Client Secret above, enable GitHub sign-in, then save.</li></ol><div class="api-endpoint mono"><%= @default_callback %></div><p>Use the same hostname when opening the console. In local development, direct email sign-in stays available.</p><a class="row-link" href="https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps" target="_blank" rel="noopener noreferrer">GitHub OAuth documentation <span class="hero-arrow-up-right"></span></a></div>
    </details>
    """
  end
end
