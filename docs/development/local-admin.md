# Avvio locale e servizio Linux

## Su questo PC

PostgreSQL resta sulla porta **5432**. Supavisor usa **4000** per il pannello,
**6543** per il pool transazionale e **5452** per il pool di sessione.
Il database dei metadati è `supavisor_dev`, nello schema `_supavisor`.

Dalla cartella del progetto:

```bash
mix setup
mix phx.server
```

Apri [il pannello](http://localhost:4000/admin). L’email `admin@localhost` è già
compilata: premi **Sign in locally**. In sviluppo, dal PC locale e con il mailer
locale, l’accesso è diretto. La release di produzione usa i link monouso.

`mix setup` installa le dipendenze, crea il database se manca, esegue le
migrazioni e compila CSS/JavaScript. Non carica i seed dei test e non ricrea
utenti o tabelle dei database applicativi. Non usare `mix ecto.reset` sui dati
che vuoi conservare.

Le credenziali locali predefinite sono `postgres` / `postgres` su `localhost`.
Per cambiarle senza modificare il codice:

```bash
export DATABASE_URL='ecto://utente:password@127.0.0.1:5432/supavisor_dev'
export ADMIN_POSTGRES_HOST=127.0.0.1
export ADMIN_POSTGRES_PORT=5432
export ADMIN_POSTGRES_USER=postgres
export ADMIN_POSTGRES_PASSWORD='password-del-tuo-postgres'
mix setup
mix phx.server
```

Nella URL codifica i caratteri speciali della password (per esempio `@` come `%40`).
Per `ADMIN_POSTGRES_PASSWORD` usa invece la password originale.

### Cosa puoi fare

- **PostgreSQL**: vedere database, proprietari, dimensioni, numero di connessioni
  e ruoli; aggiornare l'elenco con **Refresh**.
- **Add connection / New tenant**: collegare un database esistente, indicando
  un utente PostgreSQL già esistente e la sua password.
- **Provision database**: creare un database e il relativo ruolo proprietario,
  con password casuale e profilo Supavisor. Salva la password mostrata al termine.
- **Edit tenant**: aggiornare credenziali memorizzate, utenti e parametri del pool.
  Lascia la password vuota per conservare quella già salvata.
- **Delete tenant**: eliminare il profilo Supavisor. Il database e il ruolo
  PostgreSQL restano presenti.

I profili Supavisor non sono l'inventario dei database. Gli utenti nei profili
sono credenziali di accesso al pool: modificarli non esegue `ALTER ROLE` su PostgreSQL.
La pagina PostgreSQL consente di consultare i ruoli; i nuovi ruoli vengono creati
insieme ai database dal modulo di provisioning. Le configurazioni auth-query
usano un manager PostgreSQL già predisposto con i permessi per la query.

Esempio per un database creato dal pannello, con connessione `mia_app` e ruolo
`mia_app_user`:

```bash
psql -h 127.0.0.1 -p 6543 -U mia_app_user.mia_app -d mia_app_db -W
```

Per session pooling usa `-p 5452`. La porta `5432` continua a raggiungere PostgreSQL
direttamente. Per migrazioni applicative che richiedono una sessione stabile usa
la connessione diretta o la porta di sessione.

### Requisiti e problemi frequenti

- Elixir **1.18+**, Erlang/OTP **27+**, Rust, C/C++ toolchain, CMake e libclang.
  In questa sessione sono stati usati Elixir 1.20.2, OTP 29 e PostgreSQL 18.6.
- `eaddrinuse`: un'altra istanza usa già la porta. Ferma la vecchia istanza oppure
  configura `PORT`, `PROXY_PORT_SESSION`, `PROXY_PORT_TRANSACTION` e, se avvii
  più pooler, anche `PROXY_PORT`, `SESSION_PROXY_PORTS`, `TRANSACTION_PROXY_PORTS`.
- La sessione del browser dura 8 ore. In produzione, ogni link di accesso è
  monouso e scade dopo 15 minuti; dopo un riavvio richiedine uno nuovo.
- UI senza stile: esegui `mix assets.setup && mix assets.build` e ricarica.
- Verifica di salute: `curl -i http://localhost:4000/api/health` deve restituire `204`.

## Preparazione del server Linux senza Docker

Compila sul server o su una macchina con la stessa architettura e ABI Linux:

```bash
./scripts/build-release.sh
```

La release include Erlang, Elixir e le risorse del pannello. Sul server servono
le librerie di sistema compatibili con la macchina di compilazione. Non copiare
una release compilata su una distribuzione più recente verso una più vecchia.

1. Crea un utente Linux di servizio `supavisor` e copia la release da
   `_build/prod/rel/supavisor` a `/opt/supavisor/current`.
2. In PostgreSQL crea un ruolo `supavisor` con login e un database `supavisor`
   di sua proprietà. Imposta la password con `\password supavisor` da `psql`.
3. Copia `deploy/systemd/supavisor.env.example` in
   `/etc/supavisor/supavisor.env`, proprietà `root:root`, permessi `0600`, e
   sostituisci tutti i segnaposto. Per `VAULT_ENC_KEY` usa `openssl rand -hex 16`
   (32 caratteri); per `SECRET_KEY_BASE` usa `openssl rand -hex 64`; per gli
   altri segreti usa `openssl rand -hex 32`. Conserva la chiave Vault: serve
   a decifrare le password già salvate e va inclusa nei backup protetti.
4. Configura il PostgreSQL esistente tramite `ADMIN_POSTGRES_*`. Abilita
   `ADMIN_PROVISIONING_ENABLED=true` se vuoi creare database e ruoli dal pannello.
5. Installa l'unità:

```bash
sudo cp deploy/systemd/supavisor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now supavisor
sudo systemctl status supavisor
sudo journalctl -u supavisor -f
```

L'unità esegue automaticamente le migrazioni prima dell'avvio. L'utente Linux
deve poter leggere la release. Il database dei metadati deve esistere già.
I log e lo stato restano disponibili tramite `journalctl` e `systemctl`.

### Accesso al pannello sul server

La configurazione di esempio espone HTTP solo su loopback. Puoi raggiungerlo
con `ssh -L 4000:127.0.0.1:4000 utente@server` e aprire `http://localhost:4000`.
Per un dominio pubblico configura un reverse proxy HTTPS con supporto WebSocket,
imposta `ADMIN_BASE_URL=https://db.example.com` e `POOLER_HOST` all'host del pooler.
Il firewall deve esporre solo le porte dei pool autorizzate, tenendo private
le porte di clustering e i proxy interni `5412`, `12100`–`12107`.

Configura SMTP per ricevere i magic link. In alternativa, un amministratore del
server può generare un link per un'email presente in `ADMIN_EMAILS`:

```bash
sudo systemd-run --wait --pipe --collect \
  -p User=supavisor -p Group=supavisor \
  -p WorkingDirectory=/opt/supavisor/current \
  -p EnvironmentFile=/etc/supavisor/supavisor.env \
  /opt/supavisor/current/bin/supavisor rpc \
  '{:ok, url} = SupavisorWeb.AdminAuth.create_magic_link("admin@example.com"); IO.puts(url)'
```

Il comando va eseguito sul server mentre il servizio è attivo. Il link dà accesso
amministrativo, scade dopo 15 minuti e si può usare una sola volta.
Il file di ambiente viene letto da systemd, senza eseguire il contenuto come comandi di shell.

Questi file preparano l'installazione; non distribuiscono il progetto su un server remoto.

## Authorization and GitHub sign-in

Open **Authorization** in the console to manage the administrator email list.
The initial list comes from `ADMIN_EMAILS`; after the first save, PostgreSQL
stores the list in `_supavisor.admin_settings`. Keep your current address in the
list when saving. Admin access is checked again on requests, LiveView events,
navigation and API channel messages.

To enable GitHub sign-in, register an OAuth App in GitHub Developer Settings.
Set its homepage to the console URL and its callback to:

```
http://localhost:4000/admin/auth/github/callback
```

For a deployed server, use its HTTPS URL. Open the console through the same
hostname used by the callback. Enter the Client ID and Client Secret in
**Authorization**, enable GitHub sign-in and save. The login page then offers
**Continue with GitHub**. Only verified GitHub email addresses present in the
administrator list can sign in. The local direct sign-in option remains
available in development.

OAuth uses session-bound, single-use state with a ten-minute expiry and PKCE
S256. Provider requests use only the `user:email` scope. The Client Secret is
encrypted with the application's existing Vault key and is never rendered back
to the browser. Keep the same Vault key when moving the application database to
a server. An empty secret field preserves the saved secret; uncheck the enable
option to disable GitHub sign-in.

Provider setup reference:
[GitHub OAuth web application flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps).

## Console sections

The console uses LiveView navigation, a responsive sidebar and a section search
palette (Ctrl/Cmd + K). Tenants and PostgreSQL include search and pagination.
The **API** section manages service WebSocket credentials and live connections
at `/services/socket`, channel `services:gateway`. Applications authenticate
with a dedicated token. The PostgreSQL REST API keeps its existing routes and
credentials; it is independent of this service endpoint.

Mailer shows the configured delivery adapter. Embedding, STT, TTS, AI model and
Imports have dedicated pages describing their unconfigured status. Their
provider integrations and processing jobs are not implemented yet.

### Live updates and memory

Tenant lists use database pagination and LiveView Streams, selecting only the
visible page and user counts. PostgreSQL tables also use Streams, with bounded
catalog reads and ten visible rows per page. Tenant changes are broadcast via
PubSub to refresh other open tenant pages.

Administrator allowlists use a supervised, protected ETS table with concurrent
reads. Database refreshes are serialized and cached for five seconds. Saving
Authorization settings invalidates the local cache synchronously and broadcasts
invalidation to the other nodes. The cache contains email addresses only;
provider secrets stay encrypted in PostgreSQL. Direct database edits are picked
up when the short cache lifetime expires.

## Metrics

**Metrics** displays Supavisor process RAM, physical server RAM usage and
Supavisor/server CPU utilization. One supervised collector reads Linux `/proc`
every five seconds, independently of the number of dashboard viewers. Process
RAM is resident memory (`VmRSS`), including native allocations in the BEAM
process; it excludes child processes such as development asset watchers. Server
used RAM is `MemTotal - MemAvailable`, so reclaimable filesystem cache is not
counted as unavailable memory. CPU percentages compare tick deltas against all
logical host CPUs: 100% means the whole server, rather than a single core.
These are host metrics, not cgroup quotas.

The collector keeps a protected ETS snapshot and at most 120 chart samples
(10 minutes). LiveView updates arrive through PubSub, and model rows use
Streams. **Pause live** unsubscribes that view without stopping the shared
collector. There are no metric tables, migrations, PostgreSQL metric writes or
per-request logs. History and request totals reset when the collector restarts.
Unavailable Linux counters show `—`; CPU needs two readings to calculate a delta.

### Instrumenting model providers

Provider integrations are not connected yet, so the model counters initially
show zero. Wrap each complete provider operation when adding an integration:

```elixir
alias Supavisor.Monitoring.ModelMetrics

ModelMetrics.track(:ai_model, fn ->
  # Call the provider and consume the complete response here.
  # Return {:ok, result} or {:error, reason}.
  MyModelProvider.complete(prompt)
end)
```

Use `:embedding`, `:stt` or `:tts` for those services. For streaming providers,
consume the stream inside the function; returning a lazy stream would only time
its creation. Retries within the function count as one logical request.
Returned errors and exceptions count as failures; exceptions retain their
original behavior. The wrapper emits Telemetry start/stop/exception events,
and the handler updates four fixed ETS rows atomically. Each row retains only
successes, errors, cumulative duration and in-progress requests. Completed
counts include successes and failures; average duration covers both. No prompt,
response, token, user ID or unbounded model-name labels are retained.

Collection definitions follow the
[Linux `/proc` documentation](https://www.kernel.org/doc/html/latest/filesystems/proc.html)
and the [Telemetry span contract](https://telemetry.hexdocs.pm/telemetry.html#span/3).

## Service WebSocket API

Open `/admin/api`. The endpoint runs whenever the application runs. The admin
page monitors it automatically through LiveView; it does not open a separate
service client and has no Connect/Disconnect button.

### Credentials

- Generate a token, or save your own random 32–128 character token (letters,
  digits, underscores, hyphens). Generated tokens contain 256 random bits.
- Copy a generated token immediately; its preview disappears after two minutes
  or when navigating away. Only its SHA-256 hash and a fingerprint are stored
  in the single `_supavisor.service_api_settings` configuration row.
- Replacing or revoking the token disconnects authenticated service clients.
  Console login and the existing PostgreSQL REST API credentials are separate.
- Treat this as a server integration credential with access to the service
  gateway. It is not a tenant-scoped credential or an administrator login.

### Client protocol

Use the `phoenix` JavaScript package (Phoenix Channels protocol v2). The server
accepts WebSocket connections at `/services/socket/websocket`. A raw WebSocket
connection alone is **not authenticated**: only a successful channel join grants
access. Pass the token in the join payload, never in the URL. Tokens and service
payloads are excluded from channel logs. Use WSS outside local development.

```javascript
import {Socket} from "phoenix"

const socket = new Socket("ws://localhost:4000/services/socket")
const channel = socket.channel("services:gateway", {token: API_TOKEN})

channel.on("authorization:revoked", () => socket.disconnect())
channel.join()
  .receive("ok", ({client_id}) => {
    console.log("Authenticated", client_id)
    channel.push("gateway:status", {})
      .receive("ok", status => console.log(status))
  })
  .receive("error", ({code}) => console.error(code))
socket.connect()
```

The Phoenix client handles heartbeats and reconnects. Reconnects authenticate
again, so a revoked token cannot rejoin. Update the client configuration after
replacing a token. This endpoint deliberately accepts cross-origin clients;
it does not accept console cookies as authorization. Authentication requires
possession of the service token. The admin LiveView keeps its normal session
and origin checks.

### Current scope

Only connection and authorization are implemented, as requested. The reserved
service names are `mailer`, `embedding`, `ai_model`, `stt` and `tts`.
`request:submit` with one of these services returns `service_not_implemented`;
unknown services return `unknown_service`. No jobs are accepted or queued.
The UI marks queue/processing as unavailable until handlers are implemented.
Future handler integration belongs in `SupavisorWeb.ServiceChannel`; use
`Supavisor.Monitoring.ModelMetrics.track/2` around completed model operations.

There are at most 100 authenticated clients per server, 30 recent connection
events, a 16 KiB WebSocket frame limit and 30 application events per client per
second. The connection registry uses ETS snapshots, process monitors and
coalesced PubSub updates. LiveView Streams insert/delete only changed rows.
Neither connections nor activity nor metrics are written to PostgreSQL.
They are local to this server and reset when their process restarts. The token
configuration survives application restarts.
