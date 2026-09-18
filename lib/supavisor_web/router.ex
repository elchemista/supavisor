defmodule SupavisorWeb.Router do
  use SupavisorWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {SupavisorWeb.LayoutView, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :admin_fetch do
    plug(SupavisorWeb.AdminAuth, :fetch_current_admin)
  end

  pipeline :admin_cap do
    plug(:accepts, ["json"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :require_admin do
    plug(SupavisorWeb.AdminAuth, :require_authenticated_admin)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(:check_auth, [:api_jwt_secret, :api_blocklist])
    plug(OpenApiSpex.Plug.PutApiSpec, module: SupavisorWeb.ApiSpec)
  end

  pipeline :service_api do
    plug(:accepts, ["json"])
    plug(SupavisorWeb.Services.Auth)
  end

  pipeline :media_api do
    plug(SupavisorWeb.Services.Auth)
  end

  pipeline :metrics do
    plug(:check_auth, [:metrics_jwt_secret, :metrics_blocklist])
  end

  pipeline :openapi do
    plug(OpenApiSpex.Plug.PutApiSpec, module: SupavisorWeb.ApiSpec)
  end

  scope "/", SupavisorWeb.Admin do
    pipe_through(:browser)
    get("/", SessionController, :index)
  end

  scope "/swaggerui" do
    pipe_through(:browser)
    get("/", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi")
  end

  scope "/api" do
    pipe_through(:openapi)
    get("/openapi", OpenApiSpex.Plug.RenderSpec, [])
  end

  # websocket pg proxy
  scope "/v2" do
    get("/", SupavisorWeb.WsProxy, [])
  end

  scope "/api", SupavisorWeb do
    pipe_through(:api)

    get("/tenants/:external_id", TenantController, :show)
    put("/tenants/:external_id", TenantController, :update)
    patch("/tenants/:external_id", TenantController, :patch)
    delete("/tenants/:external_id", TenantController, :delete)
    get("/tenants/:external_id/terminate", TenantController, :terminate)

    post(
      "/tenants/:external_id/update_auth_credentials",
      TenantController,
      :update_auth_credentials
    )

    get("/tenants/:external_id/network_bans", TenantController, :list_network_bans)
    delete("/tenants/:external_id/network_bans", TenantController, :clear_network_bans)

    get("/health", TenantController, :health)

    get("/clusters/:alias", ClusterController, :show)
    put("/clusters/:alias", ClusterController, :update)
    delete("/clusters/:alias", ClusterController, :delete)
    # get("/clusters/:alias/terminate", ClusterController, :terminate)
  end

  scope "/api/services/v1", SupavisorWeb.Services do
    pipe_through(:service_api)
    get("/status", ServiceController, :status)
    get("/models", ServiceController, :models)
    post("/embeddings", ServiceController, :embeddings)
    post("/tts", ServiceController, :tts)
    post("/stt", ServiceController, :stt)
    post("/ai", ServiceController, :ai)
    get("/requests/:id", ServiceController, :request)
    post("/requests/:id/cancel", ServiceController, :cancel)
    get("/mailboxes", ServiceController, :mailboxes)
    get("/mail/messages", ServiceController, :messages)
    get("/mail/messages/:id", ServiceController, :message)
    post("/mail/send", ServiceController, :send_mail)
  end

  scope "/api/services/v1/audio", SupavisorWeb.Services do
    pipe_through(:media_api)
    post("/", AudioController, :create)
    get("/:id", AudioController, :show)
  end

  scope "/metrics", SupavisorWeb do
    pipe_through(:metrics)

    get("/", MetricsController, :index)
    get("/:external_id", MetricsController, :tenant)
  end

  scope "/admin", SupavisorWeb.Admin, as: :admin do
    pipe_through([:browser, :admin_fetch])

    get("/login", SessionController, :new)
    post("/login", SessionController, :create)
    post("/auth/github", GithubController, :start)
    get("/auth/github/callback", GithubController, :callback)
    get("/magic/:token", SessionController, :verify, log: false)
    delete("/logout", SessionController, :delete)
  end

  scope "/admin" do
    pipe_through(:admin_cap)
    forward("/cap", SupavisorWeb.AdminCap)
  end

  scope "/admin", SupavisorWeb.Admin, as: :admin do
    pipe_through([:browser, :admin_fetch, :require_admin])

    post("/password", SessionController, :password)

    get("/postgres/backups/:id/:kind", BackupController, :download)

    live_session :admin, on_mount: [SupavisorWeb.AdminAuth, SupavisorWeb.AdminNavigation] do
      live("/", DashboardLive, :index)
      live("/postgres", PostgresLive, :index)
      live("/postgres/backups", BackupLive, :index)
      live("/api", ApiLive, :index)
      live("/authorization", AuthorizationLive, :index)
      live("/metrics", MetricsLive, :index)
      live("/mailer", MailerLive, :index)
      live("/embedding", EmbeddingLive, :index)
      live("/stt", LocalModelsLive, :stt)
      live("/tts", LocalModelsLive, :tts)
      live("/ai-model", LocalModelsLive, :ai_model)
      live("/provision", ProvisionLive, :new)
      live("/tenants/new", TenantLive, :new)
      live("/tenants/:external_id/edit", TenantLive, :edit)
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", SupavisorWeb do
  #   pipe_through :api
  # end

  # Enables LiveDashboard only for development
  #
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication
  # as long as you are also using SSL (which you should anyway).
  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: SupavisorWeb.Telemetry)

      if Mix.env() == :dev do
        forward("/dev/mailbox", Plug.Swoosh.MailboxPreview)
      end
    end
  end

  defp check_auth(%{request_path: "/api/health"} = conn, _), do: conn

  defp check_auth(conn, [secret_key, blocklist_key]) do
    secret = Application.fetch_env!(:supavisor, secret_key)
    blocklist = Application.fetch_env!(:supavisor, blocklist_key)

    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         token <- Regex.replace(~r/\s|\n/, URI.decode(token), ""),
         false <- token in blocklist,
         {:ok, _claims} <- Supavisor.Jwt.authorize(token, secret) do
      conn
    else
      _ ->
        conn
        |> send_resp(403, "")
        |> halt()
    end
  end
end
