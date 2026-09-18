# Local AI models

## Qwen3 0.6B INT8

The local model is stored in `qwen3-0.6b-int8/`, using the CPU INT8 export from
[onnx-community/Qwen3-0.6B-ONNX](https://huggingface.co/onnx-community/Qwen3-0.6B-ONNX).
The graph is `qwen3-0.6b-int8/onnx/model_int8.onnx`. Model weights, tokenizer,
chat template and configuration occupy approximately 602 MiB on disk; this is
not a RAM estimate. The model folder contains the original license and a
`download-manifest.json` recording the pinned revision and verified file hashes.

In the local dashboard choose **AI model → Refresh files → Load graph**.
The Elixir loader accepts the same relative graph path. Files stay on disk when
the session is released after five idle minutes. The Qwen text-generation
adapter and public chat endpoints are not implemented yet.

## Other exports

Copy your Qwen ONNX export into a model folder here, for example:

```text
priv/ai/qwen/
  model.onnx
  tokenizer.json
  tokenizer_config.json
  config.json
  ...external weight files, generation configuration and other export assets
```

These names are illustrative. Keep your export's actual filenames and relative
layout, including nested `onnx/` folders and all external tensor data referenced
by the graph. No weights are downloaded or loaded automatically.

In the local dashboard open **AI model → Refresh files → Load graph** to load a
CPU session and inspect its input/output names, types and shapes. **Unload**
releases the session without deleting the export.

This is a graph runtime, not yet a Qwen chat server. The model-specific adapter
will handle tokenization, chat formatting, token-by-token decoding, any attention
cache and output decoding. REST/WebSocket text generation remains disabled.

Files in this folder, except this README, are ignored by Git and Docker builds.
See `docs/development/local-ai.md` for the Elixir API and memory limits.
