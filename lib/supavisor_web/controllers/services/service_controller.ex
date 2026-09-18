defmodule SupavisorWeb.Services.ServiceController do
  use SupavisorWeb, :controller
  alias Supavisor.Services.Dispatcher
  def status(conn, params), do: respond(conn, "gateway:status", params)
  def models(conn, params), do: respond(conn, "models:list", params)
  def embeddings(conn, params), do: respond(conn, "embedding:run", params, 202)
  def tts(conn, params), do: respond(conn, "tts:run", params, 202)
  def stt(conn, params), do: respond(conn, "stt:run", params, 202)
  def ai(conn, params), do: respond(conn, "ai:run", params, 202)
  def mailboxes(conn, params), do: respond(conn, "mailboxes:list", params)
  def messages(conn, params), do: respond(conn, "mail:list", params)
  def message(conn, params), do: respond(conn, "mail:get", params)
  def request(conn, params), do: respond(conn, "request:get", params)
  def cancel(conn, params), do: respond(conn, "request:cancel", params)

  def send_mail(conn, params) do
    params =
      case get_req_header(conn, "idempotency-key") do
        [key] -> Map.put(params, "idempotency_key", key)
        _ -> params
      end

    respond(conn, "mail:send", params, 202)
  end

  defp respond(conn, event, params, status \\ 200) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Dispatcher.call(conn.assigns.service_principal, event, params) do
      {:ok, result} -> conn |> put_status(status) |> json(result)
      {:error, error} -> conn |> put_status(error_status(error.code)) |> json(%{error: error})
    end
  end

  defp error_status("forbidden"), do: 403
  defp error_status("not_found"), do: 404

  defp error_status(code)
       when code in [
              "model_not_loaded",
              "model_not_active",
              "idempotency_conflict",
              "not_cancellable"
            ],
       do: 409

  defp error_status(code) when code in ["queue_full", "mailbox_full"], do: 429
  defp error_status("payload_too_large"), do: 413
  defp error_status("unavailable"), do: 503
  defp error_status(_), do: 422
end
