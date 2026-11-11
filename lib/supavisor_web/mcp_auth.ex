defmodule SupavisorWeb.MCPAuth do
  @moduledoc false
  import Plug.Conn
  alias Supavisor.MCP.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, grant} <- Auth.authorize(token, conn.assigns.mcp_resource) do
      assign(conn, :mcp_grant, grant)
    else
      _ ->
        conn
        |> put_resp_header(
          "www-authenticate",
          ~s(Bearer resource_metadata="#{conn.assigns.mcp_origin}/.well-known/oauth-protected-resource/mcp", scope="#{Enum.join(Auth.scopes(), " ")}")
        )
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "invalid_token"}))
        |> halt()
    end
  end
end
