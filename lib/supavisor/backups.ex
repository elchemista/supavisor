defmodule Supavisor.Backups do
  @moduledoc "Database export and transactional restore. Payloads stay on private local disk."
  import Ecto.Query
  alias Supavisor.Repo
  alias Supavisor.Backups.{Job, Worker}
  alias SupavisorWeb.AdminProvisioning
  @topic "admin:backups"

  def config, do: Application.fetch_env!(:supavisor, __MODULE__)
  def root, do: Keyword.fetch!(config(), :directory)
  def node_id, do: Keyword.fetch!(config(), :node_id)
  def max_bytes, do: Keyword.fetch!(config(), :max_bytes)
  def subscribe, do: Phoenix.PubSub.subscribe(Supavisor.PubSub, @topic)
  def changed, do: Phoenix.PubSub.broadcast(Supavisor.PubSub, @topic, :backups_changed)
  def job_dir(id), do: Path.join(root(), id)

  def targets,
    do:
      Enum.map(AdminProvisioning.allowed_targets(), fn
        {host, port} -> {to_string(host), port}
        %{host: host, port: port} -> {to_string(host), port}
      end)

  def tools do
    for name <- ~w(pg_dump pg_restore service_runner), into: %{} do
      path =
        if name == "service_runner" do
          executable = Application.app_dir(:supavisor, "priv/native/service_runner")
          if File.regular?(executable), do: executable
        else
          pg_executable(name)
        end

      {name, path}
    end
  end

  def pg_executable(name) do
    case config()[:pg_bin] do
      nil ->
        System.find_executable(name)

      "" ->
        System.find_executable(name)

      directory ->
        path = Path.join(directory, name)
        if File.regular?(path), do: path
    end
  end

  def ready?, do: Enum.all?(tools(), fn {_, path} -> is_binary(path) end)
  def admin?(email), do: email in SupavisorWeb.AdminSettings.uncached_admin_emails()
  def protected_database?(database), do: database == Repo.config()[:database]

  def target_info(host, port, database)
      when is_binary(database) and byte_size(database) in 1..63 do
    AdminProvisioning.with_connection(host, port, fn conn ->
      case Postgrex.query(
             conn,
             "SELECT pg_get_userbyid(datdba), current_setting('server_version') FROM pg_database WHERE datname = $1 AND NOT datistemplate AND datallowconn",
             [database]
           ) do
        {:ok, %{rows: [[owner, version]]}} -> {:ok, %{owner: owner, version: version}}
        _ -> {:error, "Database unavailable on this configured server."}
      end
    end)
    |> normalize_target_error()
  end

  def target_info(_, _, _), do: {:error, "Invalid database name."}
  defp normalize_target_error({:ok, _} = result), do: result
  defp normalize_target_error({:error, error}) when is_binary(error), do: {:error, error}

  defp normalize_target_error(_),
    do: {:error, "Cannot connect to the configured PostgreSQL server."}

  def list(host, port, database) do
    Repo.all(
      from j in Job,
        where:
          j.node_id == ^node_id() and j.host == ^host and j.port == ^port and
            j.database == ^database,
        order_by: [desc: j.inserted_at],
        limit: 100
    )
  end

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from j in Job, where: j.id == ^id and j.node_id == ^node_id())
      _ -> nil
    end
  end

  def enqueue(attrs, actor, upload \\ nil),
    do: GenServer.call(Worker, {:enqueue, attrs, actor, upload}, 15_000)

  def cancel(id, actor), do: GenServer.call(Worker, {:cancel, id, actor})
  def delete(id, actor), do: GenServer.call(Worker, {:delete, id, actor})

  # Only the coordinator admits jobs, so queue and storage limits cannot race
  # between concurrent LiveView sessions on this node.
  def admit(attrs, actor, upload) do
    with true <- admin?(actor) || {:error, "Administrator access revoked."},
         true <-
           ready?() ||
             {:error, "Install PostgreSQL client tools and build the native backup worker."},
         true <- attrs.operation in ["export", "import"] || {:error, "Invalid operation."},
         true <-
           attrs.format in ["dump", "zip"] || {:error, "Use a PostgreSQL dump or ZIP archive."},
         true <-
           attrs.operation != "import" || !protected_database?(attrs.database) ||
             {:error,
              "Restore the console’s metadata database offline. Export is available here."},
         true <-
           attrs.operation != "import" || attrs[:confirmation] == attrs.database ||
             {:error, "Type the exact destination database name."},
         true <-
           attrs[:restore_mode] in [nil, "add", "replace"] || {:error, "Invalid restore mode."},
         true <-
           attrs[:ownership] in [nil, "preserve", "target"] ||
             {:error, "Invalid ownership option."},
         true <-
           Repo.aggregate(from(j in Job, where: j.node_id == ^node_id()), :count) < 100 ||
             {:error, "Remove old backup jobs before creating more (limit: 100)."},
         true <-
           Repo.aggregate(
             from(j in Job, where: j.node_id == ^node_id() and j.status in ["queued", "running"]),
             :count
           ) < 5 || {:error, "The backup queue is full. Wait for an operation to finish."},
         {:ok, _} <- target_info(attrs.host, attrs.port, attrs.database),
         :ok <- storage_available(),
         :ok <- valid_upload(attrs.operation, upload) do
      id = Ecto.UUID.generate()
      dir = job_dir(id)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700),
           :ok <- move_upload(upload, dir) do
        fields =
          Map.take(attrs, [
            :host,
            :port,
            :database,
            :operation,
            :format,
            :restore_mode,
            :ownership
          ])

        filename =
          String.replace(attrs.database, ~r/[^a-zA-Z0-9_-]/u, "_") <>
            "-" <> Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ") <> "." <> attrs.format

        job =
          struct(
            Job,
            Map.merge(fields, %{id: id, node_id: node_id(), created_by: actor, filename: filename})
          )

        persist_job(job, upload, dir)
      else
        _ ->
          File.rm_rf(dir)
          {:error, "Could not store the upload. Check backup directory permissions."}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Could not start this operation."}
    end
  rescue
    _ ->
      {:error, "Could not start the backup operation. Check storage and database availability."}
  end

  defp persist_job(job, upload, dir) do
    case Repo.insert(job) do
      {:ok, job} ->
        changed()
        {:ok, job}

      _ ->
        recover_upload(upload, dir)
        {:error, "Could not save the backup job."}
    end
  rescue
    _ ->
      recover_upload(upload, dir)
      {:error, "Could not save the backup job. Check database availability."}
  end

  defp recover_upload(upload, dir) do
    # Keep a completed upload available to retry if saving metadata failed.
    if upload, do: File.rename(Path.join(dir, "upload"), upload)
    File.rm_rf(dir)
  end

  defp valid_upload("export", nil), do: :ok

  defp valid_upload("import", path) when is_binary(path) do
    with true <- Path.dirname(path) == Path.join(root(), ".uploads"),
         {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size > 0 and size <= max_bytes() do
      :ok
    else
      _ -> {:error, "Upload a complete backup within the configured size limit."}
    end
  end

  defp valid_upload(_, _), do: {:error, "Select a backup file first."}
  defp move_upload(nil, _), do: :ok
  defp move_upload(path, dir), do: File.rename(path, Path.join(dir, "upload"))

  def storage_available do
    total = disk_bytes(root())

    if total < config()[:quota_bytes],
      do: :ok,
      else: {:error, "Backup storage quota reached. Download and remove older backups."}
  end

  def disk_bytes(path) do
    # The configured root may itself be a mount symlink; never follow nested links.
    info = if path == root(), do: File.stat(path), else: File.lstat(path)

    case info do
      {:ok, %{type: :regular, size: size}} ->
        size

      {:ok, %{type: :directory}} ->
        File.ls!(path)
        |> Enum.reduce(0, fn name, bytes -> bytes + disk_bytes(Path.join(path, name)) end)

      _ ->
        0
    end
  end

  def download(id, kind, actor) do
    with true <- admin?(actor),
         %Job{} = job <- get(id),
         true <- job.status not in ["queued", "running"],
         {:ok, path, filename} <- artifact(job, kind),
         {:ok, %{type: :regular, size: size}} when size > 0 <- File.lstat(path) do
      {:ok, path, filename}
    else
      _ -> {:error, :not_found}
    end
  end

  defp artifact(%{operation: "export", status: "completed"} = job, "export"),
    do: {:ok, Path.join(job_dir(job.id), "export." <> job.format), job.filename}

  defp artifact(%{operation: "import", safety_bytes: size} = job, "safety") when size > 0,
    do:
      {:ok, Path.join(job_dir(job.id), "safety.dump"),
       Path.rootname(job.filename) <> "-before-restore.dump"}

  defp artifact(_, _), do: {:error, :not_found}

  def update(job, fields) do
    case job |> Ecto.Changeset.change(fields) |> Repo.update() do
      {:ok, updated} ->
        changed()
        {:ok, updated}

      error ->
        error
    end
  end
end
