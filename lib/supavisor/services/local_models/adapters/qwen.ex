defmodule Supavisor.Services.LocalModels.Adapters.Qwen do
  @moduledoc false
  alias Supavisor.Services.LocalModels.Models
  alias Supavisor.Services.LocalModels.Adapters.Support

  def validate(params) do
    messages = params["messages"] || [%{"role" => "user", "content" => params["input"]}]
    max_tokens = params["max_tokens"] || 128

    cond do
      !is_list(messages) or length(messages) not in 1..12 ->
        {:error, "Provide 1–12 messages."}

      !is_integer(max_tokens) or max_tokens not in 1..256 ->
        {:error, "max_tokens must be 1–256."}

      !Enum.all?(messages, fn m ->
        is_map(m) and m["role"] in ~w(system user assistant) and
            Support.text(m["content"], 6000) == :ok
      end) ->
        {:error, "Each message requires a valid role and UTF-8 content."}

      true ->
        {:ok,
         %{
           "messages" => Enum.map(messages, &Map.take(&1, ["role", "content"])),
           "max_tokens" => max_tokens
         }}
    end
  end

  def run(entries, params) do
    tokenizer = Support.tokenizer(:ai_model)
    # Qwen3's documented non-thinking chat template; no tools or hidden reasoning.
    prompt =
      Enum.map_join(params["messages"], "", fn m ->
        "<|im_start|>#{m["role"]}\n#{m["content"]}<|im_end|>\n"
      end) <> "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    input = Support.encode(tokenizer, prompt)

    if length(input) > 512 do
      {:error, "Conversation exceeds the 512-token input limit."}
    else
      model = entries[hd(Models.definition(:ai_model).graphs)].model
      cache = List.duplicate(Support.empty_cache(8, 128), 56)

      {tokens, reason} =
        decode(model, input, cache, 0, [], params["max_tokens"], Support.deadline())

      {:ok,
       %{
         model: Models.definition(:ai_model).id,
         text: Support.decode(tokenizer, tokens),
         finish_reason: reason,
         usage: %{prompt_tokens: length(input), completion_tokens: length(tokens)}
       }}
    end
  rescue
    _ -> {:error, "Text generation failed. Check the Qwen INT8 model and tokenizer files."}
  end

  defp decode(_, _, _, _, output, 0, _), do: {output, "length"}

  defp decode(model, ids, cache, position, output, remaining, deadline) do
    Support.check_deadline!(deadline)
    count = length(ids)

    inputs = [
      Nx.tensor([ids], type: :s64),
      Nx.broadcast(Nx.tensor(1, type: :s64), {1, position + count}),
      Nx.tensor([Enum.to_list(position..(position + count - 1))], type: :s64) | cache
    ]

    [logits | cache] = model |> OnnxRuntime.run(List.to_tuple(inputs)) |> Tuple.to_list()
    token = Support.last_token(logits)

    if token in [151_643, 151_645],
      do: {output, "stop"},
      else:
        decode(
          model,
          [token],
          cache,
          position + count,
          output ++ [token],
          remaining - 1,
          deadline
        )
  end
end
