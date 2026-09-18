defmodule SupavisorWeb.Services.AudioUploadAuth do
  @moduledoc "Reject unauthenticated audio uploads before Plug streams their body to disk."
  import Plug.Conn
  def init(opts), do: opts

  def call(%{method: "POST", path_info: ["api", "services", "v1", "audio"]} = conn, _) do
    conn = SupavisorWeb.Services.Auth.call(conn, [])

    cond do
      conn.halted ->
        conn

      Supavisor.ServiceAPI.KeyCache.allowed?(conn.assigns.service_principal, "stt:run") ->
        conn

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          403,
          Jason.encode!(%{error: %{code: "forbidden", message: "stt:run permission required."}})
        )
        |> halt()
    end
  end

  def call(conn, _), do: conn
end
