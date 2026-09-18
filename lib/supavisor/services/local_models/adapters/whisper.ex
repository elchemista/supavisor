defmodule Supavisor.Services.LocalModels.Adapters.Whisper do
  @moduledoc false
  alias Supavisor.Services.LocalModels.Models
  alias Supavisor.Services.LocalModels.Adapters.{Support, Audio}
  alias Supavisor.Services.Media

  def validate(%{"audio_id" => id}) do
    if Supavisor.Services.Events.uuid?(id),
      do: {:ok, %{"audio_id" => id}},
      else: {:error, "Upload audio first and supply its audio_id."}
  end

  def validate(_),
    do: {:error, "Upload audio first and supply its audio_id (maximum 30 seconds)."}

  def run(entries, params) do
    Media.with_workspace(fn work ->
      with {:ok, path, _} <- Media.fetch_owned(params["audio_id"], params["owner"], "stt:run"),
           {:ok, audio} <- Audio.prepare(%{operation: "mel", input: path, work: work}) do
        tokenizer = Support.tokenizer(:stt)
        base = Models.definition(:stt).directory

        features =
          File.read!(Path.join(work, "mel.f32"))
          |> Nx.from_binary(:f32)
          |> Nx.reshape({1, 128, 3000})

        {hidden} = OnnxRuntime.run(entries[base <> "/encoder_model.onnx"].model, features)

        config =
          Models.path(:stt, base <> "/generation_config.json") |> File.read!() |> Jason.decode!()

        prefix = [
          50258,
          config["lang_to_id"]["<|it|>"],
          config["task_to_id"]["transcribe"],
          config["no_timestamps_token_id"]
        ]

        tokens =
          decode(
            entries[base <> "/decoder_model.onnx"].model,
            hidden,
            prefix,
            [],
            config["suppress_tokens"] || [],
            Support.deadline()
          )

        {:ok,
         %{
           text: Support.decode(tokenizer, tokens),
           language: "it",
           duration_seconds: audio["duration_seconds"],
           model: Models.definition(:stt).id
         }}
      end
    end)
  rescue
    _ -> {:error, "Transcription failed. Check the Whisper INT8 model and audio format."}
  end

  defp decode(_, _, _, output, _, _) when length(output) >= 256, do: output

  defp decode(model, hidden, prefix, output, suppressed, deadline) do
    Support.check_deadline!(deadline)
    {logits} = OnnxRuntime.run(model, {Nx.tensor([prefix ++ output], type: :s64), hidden})
    # No timestamps are requested; prevent timestamp IDs during decoding.
    token = Support.last_token(logits, suppressed ++ Enum.to_list(50365..51865))

    if token == 50257,
      do: output,
      else: decode(model, hidden, prefix, output ++ [token], suppressed, deadline)
  end
end
