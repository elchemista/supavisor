# Local Qwen text generation

The AI model page manages Qwen3 0.6B INT8 as one model, with **Load model**,
**Release RAM**, file sizes/readiness, request state, and REST/WebSocket examples.
Keep `onnx/model_int8.onnx`, `tokenizer.json` and `config.json` under
`priv/ai/qwen3-0.6b-int8`, or the corresponding external `LOCAL_ONNX_MODEL_DIR/ai`
directory. Nothing downloads at startup.

`POST /api/services/v1/ai` and channel `ai:run` share the scoped `ai:run`
permission and the bounded CPU inference queue. Supply `messages` with
`system`, `user`, `assistant` roles, or a simple `input` string, plus optional
`max_tokens` (1–256, default 128). The model's non-thinking chat format is used.
Input is capped at 512 tokens. Greedy generation is used; no temperature,
tool calling or token streaming is implied. The WebSocket emits request state
and the completed result; it is not an OpenAI-compatible streaming API.

Inference runs in Elixir ONNX Runtime. The tokenizer uses the local Hugging Face
`tokenizer.json` through the Elixir `tokenizers` dependency. The attention cache
stays in native tensors during decoding and is discarded with the request.
There is a 180-second decoder budget checked between native calls.

Models load on first use and release their sessions after five idle minutes.
**Release RAM** is available when the queue is idle and keeps files on disk.
Request results live in bounded ETS for five minutes. Prompts/text are not saved
to PostgreSQL. Only aggregated counters appear in Metrics.

Qwen3 0.6B is a small quantized model; application-level response quality still
needs evaluation for the intended use. Source:
[onnx-community/Qwen3-0.6B-ONNX](https://huggingface.co/onnx-community/Qwen3-0.6B-ONNX),
revision `da1453100cf3ff33ef56d17983fc7a8648706db6`.
