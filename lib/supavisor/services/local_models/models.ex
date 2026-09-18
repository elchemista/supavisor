defmodule Supavisor.Services.LocalModels.Models do
  @moduledoc "Model bundles and the files required by their supported adapters."
  alias Supavisor.Services.LocalModels

  def definition(:tts),
    do: %{
      id: "kokoro",
      name: "Kokoro v1.0",
      directory: "kokoro",
      graphs: ["kokoro/kokoro-v1.0.onnx"],
      required: ["kokoro/kokoro-v1.0.onnx", "kokoro/voices-v1.0/if_sara.npy"],
      adapter: Supavisor.Services.LocalModels.Adapters.Kokoro
    }

  def definition(:stt),
    do: %{
      id: "whisper-it-distil-int8",
      name: "Whisper Italian · INT8",
      directory: "whisper-it-distil/onnx_int8",
      graphs: [
        "whisper-it-distil/onnx_int8/encoder_model.onnx",
        "whisper-it-distil/onnx_int8/decoder_model.onnx"
      ],
      required:
        Enum.map(
          ~w(encoder_model.onnx encoder_model.onnx.data decoder_model.onnx decoder_model.onnx.data tokenizer.json config.json generation_config.json preprocessor_config.json),
          &"whisper-it-distil/onnx_int8/#{&1}"
        ),
      adapter: Supavisor.Services.LocalModels.Adapters.Whisper
    }

  def definition(:ai_model),
    do: %{
      id: "qwen3-0.6b-int8",
      name: "Qwen3 0.6B · INT8",
      directory: "qwen3-0.6b-int8",
      graphs: ["qwen3-0.6b-int8/onnx/model_int8.onnx"],
      required:
        Enum.map(~w(onnx/model_int8.onnx tokenizer.json config.json), &"qwen3-0.6b-int8/#{&1}"),
      adapter: Supavisor.Services.LocalModels.Adapters.Qwen
    }

  def info(service) do
    model = definition(service)
    {:ok, catalog} = LocalModels.catalog(service)
    files = Enum.filter(catalog.files, &String.starts_with?(&1.path, model.directory <> "/"))
    present = MapSet.new(Enum.filter(files, &(&1.bytes > 0)), & &1.path)
    missing = Enum.reject(model.required, &MapSet.member?(present, &1))
    snapshot = LocalModels.snapshot(service)

    Map.merge(Map.drop(model, [:adapter]), %{
      files: files,
      missing: missing,
      ready: missing == [],
      bytes: Enum.sum(Enum.map(files, & &1.bytes)),
      loaded: Enum.all?(model.graphs, &Map.has_key?(snapshot.loaded, &1)),
      partial: Enum.any?(model.graphs, &Map.has_key?(snapshot.loaded, &1))
    })
  end

  def validate(service, params) do
    model = definition(service)

    with true <- params["model"] in [nil, model.id] || {:error, "Choose #{model.id}."},
         %{ready: true} <- info(service) do
      model.adapter.validate(params)
    else
      %{missing: missing} -> {:error, "Missing model files: " <> Enum.join(missing, ", ")}
      error -> error
    end
  end

  def path(service, relative) do
    root = LocalModels.directory(service)
    parts = Path.split(relative)

    if Path.type(relative) != :relative or Enum.any?(parts, &(&1 in [".", ".."])) do
      raise ArgumentError, "Invalid model asset"
    end

    Enum.reduce(parts, root, fn part, base ->
      path = Path.join(base, part)

      case File.lstat(path) do
        {:ok, %{type: type}} when type in [:directory, :regular] -> path
        _ -> raise ArgumentError, "Missing model asset"
      end
    end)
  end

  def scope(:ai_model), do: "ai:run"
  def scope(service), do: "#{service}:run"
end
