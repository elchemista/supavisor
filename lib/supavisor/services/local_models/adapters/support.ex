defmodule Supavisor.Services.LocalModels.Adapters.Support do
  @moduledoc false
  alias Supavisor.Services.LocalModels.Models

  def text(value, max) when is_binary(value) do
    if String.valid?(value) and byte_size(String.trim(value)) in 1..max,
      do: :ok,
      else: {:error, "Text must contain 1–#{max} UTF-8 bytes."}
  end

  def text(_, max), do: {:error, "Text must contain 1–#{max} UTF-8 bytes."}

  def tokenizer(service) do
    path = Models.path(service, Models.definition(service).directory <> "/tokenizer.json")
    {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(path)
    tokenizer
  end

  def encode(tokenizer, text) do
    {:ok, encoding} = Tokenizers.Tokenizer.encode(tokenizer, text, add_special_tokens: false)
    Tokenizers.Encoding.get_ids(encoding)
  end

  def decode(tokenizer, tokens) do
    {:ok, text} = Tokenizers.Tokenizer.decode(tokenizer, tokens, skip_special_tokens: true)
    text
  end

  # Cache tensors stay in ONNX Runtime between decoder steps. In particular the
  # initial zero-length cache cannot be represented by ordinary Nx constructors.
  def empty_cache(heads, dimensions) do
    ref = OnnxRuntime.Native.from_binary(<<>>, [1, heads, 0, dimensions], {:f, 32})

    %Nx.Tensor{
      shape: {1, heads, 0, dimensions},
      type: {:f, 32},
      names: [nil, nil, nil, nil],
      data: %OnnxRuntime.Backend{ref: ref}
    }
  end

  def last_token(logits, suppressed \\ []) do
    {_, count, size} = logits.shape

    last =
      Nx.slice(logits, [0, count - 1, 0], [1, 1, size])
      |> Nx.backend_transfer(Nx.BinaryBackend)
      |> Nx.reshape({size})

    if suppressed == [] do
      last |> Nx.argmax() |> Nx.to_number()
    else
      blocked = MapSet.new(suppressed)

      last
      |> Nx.to_flat_list()
      |> Enum.with_index()
      |> Enum.reject(fn {_, i} -> MapSet.member?(blocked, i) end)
      |> Enum.max_by(&elem(&1, 0))
      |> elem(1)
    end
  end

  def deadline, do: System.monotonic_time(:second) + 180

  def check_deadline!(deadline) do
    if System.monotonic_time(:second) > deadline, do: raise("Model request exceeded 180 seconds")
  end
end
