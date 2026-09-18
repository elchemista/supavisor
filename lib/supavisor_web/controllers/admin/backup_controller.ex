defmodule SupavisorWeb.Admin.BackupController do
  use SupavisorWeb, :controller

  def download(conn, %{"id" => id, "kind" => kind}) do
    case Supavisor.Backups.download(id, kind, conn.assigns.current_admin_email) do
      {:ok, path, filename} ->
        conn
        |> put_resp_header("cache-control", "no-store, private")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_download({:file, path},
          filename: filename,
          content_type:
            if(String.ends_with?(filename, ".zip"),
              do: "application/zip",
              else: "application/octet-stream"
            )
        )

      _ ->
        conn |> put_status(:not_found) |> text("Backup file not found on this server.")
    end
  end
end
