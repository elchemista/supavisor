defmodule Supavisor.Services.LocalModels.Catalog do
  @moduledoc false
  alias Supavisor.Services.LocalModels
  @max_entries 256
  @max_depth 6

  def list(service) do
    root = LocalModels.directory(service)

    case File.ls(root) do
      {:ok, entries} ->
        {files, _, truncated} = walk(root, "", entries, @max_entries, 0)
        {:ok, %{files: Enum.sort_by(files, & &1.path), truncated: truncated}}

      {:error, :enoent} ->
        {:ok, %{files: [], truncated: false}}

      {:error, _} ->
        {:error, "The model directory could not be read. Check its permissions."}
    end
  end

  def resolve(service, file) when is_binary(file) and byte_size(file) in 1..512 do
    parts = Path.split(file)

    if Path.type(file) == :relative and Path.extname(file) == ".onnx" and
         !String.contains?(file, <<0>>) and Enum.all?(parts, &(&1 not in [".", ".."])) do
      regular_path(LocalModels.directory(service), parts)
    else
      {:error, "Choose an ONNX file inside this service's model directory."}
    end
  end

  def resolve(_, _), do: {:error, "Choose an ONNX file from the local list."}

  # Check each component instead of following links into arbitrary directories.
  # The application priv directory itself may be Mix's build-time symlink.
  defp regular_path(base, [part | rest]) do
    path = Path.join(base, part)

    case {File.lstat(path), rest} do
      {{:ok, %{type: :regular, size: size}}, []} when size > 0 -> {:ok, path}
      {{:ok, %{type: :directory}}, [_ | _]} -> regular_path(path, rest)
      _ -> {:error, "Model file is missing, empty, unreadable or uses a symbolic link."}
    end
  end

  defp walk(root, relative, entries, budget, depth) do
    Enum.reduce_while(Enum.sort(entries), {[], budget, false}, fn entry,
                                                                  {files, left, truncated} ->
      if left == 0 do
        {:halt, {files, 0, true}}
      else
        path = Path.join(relative, entry)
        absolute = Path.join(root, path)

        case File.lstat(absolute) do
          {:ok, %{type: :regular, size: bytes}} ->
            row = %{id: Base.url_encode64(path, padding: false), path: path, bytes: bytes}
            files = [row | files]
            {:cont, {files, left - 1, truncated}}

          {:ok, %{type: :directory}} when depth < @max_depth ->
            case File.ls(absolute) do
              {:ok, children} ->
                {nested, remaining, limited} = walk(root, path, children, left - 1, depth + 1)
                {:cont, {nested ++ files, remaining, truncated or limited}}

              _ ->
                {:cont, {files, left - 1, true}}
            end

          {:ok, %{type: :directory}} ->
            {:cont, {files, left - 1, true}}

          _ ->
            {:cont, {files, left - 1, truncated}}
        end
      end
    end)
  end
end
