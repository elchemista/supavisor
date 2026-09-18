# Workspace services: REST, WebSocket, embedding and email

## Start locally

Requires Elixir 1.19+, the project's native build tools, and PostgreSQL.

```bash
mix setup
mix phx.server
```

For an existing installation, apply migrations with `mix supavisor.migrate`
(or `mix ecto.migrate --prefix _supavisor`), then run `mix assets.build`.
Do not run migrations against the default `public` schema.

Open `/admin` and choose **Sign in locally** with `admin@localhost` in development.
The console and all its forms use English. Its service pages are:

- **API**: named keys, permissions, expiration, connected clients and examples.
- **Embedding**: model catalog, download/activation, request queue and vector preview.
- **Mailer**: inbox, outbox, processing queue, mailboxes and inbound webhooks.
- **Metrics**: host/process CPU and RAM, and real embedding request counters.
- **STT / TTS**: local ONNX graph files, loading, tensor metadata and unloading.
- **AI model**: local ONNX graph loading from `priv/ai`, ready for a Qwen export.

Speech graphs can run from Elixir in development; complete speech pipelines and
their REST/WebSocket operations are not enabled yet. See [Local speech](local-speech.md).
AI text generation still needs the model adapter; see [Local AI models](local-ai.md).
Database import and export are available under **PostgreSQL → Backup / restore**
for each database; see [Database backups](database-backups.md).
Existing PostgreSQL pool protocols, REST routes and JWT credentials are unchanged.
Console login/GitHub OAuth and service API keys are separate authorization systems.

## Authentication

Create a key under **API → New API key**. Choose a name, expiration, transports,
permissions and optional mailbox restrictions. Generate a token or supply your
own random 32–128 character token containing letters, numbers, `_` and `-`.
Generated tokens have 256 random bits. Copy the token immediately: the preview
is hidden after two minutes. Only a SHA-256 digest and fingerprint are stored.

| Scope | Access |
| --- | --- |
| `embedding:read` | Model catalog and active model |
| `embedding:run` | Submit embedding requests |
| `mail:read` | List allowed mailboxes; read their messages |
| `mail:send` | Send from allowed, enabled mailboxes |

No selected mailbox restriction means all workspace mailboxes. Keys are service
credentials, not tenant database credentials. Request results and cancellations
are restricted to the submitting key; administrators can inspect all requests.
A key with `mail:read` can read messages in its permitted mailboxes, including
messages submitted by other keys.

Keys can be revoked immediately. Revocation closes their WebSocket clients and
prevents new work. Queued work checks authorization again before execution;
already-running native operations or SMTP deliveries cannot be recalled.
Revoked keys may be removed from the list. There are at most 100 stored keys.

Credentials use a protected ETS cache, refreshed every five seconds. Console
changes refresh it synchronously on this node and broadcast to other nodes.
A database refresh failure clears the cache rather than keeping stale access.
REST and WebSocket share a limit of 120 application requests/minute/key/node.
Unauthenticated REST calls return 401, missing permissions 403, inaccessible
request IDs 404, inactive models/idempotency conflicts 409, and full queues 429.

## REST and WebSocket

REST base: `/api/services/v1`. Send `Authorization: Bearer YOUR_API_TOKEN`.
JSON responses are marked `Cache-Control: no-store`. POST operations return
HTTP 202 and a request ID; poll the corresponding request to retrieve results.
Use HTTPS/WSS when the service is exposed beyond local development.

| REST | Phoenix Channels event |
| --- | --- |
| `GET /status` | `gateway:status` |
| `GET /models` | `models:list` |
| `POST /embeddings` | `embedding:run` |
| `GET /requests/:id` | `request:get` with `{id}` |
| `POST /requests/:id/cancel` | `request:cancel` with `{id}` |
| `GET /mailboxes` | `mailboxes:list` |
| `GET /mail/messages` | `mail:list` |
| `GET /mail/messages/:id` | `mail:get` with `{id}` |
| `POST /mail/send` | `mail:send` |

Mail listing accepts `direction=inbound`, `outbound` or `queue`, plus `page`,
`search` and `mailbox_id`; responses contain `rows`, `total`, `page`, `pages`.
Pages contain at most 20 message metadata rows. Message details include the
body. Treat HTML returned by the API as untrusted email content.

WebSocket uses Phoenix Channels protocol v2, not arbitrary raw JSON frames:

```javascript
import {Socket} from 'phoenix'

const socket = new Socket('ws://localhost:4000/services/socket')
const channel = socket.channel('services:gateway', {token: API_TOKEN})
channel.on('authorization:revoked', () => socket.disconnect())
channel.on('request:update', job => {
  if (job.status === 'completed') {
    channel.push('request:get', {id: job.id})
      .receive('ok', result => console.log(result))
  }
})
channel.join()
  .receive('ok', () => channel.push('models:list', {}).receive('ok', console.log))
  .receive('error', error => console.error(error))
socket.connect()
```

The wire endpoint is `/services/socket/websocket?vsn=2.0.0`. Authenticate in the
channel join, never the URL. An open transport alone is not authenticated.
The endpoint accepts cross-origin service clients and does not authorize console
cookies. The Phoenix client handles heartbeats/reconnects; every rejoin checks
the key again. The admin page monitors the endpoint through LiveView and has no
Connect/Disconnect control.

Limits: 256 KiB incoming WebSocket frame, 100 authenticated clients/node,
10 clients/key, 30 recent connection events. Clients receive `request:update`
metadata for their own key; fetch the result with `request:get`. General
`request:submit` is also supported with `{service: 'embedding' | 'mailer', payload}`.
Only queued operations can be cancelled.

## Local embedding with ex_fastembed

The dependency is a vendored snapshot of [elchemista/ex_fastembed](https://github.com/elchemista/ex_fastembed)
at `fa991c970c310b2f44f837062fe9202d71f96311`, with native unload and file metadata
support. See `vendor/ex_fastembed/SUPAVISOR_PATCH.md`. Its NIF builds from source;
the upstream precompiled artifact does not include these additions.
In **Embedding**, select a catalog model and choose **Download & activate**.
The catalog displays the repository, dimension, variant download size, cache
status and upstream model card. It can be sorted by smallest download. Missing files download from Hugging Face; initialization runs outside
LiveView. The first download needs network access and sufficient disk/RAM.

Only one embedding model is loaded per VM. Model changes and inference share a
serial queue so a vector cannot accidentally use a different model's dimensions.
The last successful selection is saved under `SERVICE_DATA_DIR`. Startup restores
the selection without loading weights. After five minutes without use, the native
session is released and the model enters **Standby**. The first REST or WebSocket
request reloads its cached weights and then runs; concurrent embedding requests
share the serial queue and one load. Queued/running work prevents idle unloading.
The five-minute deadline starts after the last inference or explicit load finishes;
viewing or refreshing the dashboard does not extend it.
`models:list` returns `active` (configured model), `loaded` (resident model or
`null`), `memory_state` and `idle_timeout_seconds`. A request loading its model has
`phase: "loading_model"`; its usual HTTP 202/request-polling flow is unchanged.
With no configured model, calls return `model_not_loaded`.
A failed switch preserves the previous model. A queued request for a model that
has since changed fails explicitly rather than using another model.

**Unload · release RAM** drops the native ONNX session immediately while keeping
the selection and downloaded files. The next request loads the model again.
The native allocator may retain some freed memory for reuse. **Delete downloaded
files** removes the selected repository cache, including any variants sharing
that repository. The confirmation lists those variants. An active model from
the repository must be unloaded first. Both actions require an administrator
and an empty queue; maintenance temporarily rejects new inference submissions.
Deleting the configured model's cache also clears its saved selection, so API
requests cannot silently re-download a model that an administrator removed.
Missing files require an explicit dashboard download. The database and other
repository caches are unaffected. Timers and activity tracking stay in memory.

Download sizes include only the selected variant's required graph, external
weights and tokenizer/configuration files. Public Hugging Face file metadata is
fetched in the background (four requests at most in parallel), cached for six
hours in a small `embedding-sizes.json` file under `SERVICE_DATA_DIR`, and served
through the existing ETS snapshot. Cached repositories use their pinned revision.
Unavailable metadata is shown explicitly; weight files are never downloaded to
measure them. Previously fetched metadata may be shown with a stale notice.
**Repository on disk** counts stored files once, without double-counting snapshot
symlinks, and includes partial downloads and other variants of that repository.
The dashboard distinguishes download/disk sizes from current app RSS and host
available RAM. App RSS covers all services and is not a per-model estimate.

```bash
curl http://localhost:4000/api/services/v1/embeddings \
  -H 'Authorization: Bearer YOUR_API_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"model":"BGESmallENV15Q","input":["Text to embed"]}'

curl http://localhost:4000/api/services/v1/requests/REQUEST_ID \
  -H 'Authorization: Bearer YOUR_API_TOKEN'
```

Equivalent channel request:

```javascript
channel.push('embedding:run', {
  model: 'BGESmallENV15Q', input: ['Text to embed']
}).receive('ok', job => console.log(job.id))
```

Completed results contain `result.model`, `result.input_count` and
`result.data: [{index, embedding: [/* floats */]}]`.
Input limits: 1–16 strings, each 1–4096 UTF-8 bytes. The queue holds at most 20
waiting jobs and one active operation. Up to 20 completed results remain in ETS
for approximately five minutes. Inputs are released after completion. Model
files remain on disk; vectors and inputs are never stored in PostgreSQL.
A running native model download/inference is not presented as cancellable.

## Mailboxes and Postbeam

The dependency is pinned to [elchemista/postbeam](https://github.com/elchemista/postbeam).
Create an address under **Mailer → Add mailbox**. Each mailbox has its own
enabled state, sending hostname, delivery mode, DKIM selector and webhook.

- **Local** stores outgoing mail and marks it `local`; no external email is sent.
- **Direct delivery** calls Postbeam, connecting to recipient MX servers with TLS.
  This is not an authenticated SMTP relay account or an IMAP client.

For external sending, configure a domain you control, outbound TCP 25,
forward/reverse DNS, SPF and DKIM. **DKIM DNS** generates/reuses a private key
and shows the TXT record to publish. Enable DKIM after publishing the record.
Postbeam private keys are stored with mode 0600 under the service data directory.
Mailbox creation does not provision DNS or accounts at an external mail provider.

Compose in the panel or submit:

```bash
curl http://localhost:4000/api/services/v1/mail/send \
  -H 'Authorization: Bearer YOUR_API_TOKEN' \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: invoice-2026-123' \
  -d '{"mailbox_id":"MAILBOX_ID","to":"recipient@example.com","subject":"Hello","text":"Sent with Postbeam"}'
```

Use `mail:send` with the same fields over WebSocket, placing the idempotency key
in `idempotency_key`. The sender is always the permitted mailbox's address.
There is one recipient per request, a 512-byte subject limit and 128 KB combined
text/HTML limit. Keep the same idempotency key when retrying the same operation.
Reusing it with another message returns a conflict. Deduplication lasts as long
as the original stored message exists; deleting it removes that protection.

The durable queue has two SMTP workers/node, at most 100 queued/processing
messages per mailbox. States distinguish `queued`, `sending`, `accepted`,
`failed`, `uncertain`, `cancelled` and `local`. `accepted` means recipient SMTP
acceptance, not guaranteed inbox placement. SMTP delivery is never automatically
requeued after an uncertain outcome or worker interruption, to avoid duplicates.
Review the result before submitting another message.

Message bodies/raw MIME and webhook tokens are encrypted with `VAULT_ENC_KEY`.
Sender, recipient, subject and queue metadata remain queryable. Each mailbox can
store at most 1,000 messages; full mailboxes reject incoming delivery temporarily
and reject new submissions. Messages remain until deleted by default. Optional
`SERVICE_MAIL_RETENTION_DAYS=N` removes completed messages older than N days in
an hourly cleanup; zero disables cleanup. Pending jobs are excluded. Only empty
mailboxes can be removed; disabling preserves their contents.

## Receive email and forward webhooks

Postbeam's inbound SMTP listener accepts only enabled mailbox addresses. It
stores messages before acknowledging SMTP acceptance and does not relay unknown
recipients. Local development listens on `127.0.0.1:2525`.

The panel's **Start/Stop receiver** applies until restart. Deployment settings:

```dotenv
SERVICE_SMTP_ENABLED=true
SERVICE_SMTP_BIND=127.0.0.1
SERVICE_SMTP_PORT=2525
SERVICE_SMTP_HOSTNAME=mail.example.com
# SERVICE_SMTP_CERTFILE=/etc/supavisor/smtp/fullchain.pem
# SERVICE_SMTP_KEYFILE=/etc/supavisor/smtp/privkey.pem
```

For public mail, route the domain's MX to the server and forward TCP 25 to this
listener (or configure an appropriate non-root privileged-port arrangement).
An existing mail server may forward selected recipients to the local listener.
Setting a mailbox address alone cannot receive messages for a domain whose MX
points elsewhere. Supply readable certificate/key files to offer STARTTLS.
Limits: 1 MiB/message, 10 recipients/transaction, 50 connections. This inbox does
not implement IMAP synchronization, spam filtering or sender SPF/DMARC validation.
The panel escapes plaintext and isolates HTML in a sandbox with remote resources
and scripts blocked. MIME attachments are represented by type and size metadata;
attachment download/forwarding is not implemented.

For each mailbox, enable **Incoming email webhook**, set the URL and optional
Bearer token. HTTPS is required, except HTTP loopback for local development.
A blank token field keeps the saved token; the removal checkbox clears it.
Tokens are encrypted and never filled back into the form.

Delivery is an asynchronous HTTP POST after the inbox transaction commits:

```http
Authorization: Bearer YOUR_CONFIGURED_TOKEN
X-Postbeam-Event-Id: MESSAGE_UUID
Idempotency-Key: MESSAGE_UUID
Content-Type: application/json
```

```json
{
  "event": "email.received",
  "event_id": "MESSAGE_UUID",
  "received_at": "2026-09-18T12:00:00Z",
  "mailbox": {"id": "MAILBOX_UUID", "address": "support@example.com"},
  "from": "sender@example.com",
  "to": ["support@example.com"],
  "subject": "Hello",
  "text": "Message body",
  "html": "",
  "attachments": []
}
```

The JSON `event_id` is stable across retries. Receivers must deduplicate it:
webhooks are delivered at least once and a timeout can happen after the receiver
has already accepted the message. HTTP 2xx succeeds. Network errors, 408, 429
and 5xx get at most five total attempts with delays of 30, 60, 120 and 240 seconds.
Other statuses fail immediately. Redirects are not followed. There are two
webhook workers/node. The message reader shows status, attempts, next attempt,
error and **Retry webhook** for failed events. Manual retry retains the event ID.
Queued attempts use the mailbox's current URL/token; disabling the mailbox or
webhook stops further forwarding. A request already sent cannot be recalled.

## Runtime and deployment

Set `SERVICE_DATA_DIR=/var/lib/supavisor/services` for the provided systemd unit.
It contains model files, the selected model name and DKIM private keys. Existing
`HF_HOME` or `FASTEMBED_CACHE_DIR` overrides control FastEmbed's model cache.
Back up the service database, Vault encryption key and DKIM keys. The unit keeps
service data writable outside the immutable release directory.

Queue claims use PostgreSQL row locks and leases; interrupted SMTP deliveries
become `uncertain`, while webhook deliveries can retry. Retention is optional.
Only mail state and service settings use persistent tables. CPU/RAM history,
model counters, connection activity, API rate counters and embedding vectors
use bounded ETS storage. None writes per-request model metrics to PostgreSQL.
LiveView tables use streams and update changed rows; service notifications are
coalesced per viewer. Queue counts share one aggregate read per worker cycle.

Embedding queues/results, model choice and connection counts belong to each
server node. Use one node for this setup; a multi-node deployment needs sticky
routing for embedding requests/results and consistent model/key storage.
The SMTP/webhook worker limits and rate limits are per node.
