defmodule SupavisorWeb.MCPOrigin do
  @moduledoc "Derives MCP/OAuth URLs from each request without shared mutable configuration."
  import Plug.Conn
  alias Supavisor.MCP.Auth

  @loopback [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = from_conn(conn)

    conn
    |> assign(:mcp_origin, origin)
    |> assign(:mcp_resource, Auth.resource(origin))
  rescue
    ArgumentError ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, JSON.encode!(%{error: "invalid_origin"}))
      |> halt()
  end

  # A local TLS terminator must preserve Host and replace forwarded headers.
  # Forwarded headers from remote clients never determine the OAuth issuer.
  def rewrite_local_proxy(conn, _opts \\ []) do
    if conn.remote_ip in @loopback do
      case get_req_header(conn, "x-forwarded-proto") do
        [scheme] when scheme in ["http", "https"] ->
          port = forwarded_port(conn, if(scheme == "https", do: 443, else: 80))
          %{conn | scheme: if(scheme == "https", do: :https, else: :http), port: port}

        _ ->
          conn
      end
    else
      conn
    end
  end

  def from_conn(conn) do
    conn = rewrite_local_proxy(conn)
    origin(conn.scheme, conn.host, conn.port)
  end

  def from_uri(uri) when is_binary(uri) do
    parsed = URI.parse(uri)
    origin(parsed.scheme, parsed.host, parsed.port)
  end

  defp origin(scheme, host, port) when is_binary(host) and is_integer(port) do
    %URI{scheme: to_string(scheme), host: String.downcase(host), port: port}
    |> URI.to_string()
    |> Auth.base_url()
  end

  defp origin(_, _, _), do: raise(ArgumentError, "Invalid request origin")

  defp forwarded_port(conn, default) do
    with [value] <- get_req_header(conn, "x-forwarded-port"),
         {port, ""} when port in 1..65_535 <- Integer.parse(value) do
      port
    else
      _ -> default
    end
  end
end
