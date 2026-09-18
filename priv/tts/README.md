# Local TTS models

Place your text-to-speech export here, for example:

```text
priv/tts/kokoro/
  model.onnx
  voices.bin
  config.json
  ...other tokenizer, phonemizer and external weight files from your export
```

Keep the export's real filenames and relative paths. The dashboard discovers
`.onnx` graphs in nested folders; choose **Load graph** to allocate a CPU session.
Supporting files are for the future model adapter and are not automatically
interpreted by the graph loader. Nothing loads at boot.

Kokoro is normally a TTS model. Custom exports can use a different directory name.
This folder's contents, except this README, are ignored by Git and Docker builds.
See `docs/development/local-speech.md` for the Elixir API and current limits.
