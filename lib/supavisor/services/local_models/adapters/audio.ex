defmodule Supavisor.Services.LocalModels.Adapters.Audio do
  @moduledoc "Audio preparation in Elixir and Rust; external tools only handle codecs and phonemes."
  alias Supavisor.Services.LocalModels.AudioDSP

  def prepare(%{operation: "mel", input: input, work: work}) do
    pcm = Path.join(work, "input.f32")

    with :ok <-
           command("ffmpeg", [
             "-nostdin",
             "-v",
             "error",
             "-threads",
             "1",
             "-y",
             "-protocol_whitelist",
             "file,pipe",
             "-format_whitelist",
             "mp3,wav,ogg,flac,matroska,webm,mov,aac",
             "-i",
             input,
             "-t",
             "30.1",
             "-vn",
             "-ac",
             "1",
             "-ar",
             "16000",
             "-f",
             "f32le",
             pcm
           ]),
         {:ok, %{size: bytes}} when bytes in 4..1_920_000 <- File.stat(pcm),
         {:ok, raw} <- File.read(pcm),
         {:ok, features} <- AudioDSP.whisper_mel(raw),
         :ok <- File.write(Path.join(work, "mel.f32"), features) do
      {:ok, %{"duration_seconds" => bytes / 64_000}}
    else
      {:ok, %{size: _}} ->
        {:error, "Audio must be between 0 and 30 seconds. Split longer recordings."}

      {:error, message} when is_binary(message) ->
        {:error, message}

      _ ->
        {:error, "Could not prepare the audio recording."}
    end
  end

  def prepare(%{
        operation: "phonemes",
        work: work,
        text: text,
        language: language,
        voice: voice,
        vocab: vocab
      }) do
    source = Path.join(work, "text.txt")
    phonemes_path = Path.join(work, "phonemes.txt")

    with :ok <- File.write(source, text),
         :ok <-
           command("espeak-ng", [
             "-q",
             "--ipa=3",
             "-v",
             language,
             "-f",
             source,
             "--phonout=" <> phonemes_path
           ]),
         {:ok, phonemes} <- File.read(phonemes_path),
         {:ok, dictionary} <- Jason.decode(File.read!(vocab)) do
      tokens =
        phonemes
        |> String.split()
        |> Enum.join(" ")
        |> String.codepoints()
        |> Enum.flat_map(fn c ->
          case Map.fetch(dictionary, c) do
            {:ok, id} -> [id]
            _ -> []
          end
        end)

      if length(tokens) in 1..510 do
        with {:ok, style} <- read_voice(voice, length(tokens)),
             :ok <- File.write(Path.join(work, "style.f32"), style),
             do: {:ok, %{"tokens" => tokens}}
      else
        {:error,
         "Text must produce 1–510 speech sounds. Split longer text into shorter sentences."}
      end
    end
  end

  def prepare(%{operation: "mp3", work: work}) do
    output = Path.join(work, "audio.mp3")

    with :ok <-
           command("ffmpeg", [
             "-nostdin",
             "-v",
             "error",
             "-threads",
             "1",
             "-y",
             "-f",
             "f32le",
             "-ar",
             "24000",
             "-ac",
             "1",
             "-i",
             Path.join(work, "audio.f32"),
             "-vn",
             "-c:a",
             "libmp3lame",
             "-b:a",
             "128k",
             "-map_metadata",
             "-1",
             output
           ]) do
      {:ok, %{"content_type" => "audio/mpeg", "bytes" => File.stat!(output).size}}
    end
  end

  # Read only the selected 1x256 float32 voice vector. NPY headers are parsed as
  # constrained text, never evaluated, and object/pickled arrays are rejected.
  defp read_voice(path, length) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        {:ok, <<147, "NUMPY", major, 0, rest::binary>>} = :file.pread(file, 0, 12)

        {header_size, offset} =
          case {major, rest} do
            {1, <<size::little-16, _::binary>>} -> {size, 10}
            {2, <<size::little-32>>} -> {size, 12}
          end

        true = header_size <= 4096
        {:ok, header} = :file.pread(file, offset, header_size)
        true = Regex.match?(~r/'descr':\s*'<f4'/, header)
        true = Regex.match?(~r/'fortran_order':\s*False/, header)
        [_, rows] = Regex.run(~r/'shape':\s*\((\d+),\s*1,\s*256\)/, header)
        count = String.to_integer(rows)
        true = count in 1..512

        {:ok, style} =
          :file.pread(file, offset + header_size + (min(count, length) - 1) * 1024, 1024)

        true = byte_size(style) == 1024
        {:ok, style}
      rescue
        _ -> {:error, "Invalid voice file. Expected a float32 NPY voice array."}
      after
        :file.close(file)
      end
    end
  end

  defp command(name, arguments) do
    with executable when is_binary(executable) <- System.find_executable(name),
         timeout when is_binary(timeout) <- System.find_executable("timeout") do
      # The child receives fixed argv, never shell code. GNU timeout also bounds
      # a stuck codec when its Elixir caller terminates unexpectedly.
      case System.cmd(timeout, ["--signal=TERM", "--kill-after=2", "45s", executable | arguments],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        _ -> {:error, "Audio conversion failed. Check the input audio and #{name} installation."}
      end
    else
      _ -> {:error, "Required audio executable #{name} or timeout is unavailable."}
    end
  end
end
