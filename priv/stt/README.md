# Local STT models

Place your speech-to-text export here, for example:

```text
priv/stt/whisper/
  encoder_model.onnx
  decoder_model.onnx
  decoder_with_past_model.onnx
  tokenizer.json
  preprocessor_config.json
  ...other files from your export
```

Use the graph names actually produced by your exporter. Some exports use a
single graph, others split the encoder and decoder. Keep external weight files
beside the graph that references them. The dashboard loads individual graphs;
it does not yet implement audio preprocessing, tokenization or the decoding loop.

Whisper is normally an STT model. Nothing loads at boot. This folder's contents,
except this README, are ignored by Git and Docker builds.
See `docs/development/local-speech.md` for the Elixir API and current limits.
