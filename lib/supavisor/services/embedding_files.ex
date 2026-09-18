defmodule Supavisor.Services.EmbeddingFiles do
  @moduledoc "Embedding variant sizes and repository cache lifecycle; no database storage."
  @ttl 21_600

  def load_metadata do
    with {:ok, json} <- File.read(metadata_path()),
         {:ok, data} when is_map(data) <- Jason.decode(json) do
      data
    else
      _ -> %{}
    end
  end

  def refresh_metadata(models, metadata) do
    groups = Enum.group_by(models, &{&1.repository, revision(&1.repository)})
    now = System.system_time(:second)

    result =
      Task.async_stream(
        groups,
        fn {{repository, revision}, variants} ->
          key = repository <> "@" <> revision
          previous = metadata[key]
          files = variants |> Enum.flat_map(& &1.files) |> Enum.uniq()

          if fresh?(previous, now) do
            {key, previous}
          else
            case remote_sizes(repository, revision, files) do
              {:ok, sizes, commit} ->
                {key, %{"files" => sizes, "revision" => commit, "checked_at" => now}}

              _ ->
                {key, previous}
            end
          end
        end,
        max_concurrency: 4,
        timeout: 20_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {key, value}}, acc when is_map(value) -> Map.put(acc, key, value)
        _, acc -> acc
      end)

    # Only the catalog's current revisions are retained; no unbounded history.
    path = metadata_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", Jason.encode!(result)),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok

    result
  end

  def enrich(models, metadata) do
    repositories =
      models
      |> Enum.map(& &1.repository)
      |> Enum.uniq()
      |> Map.new(&{&1, local_info(&1)})

    Enum.map(models, fn model ->
      local = repositories[model.repository]
      sizes = metadata[model.repository <> "@" <> local.revision]
      variant_bytes = sum_files(model.files, local.files)
      remote_bytes = sizes && sum_files(model.files, sizes["files"])

      Map.merge(model, %{
        download_bytes: remote_bytes || variant_bytes,
        variant_bytes: variant_bytes,
        disk_bytes: local.disk_bytes,
        sizes_checked_at: sizes && sizes["checked_at"],
        sizes_stale: is_map(sizes) and not fresh?(sizes, System.system_time(:second))
      })
    end)
  end

  def delete_repository(repository) do
    with {:ok, path} <- repository_path(repository) do
      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, %{repository: repository}}

        {:ok, %{type: :directory}} ->
          case File.rm_rf(path) do
            {:ok, _} ->
              {:ok, %{repository: repository}}

            _ ->
              {:error,
               "Some cached files could not be removed. Check directory permissions and retry."}
          end

        _ ->
          {:error, "The model cache is not a regular directory. No files were removed."}
      end
    end
  end

  defp local_info(repository) do
    rev = revision(repository)

    with {:ok, root} <- repository_path(repository),
         {:ok, %{type: :directory}} <- File.lstat(root) do
      snapshot = Path.join([root, "snapshots", rev])
      %{revision: rev, disk_bytes: disk_bytes(root), files: snapshot_files(snapshot)}
    else
      _ -> %{revision: rev, disk_bytes: 0, files: %{}}
    end
  end

  defp snapshot_files(directory, prefix \\ "") do
    case File.ls(directory) do
      {:ok, entries} ->
        Enum.reduce(entries, %{}, fn entry, acc ->
          path = Path.join(directory, entry)
          key = prefix <> entry

          case File.lstat(path) do
            {:ok, %{type: :directory}} ->
              Map.merge(acc, snapshot_files(path, key <> "/"))

            {:ok, %{type: type}} when type in [:regular, :symlink] ->
              case File.stat(path) do
                {:ok, %{type: :regular, size: bytes}} -> Map.put(acc, key, bytes)
                _ -> acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  # Snapshot pointers are symlinks into blobs; count the stored blob only once.
  defp disk_bytes(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: bytes}} ->
        bytes

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> Enum.reduce(entries, 0, &(disk_bytes(Path.join(path, &1)) + &2))
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp revision(repository) do
    with {:ok, root} <- repository_path(repository),
         {:ok, value} <- File.read(Path.join(root, "refs/main")),
         value = String.trim(value),
         true <- Regex.match?(~r/\A[0-9a-f]{40,64}\z/, value),
         do: value,
         else: (_ -> "main")
  end

  defp repository_path(repository) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/, repository) do
      {:ok,
       Path.join(
         Path.expand(ExFastembed.cache_directory()),
         "models--" <> String.replace(repository, "/", "--")
       )}
    else
      {:error, "Invalid model repository."}
    end
  end

  defp sum_files(files, sizes) when is_map(sizes) do
    values = Enum.map(files, &Map.get(sizes, &1))
    if Enum.all?(values, &(is_integer(&1) and &1 > 0)), do: Enum.sum(values), else: nil
  end

  defp sum_files(_, _), do: nil

  defp remote_sizes(repository, revision, files) do
    # Read only public metadata from a fixed HTTPS origin; never download weights.
    url = "https://huggingface.co/api/models/#{repository}/revision/#{revision}?blobs=true"

    with {:ok, %{status: 200, body: %{"siblings" => siblings, "sha" => commit}}} <-
           metadata_request(url, 2) do
      sizes =
        for %{"rfilename" => file, "size" => size} <- siblings,
            file in files and is_integer(size),
            into: %{},
            do: {file, size}

      {:ok, sizes, commit}
    else
      _ -> {:error, :unavailable}
    end
  end

  # The Hub redirects renamed/case-normalized repositories. Keep those requests
  # on the same public metadata origin, with a bounded number of redirects.
  defp metadata_request(url, redirects) do
    case Req.get(url,
           redirect: false,
           retry: false,
           connect_options: [timeout: 5_000],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status} = response}
      when status in [301, 302, 303, 307, 308] and redirects > 0 ->
        with [location | _] <- Req.Response.get_header(response, "location"),
             %URI{scheme: "https", host: "huggingface.co", port: 443, userinfo: nil} = target <-
               URI.merge(url, location) do
          metadata_request(URI.to_string(target), redirects - 1)
        else
          _ -> {:error, :unavailable}
        end

      result ->
        result
    end
  end

  defp fresh?(%{"checked_at" => checked_at}, now) when is_integer(checked_at),
    do: now >= checked_at and now - checked_at < @ttl

  defp fresh?(_, _), do: false

  defp metadata_path do
    Application.fetch_env!(:supavisor, :service_mail_key_dir)
    |> Path.dirname()
    |> Path.join("embedding-sizes.json")
  end
end
