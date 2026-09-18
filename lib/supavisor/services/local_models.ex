defmodule Supavisor.Services.LocalModels do
  @moduledoc """
  On-demand ONNX models for speech and text services. Model bundles load their
  sessions together and run through model-specific adapters. Native sessions
  are released after five idle minutes. REST and WebSocket share the bounded
  inference queue; no model is loaded at boot.
  """

  alias Supavisor.Services.LocalModels.{Catalog, Worker}
  @services [:stt, :tts, :ai_model]

  def enabled?, do: Application.get_env(:supavisor, __MODULE__, [])[:enabled] == true

  def relative_directory(:ai_model), do: "priv/ai"
  def relative_directory(service) when service in [:stt, :tts], do: "priv/#{service}"

  def directory(service) when service in @services do
    case Application.get_env(:supavisor, __MODULE__, [])[:directory] do
      nil -> Application.app_dir(:supavisor, relative_directory(service))
      root -> Path.join(root, Path.basename(relative_directory(service)))
    end
  end

  def directory_label(service) when service in @services do
    if Application.get_env(:supavisor, __MODULE__, [])[:directory],
      do: directory(service),
      else: relative_directory(service)
  end

  def catalog(service) when service in @services, do: Catalog.list(service)

  @doc "Load one graph by path relative to its service directory. Reuses an already loaded graph."
  def load(service, file) when service in @services,
    do: call(service, {:load, file})

  @doc "Run Nx inputs, loading the graph from disk if needed; returns {:ok, output_tuple}."
  def run(service, file, inputs) when service in @services,
    do: call(service, {:run, file, inputs})

  @doc "Release a graph's session. Refuses while a load or inference is in progress."
  def unload(service, file) when service in @services,
    do: call(service, {:unload, file})

  def load_model(service), do: call(service, {:bundle, :load, %{}})
  def unload_model(service), do: call(service, {:bundle, :unload, %{}})
  def infer(service, params), do: call(service, {:bundle, :infer, params})

  def snapshot(service) when service in @services, do: Worker.snapshot(service)
  def subscribe, do: Phoenix.PubSub.subscribe(Supavisor.PubSub, "admin:local_models")

  # Native inference cannot be forcibly cancelled safely. The worker retains its
  # busy slot until the native call finishes, even if a waiting caller goes away.
  defp call(service, message) do
    if enabled?() do
      GenServer.call(Worker.name(service), message, :infinity)
    else
      {:error, "Local ONNX runtime is disabled in this environment."}
    end
  catch
    :exit, _ -> {:error, "Local model worker is unavailable. Try again shortly."}
  end
end
