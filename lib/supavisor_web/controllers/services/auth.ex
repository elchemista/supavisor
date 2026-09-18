defmodule SupavisorWeb.Services.Auth do
  import Plug.Conn
  alias Supavisor.ServiceAPI.{KeyCache, RateLimiter}
  def init(opts), do: opts

  def call(%{assigns: %{service_principal: _}} = conn, _), do: conn

  def call(conn, _) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, principal} <- KeyCache.authenticate(token, "rest") do
      if RateLimiter.allow?(principal.id),
        do: assign(conn, :service_principal, principal),
        else: reject(conn, 429, "rate_limited", "120 requests per minute per API key.")
    else
      _ -> reject(conn, 401, "unauthorized", "A valid service API Bearer token is required.")
    end
  end

  defp reject(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message}}))
    |> halt()
  end
end
