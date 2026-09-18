defmodule SupavisorWeb.AdminCap do
  @moduledoc "Rate-limited, same-origin Cap challenges for administrator sign-in."
  import Plug.Conn
  alias SupavisorWeb.AdminLoginLimiter

  def init(opts), do: opts

  def call(%{method: "POST", path_info: [action]} = conn, opts)
      when action in ["challenge", "redeem"] do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if AdminLoginLimiter.allow_cap?(conn.remote_ip) do
      PhoenixCap.Plug.call(conn, opts)
    else
      conn
      |> put_resp_header("retry-after", "60")
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        JSON.encode!(%{
          success: false,
          message: "Too many verification attempts. Try again in a minute."
        })
      )
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")

  def verify(conn, token) when is_binary(token) and byte_size(token) <= 2048,
    do: PhoenixCap.verify(conn, token)

  def verify(_conn, _token), do: {:error, :invalid_token}
end
