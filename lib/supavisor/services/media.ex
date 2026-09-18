defmodule Supavisor.Services.Media do
  @moduledoc "Private, expiring audio files. Metadata lives alongside files, never in PostgreSQL."
  use GenServer
  alias Supavisor.Services.Events
  alias Supavisor.ServiceAPI.KeyCache
  @max_bytes 25 * 1024 * 1024
  @quota 512 * 1024 * 1024
  @retention 3 * 24 * 60 * 60
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def root, do: Application.fetch_env!(:supavisor, __MODULE__)[:directory]
  def retention, do: @retention
  def max_bytes, do: @max_bytes

  def init(_) do
    for folder <- ["audio", "work", "uploads"] do
      File.mkdir_p!(Path.join(root(), folder))
      File.chmod!(Path.join(root(), folder), 0o700)
    end

    Process.send_after(self(), :expire_uploads, 30_000)
    {:ok, %{uploads: %{}}}
  end

  def start_upload(params, principal) do
    if KeyCache.allowed?(principal, "stt:run"),
      do: GenServer.call(__MODULE__, {:start_upload, params, KeyCache.owner(principal)}),
      else: Events.error("forbidden", "stt:run permission required.")
  end

  def chunk(id, offset, data, principal),
    do: GenServer.call(__MODULE__, {:chunk, id, offset, data, KeyCache.owner(principal)})

  def finish(id, principal),
    do: GenServer.call(__MODULE__, {:finish, id, KeyCache.owner(principal)})

  def abort(id, principal),
    do: GenServer.call(__MODULE__, {:abort, id, KeyCache.owner(principal)})

  def upload(%Plug.Upload{} = upload, principal) do
    with {:ok, %{size: size}} <- File.stat(upload.path),
         {:ok, %{id: id}} <-
           start_upload(%{"bytes" => size, "filename" => upload.filename}, principal) do
      result =
        File.stream!(upload.path, 48 * 1024)
        |> Enum.reduce_while({:ok, 0}, fn bytes, {:ok, offset} ->
          case chunk(id, offset, bytes, principal) do
            {:ok, %{offset: offset}} -> {:cont, {:ok, offset}}
            error -> {:halt, error}
          end
        end)

      case result do
        {:ok, _} ->
          finish(id, principal)

        error ->
          abort(id, principal)
          error
      end
    else
      {:error, %{code: _}} = error -> error
      _ -> Events.error("invalid_audio", "Could not read the uploaded audio file.")
    end
  end

  def store_output(path, owner), do: GenServer.call(__MODULE__, {:output, path, owner}, 30_000)

  def fetch(id, principal) do
    with {:ok, path, metadata} <- fetch_owned(id, KeyCache.owner(principal), nil),
         true <- KeyCache.allowed?(principal, metadata["scope"]) do
      {:ok, path, metadata}
    else
      _ -> Events.error("not_found", "Audio file not found or expired.")
    end
  end

  def fetch_owned(id, owner, scope) do
    with true <- Events.uuid?(id),
         directory <- Path.join([root(), "audio", id]),
         {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, json} <- File.read(Path.join(directory, "metadata.json")),
         {:ok, meta} <- Jason.decode(json),
         true <- meta["owner"] == owner and (is_nil(scope) or meta["scope"] == scope),
         true <- meta["expires_at"] > System.system_time(:second),
         true <-
           meta["file"] in [
             "audio.mp3",
             "input.mp3",
             "input.wav",
             "input.ogg",
             "input.flac",
             "input.webm",
             "input.m4a"
           ],
         path <- Path.join(directory, meta["file"]),
         {:ok, %{type: :regular}} <- File.lstat(path) do
      {:ok, path, meta}
    else
      _ -> Events.error("not_found", "Audio file not found or expired.")
    end
  end

  def with_workspace(fun) do
    path = Path.join([root(), "work", Ecto.UUID.generate()])
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)

    try do
      fun.(path)
    after
      File.rm_rf(path)
    end
  end

  def handle_call({:start_upload, params, owner}, _, state) do
    size = params["bytes"]

    extension =
      if is_binary(params["filename"]),
        do: params["filename"] |> Path.extname() |> String.downcase(),
        else: ""

    cond do
      !is_integer(size) or size not in 1..@max_bytes ->
        {:reply, Events.error("payload_too_large", "Upload 1–25 MiB of audio."), state}

      extension not in ~w(.mp3 .wav .ogg .flac .webm .m4a) ->
        {:reply, Events.error("invalid_audio", "Use MP3, WAV, OGG, FLAC, WebM or M4A audio."),
         state}

      map_size(state.uploads) >= 12 or
          Enum.count(state.uploads, fn {_, u} -> u.owner == owner end) >= 2 ->
        {:reply, Events.error("queue_full", "Too many pending uploads."), state}

      disk_bytes(root()) + Enum.sum(Enum.map(state.uploads, fn {_, u} -> u.size - u.offset end)) +
        size > @quota ->
        {:reply,
         Events.error(
           "queue_full",
           "Audio storage quota reached. Retry after expired files are cleaned."
         ), state}

      true ->
        id = Ecto.UUID.generate()
        path = Path.join([root(), "uploads", id])
        File.write!(path, "", [:exclusive])
        File.chmod!(path, 0o600)

        upload = %{
          path: path,
          owner: owner,
          size: size,
          offset: 0,
          extension: extension,
          touched: System.monotonic_time(:second)
        }

        {:reply, {:ok, %{id: id, chunk_bytes: 49_152, offset: 0}},
         put_in(state.uploads[id], upload)}
    end
  end

  def handle_call({:chunk, id, offset, bytes, owner}, _, state) do
    case state.uploads[id] do
      %{owner: ^owner, offset: ^offset} = upload
      when is_binary(bytes) and byte_size(bytes) in 1..49_152 ->
        if offset + byte_size(bytes) <= upload.size do
          :ok = File.write(upload.path, bytes, [:append])

          next = %{
            upload
            | offset: offset + byte_size(bytes),
              touched: System.monotonic_time(:second)
          }

          {:reply, {:ok, %{offset: next.offset}}, put_in(state.uploads[id], next)}
        else
          {:reply, Events.error("payload_too_large", "Chunk exceeds the declared audio size."),
           state}
        end

      _ ->
        {:reply,
         Events.error("invalid_upload", "Upload expired, chunk too large or offset incorrect."),
         state}
    end
  end

  def handle_call({:finish, id, owner}, _, state) do
    case state.uploads[id] do
      %{owner: ^owner, size: size, offset: size} = upload ->
        result = persist(id, upload.path, "input" <> upload.extension, owner, "stt:run")
        File.rm(upload.path)
        {:reply, result, %{state | uploads: Map.delete(state.uploads, id)}}

      _ ->
        {:reply, Events.error("invalid_upload", "Upload is incomplete or expired."), state}
    end
  end

  def handle_call({:abort, id, owner}, _, state) do
    case state.uploads[id] do
      %{owner: ^owner} = upload -> File.rm(upload.path)
      _ -> :ok
    end

    uploads = Map.reject(state.uploads, fn {key, value} -> key == id and value.owner == owner end)
    {:reply, :ok, %{state | uploads: uploads}}
  end

  def handle_call({:output, path, owner}, _, state) do
    result =
      if disk_bytes(root()) + File.stat!(path).size <= @quota,
        do: persist(Ecto.UUID.generate(), path, "audio.mp3", owner, "tts:run"),
        else: {:error, "Audio storage quota reached."}

    {:reply, result, state}
  end

  def handle_info(:expire_uploads, state) do
    Process.send_after(self(), :expire_uploads, 30_000)

    {expired, alive} =
      Enum.split_with(state.uploads, fn {_, u} ->
        System.monotonic_time(:second) - u.touched > 300
      end)

    Enum.each(expired, fn {_, u} -> File.rm(u.path) end)
    {:noreply, %{state | uploads: Map.new(alive)}}
  end

  defp persist(id, source, filename, owner, scope) do
    directory = Path.join([root(), "audio", id])
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    path = Path.join(directory, filename)
    File.cp!(source, path)
    File.chmod!(path, 0o600)

    metadata = %{
      id: id,
      owner: owner,
      scope: scope,
      file: filename,
      bytes: File.stat!(path).size,
      expires_at: System.system_time(:second) + @retention
    }

    File.write!(Path.join(directory, "metadata.json"), Jason.encode!(metadata))

    {:ok,
     %{
       id: id,
       bytes: metadata.bytes,
       expires_at: DateTime.from_unix!(metadata.expires_at),
       download_url: "/api/services/v1/audio/#{id}"
     }}
  end

  # Never follow symlinks or remove files outside this application's private root.
  def cleanup do
    cutoff = System.system_time(:second) - @retention

    for folder <- ~w(audio work uploads),
        entry <- entries(Path.join(root(), folder)),
        reduce: 0 do
      count ->
        path = Path.join([root(), folder, entry])

        case File.lstat(path, time: :posix) do
          {:ok, %{type: type, mtime: time}}
          when time < cutoff and type in [:regular, :directory] ->
            case File.rm_rf(path) do
              {:ok, _} -> count + 1
              _ -> count
            end

          _ ->
            count
        end
    end
  end

  defp entries(path) do
    case File.ls(path) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp disk_bytes(path) do
    Enum.reduce(entries(path), 0, fn name, sum ->
      child = Path.join(path, name)

      case File.lstat(child) do
        {:ok, %{type: :regular, size: size}} -> sum + size
        {:ok, %{type: :directory}} -> sum + disk_bytes(child)
        _ -> sum
      end
    end)
  end
end
