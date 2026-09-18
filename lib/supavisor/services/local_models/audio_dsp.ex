defmodule Supavisor.Services.LocalModels.AudioDSP do
  @moduledoc false
  use Rustler, otp_app: :supavisor, crate: "audio_dsp"
  def whisper_mel(_pcm), do: :erlang.nif_error(:nif_not_loaded)
end
