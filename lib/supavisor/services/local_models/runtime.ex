defmodule Supavisor.Services.LocalModels.Runtime do
  @moduledoc false

  # Keep dependency-specific calls here, including the metadata API, while the
  # ONNX binding is pinned to its current release candidate.
  def load(path) do
    model = OnnxRuntime.load(path, [:cpu])
    {inputs, outputs} = OnnxRuntime.Native.show_session(model.reference)
    {:ok, %{model: model, inputs: inputs, outputs: outputs}}
  rescue
    error -> {:error, "ONNX load failed: " <> safe_message(error)}
  end

  def run(model, inputs) do
    outputs = OnnxRuntime.run(model, inputs)

    # Return ordinary tensors; no native output resource or audio is retained
    # by the worker, ETS, database or a dashboard assign.
    {:ok,
     outputs
     |> Tuple.to_list()
     |> Enum.map(&Nx.backend_transfer(&1, Nx.BinaryBackend))
     |> List.to_tuple()}
  rescue
    error -> {:error, "ONNX inference failed: " <> safe_message(error)}
  end

  defp safe_message(error), do: error |> Exception.message() |> String.slice(0, 300)
end
