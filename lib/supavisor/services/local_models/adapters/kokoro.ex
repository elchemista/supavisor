defmodule Supavisor.Services.LocalModels.Adapters.Kokoro do
  @moduledoc false
  alias Supavisor.Services.LocalModels.{Models, Runtime}
  alias Supavisor.Services.LocalModels.Adapters.{Support, Audio}
  alias Supavisor.Services.Media

  @voices %{
    "if_sara" => "it",
    "im_nicola" => "it",
    "af_heart" => "en-us",
    "af_bella" => "en-us",
    "am_michael" => "en-us",
    "bf_emma" => "en-gb",
    "ff_siwis" => "fr-fr",
    "ef_dora" => "es",
    "em_alex" => "es",
    "pf_dora" => "pt-br"
  }
  def voices, do: @voices |> Map.keys() |> Enum.sort()

  def validate(params) do
    voice = params["voice"] || "if_sara"
    speed = params["speed"] || 1.0

    with :ok <- Support.text(params["input"], 1200),
         true <- Map.has_key?(@voices, voice) || {:error, "Choose an available voice."},
         true <-
           (is_number(speed) and speed >= 0.5 and speed <= 2.0) ||
             {:error, "Speed must be 0.5–2.0."} do
      {:ok, Map.take(params, ["input"]) |> Map.merge(%{"voice" => voice, "speed" => speed})}
    end
  end

  def run(entries, params) do
    Media.with_workspace(fn work ->
      voice = Models.path(:tts, "kokoro/voices-v1.0/#{params["voice"]}.npy")

      with {:ok, %{"tokens" => tokens}} <-
             Audio.prepare(%{
               operation: "phonemes",
               work: work,
               text: params["input"],
               language: @voices[params["voice"]],
               voice: voice,
               vocab: Application.app_dir(:supavisor, "priv/model-support/kokoro-vocab.json")
             }),
           style <-
             File.read!(Path.join(work, "style.f32"))
             |> Nx.from_binary(:f32)
             |> Nx.reshape({1, 256}),
           {:ok, {audio}} <-
             Runtime.run(
               entries["kokoro/kokoro-v1.0.onnx"].model,
               {Nx.tensor([[0 | tokens] ++ [0]], type: :s64), style,
                Nx.tensor([params["speed"]], type: :f32)}
             ),
           :ok <- File.write(Path.join(work, "audio.f32"), Nx.to_binary(audio)),
           {:ok, _} <- Audio.prepare(%{operation: "mp3", work: work}),
           {:ok, file} <- Media.store_output(Path.join(work, "audio.mp3"), params["owner"]) do
        {:ok, %{audio: file, voice: params["voice"], format: "mp3", sample_rate: 24000}}
      end
    end)
  rescue
    _ -> {:error, "Speech generation failed. Check the model files and audio dependencies."}
  end
end
