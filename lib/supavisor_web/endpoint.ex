defmodule SupavisorWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :supavisor

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_supavisor_key",
    signing_salt: "zJOrGxcM",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug :rewrite_local_proxy_headers
  plug :rewrite_proxy_headers

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.Static,
    at: "/",
    from: :supavisor,
    gzip: false,
    only: SupavisorWeb.static_paths()

  plug Plug.RequestId

  plug Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {__MODULE__, :request_log_level, []}

  plug Plug.Parsers,
    parsers: [
      :urlencoded,
      {:multipart, length: 26_280_000, read_length: 65_536, read_timeout: 30_000},
      :json
    ],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SupavisorWeb.Router

  @doc false
  def request_log_level(_conn), do: :info

  defp rewrite_local_proxy_headers(conn, _opts),
    do: SupavisorWeb.MCPOrigin.rewrite_local_proxy(conn)

  defp rewrite_proxy_headers(conn, _opts) do
    if Application.get_env(:supavisor, :trust_proxy_headers, false) and
         conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      Plug.RewriteOn.call(conn, [:x_forwarded_proto, :x_forwarded_port, :x_forwarded_for])
    else
      conn
    end
  end
end
