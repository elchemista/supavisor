defmodule Supavisor.Backups.UploadWriter do
  @behaviour Phoenix.LiveView.UploadWriter
  alias Supavisor.Backups

  @impl true
  def init(_) do
    directory = Path.join(Backups.root(), ".uploads")
    path = Path.join(directory, Ecto.UUID.generate())

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- Backups.storage_available(),
         {:ok, file} <- File.open(path, [:binary, :write, :exclusive]) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, %{path: path, file: file, bytes: 0, quota_check: 0}}

        {:error, reason} ->
          File.close(file)
          File.rm(path)
          {:error, reason}
      end
    end
  end

  @impl true
  def meta(state), do: %{path: state.path}
  @impl true
  def write_chunk(data, state) do
    bytes = state.bytes + byte_size(data)
    quota = if bytes - state.quota_check >= 8_388_608, do: Backups.storage_available(), else: :ok

    with true <- bytes <= Backups.max_bytes(),
         :ok <- quota,
         :ok <- IO.binwrite(state.file, data) do
      {:ok,
       %{
         state
         | bytes: bytes,
           quota_check:
             if(bytes - state.quota_check >= 8_388_608, do: bytes, else: state.quota_check)
       }}
    else
      _ -> {:error, :storage_limit, state}
    end
  end

  @impl true
  def close(state, reason) do
    File.close(state.file)
    if reason != :done, do: File.rm(state.path)
    {:ok, state}
  end
end
