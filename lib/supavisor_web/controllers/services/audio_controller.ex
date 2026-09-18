defmodule SupavisorWeb.Services.AudioController do
  use SupavisorWeb, :controller
  alias Supavisor.Services.Media

  def create(conn, %{"file" => %Plug.Upload{} = file}) do
    case Media.upload(file, conn.assigns.service_principal) do
      {:ok, audio} ->
        conn |> put_status(201) |> json(audio)

      {:error, error} ->
        conn
        |> put_status(if(error.code == "queue_full", do: 429, else: 422))
        |> json(%{error: error})
    end
  end

  def create(conn, _),
    do:
      conn
      |> put_status(422)
      |> json(%{
        error: %{code: "invalid_audio", message: "Use multipart/form-data with a file field."}
      })

  def show(conn, %{"id" => id}) do
    case Media.fetch(id, conn.assigns.service_principal) do
      {:ok, path, metadata} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_download({:file, path},
          filename: metadata["file"],
          content_type: MIME.from_path(path)
        )

      {:error, error} ->
        conn |> put_status(404) |> json(%{error: error})
    end
  end
end
