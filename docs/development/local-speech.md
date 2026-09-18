# Speech models: REST, WebSocket and private MP3 files

The STT and TTS pages manage complete models: **Load model**, **Release RAM**,
file readiness and sizes, the request queue, and working REST/WebSocket examples.
Model sessions load on the first request and unload after five idle minutes.
No weights load at startup. Model files remain on disk.

## Supported exports

- TTS: Kokoro v1.0, `tts/kokoro/kokoro-v1.0.onnx`, with the NPY voices in
  `tts/kokoro/voices-v1.0/`. Default voice: `if_sara` (Italian). The dashboard
  lists supported voices. eSpeak NG produces phonemes; Elixir ONNX Runtime runs
  inference. The small vocabulary under `priv/model-support` comes from the
  [Kokoro model configuration](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/config.json).
- STT: the Italian distilled Whisper INT8 encoder and decoder, their external
  `.onnx.data` files, tokenizer, and configuration in
  `stt/whisper-it-distil/onnx_int8/`. FP32 is not needed. It transcribes Italian
  clips up to 30 seconds. Split longer recordings before uploading.

Set `LOCAL_ONNX_ENABLED=true` and optionally `LOCAL_ONNX_MODEL_DIR` to the
absolute directory containing `tts/`, `stt/` and `ai/`. Otherwise `priv` is used.

System packages on Ubuntu/Debian:

```sh
sudo apt-get install --no-install-recommends ffmpeg espeak-ng
```

Audio preparation runs in Elixir and a bounded Rust NIF. The Rust frontend
computes Whisper's spectrogram on a dirty scheduler; Elixir reads the NPY voice
vectors without evaluating headers. The application does not invoke Python or
require NumPy. ONNX inference remains in the Elixir library. FFmpeg and eSpeak NG
receive fixed argument lists and a 45-second process timeout.

## Authentication and API

Create a key in **API** with `tts:run` and/or `stt:run`, choosing REST and/or
WebSocket. Existing keys keep their existing scopes; they are not silently
promoted. HTTP uses `Authorization: Bearer TOKEN`; the Phoenix channel
`services:gateway` accepts the token in its join payload. Tokens never go in URLs.

| HTTP path under `/api/services/v1` | Channel event | Payload |
| --- | --- | --- |
| `GET /models?service=tts` | `models:list` | `{"service":"tts"}` |
| `POST /tts` | `tts:run` | `{"input":"Ciao!","voice":"if_sara","speed":1.0}` |
| `POST /audio` (multipart `file`) | `audio:upload:start`, `audio:upload:chunk`, `audio:upload:finish` | See dashboard example |
| `POST /stt` | `stt:run` | `{"audio_id":"UUID"}` |
| `GET /requests/:id` | `request:get` | `{"id":"UUID"}` |
| `POST /requests/:id/cancel` | `request:cancel` | Queued requests only |
| `GET /audio/:id` | Authenticated HTTP download | Same owner key and service scope |

Generation/transcription return HTTP 202 or an acknowledged channel reply with
an ID. The shared queue runs one CPU model request at a time, with at most ten
pending requests. `request:update` delivers completion/failure to the owner.
Poll `request:get` after reconnecting. Results expire after five minutes; restart
clears the in-memory queue and results. Requests in progress aren't force-killed
inside native inference. Only housekeeping jobs use PostgreSQL/Oban.

TTS returns `result.audio.download_url`; fetch it with the same Bearer token
and save as `.mp3`. Enable REST on the key for downloading files. Phoenix uses
`send_download({:file, path})`, not an in-memory/base64 HTTP response. No public
static media route exists. A different API key cannot access the file.

## Uploads and retention

HTTP uploads use Phoenix/Plug multipart streaming, with authentication and the
`stt:run` scope checked **before body parsing**. The endpoint allows at most
25 MiB plus multipart framing. Supported extensions: MP3, WAV, OGG, FLAC, WebM,
M4A. Actual audio is validated by FFmpeg, not trusted from its extension.

WebSocket uploads use acknowledged chunks of up to 49,152 decoded bytes with
strict sequential offsets and a declared size. Limits: two pending uploads per
key, twelve globally, 25 MiB per file, 512 MiB private media quota. Unfinished
uploads expire after five idle minutes. Frame size stays bounded; entire audio
files never pass through LiveView assigns or a single channel message.

Completed files and ownership metadata are private under
`SERVICE_DATA_DIR/tmp/audio`; conversion intermediates under `tmp/work` are
removed immediately, even on failure. Oban checks hourly at minute 17 and removes
files older than 72 hours, including abandoned application work/upload files.
Authenticated downloads expire at exactly 72 hours; physical deletion occurs on
the following sweep. The worker never scans or wipes the host's general `/tmp`,
model folders, database backups or mail attachments. No audio blobs enter the DB.
Oban uses `_supavisor` and prunes its small housekeeping history after one day.

For Nginx, set `client_max_body_size 26m` and `proxy_request_buffering off` only
on `/api/services/v1/audio`, preserving the usual API body limit elsewhere.
Keep the existing Phoenix proxy headers and upstream. Plug uploads are owned by
the request process and cleaned by Plug after the request; only a successful
copy into private media storage survives it.

References: [Plug uploads](https://hexdocs.pm/plug/Plug.Upload.html),
[parser limits](https://hexdocs.pm/plug/Plug.Parsers.html),
[Phoenix downloads](https://hexdocs.pm/phoenix/Phoenix.Controller.html#send_download/3),
[Oban cron](https://hexdocs.pm/oban/Oban.Plugins.Cron.html).
