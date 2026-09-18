defmodule Supavisor.Services.Speech do
  @moduledoc """
  Speech entry points for the shared local ONNX runtime.

  Existing STT/TTS integrations can keep using this module. For AI graphs, use
  `Supavisor.Services.LocalModels` with `:ai_model` and files inside `priv/ai`.
  """

  alias Supavisor.Services.LocalModels

  defdelegate enabled?(), to: LocalModels
  defdelegate subscribe(), to: LocalModels

  def directory(service) when service in [:stt, :tts], do: LocalModels.directory(service)
  def catalog(service) when service in [:stt, :tts], do: LocalModels.catalog(service)
  def snapshot(service) when service in [:stt, :tts], do: LocalModels.snapshot(service)

  @doc "Load one graph by path relative to its service directory. Reuses an already loaded graph."
  def load(service, file) when service in [:stt, :tts],
    do: LocalModels.load(service, file)

  @doc "Run Nx inputs, loading the graph from disk if needed; returns {:ok, output_tuple}."
  def run(service, file, inputs) when service in [:stt, :tts],
    do: LocalModels.run(service, file, inputs)

  @doc "Release a graph's session. Refuses while a load or inference is in progress."
  def unload(service, file) when service in [:stt, :tts],
    do: LocalModels.unload(service, file)
end
