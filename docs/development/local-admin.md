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
compilata: seleziona **I'm not a robot** e premi **Sign in locally**. In sviluppo,
dal PC locale, l’accesso è diretto. La release di produzione usa email e
password; la prima password viene generata dal comando amministrativo sul server.

`mix setup` installa le dipendenze, crea il database se manca, esegue le
migrazioni e compila CSS/JavaScript. Non carica i seed dei test e non ricrea
utenti o tabelle dei database applicativi. Non usare `mix ecto.reset` sui dati
che vuoi conservare.

In sviluppo, `mix phx.server` applica automaticamente le migrazioni metadata
pendenti prima di avviare il pannello. Il database deve già esistere (crealo con
`mix setup` al primo avvio). In produzione resta necessario `bin/migrate`, già
eseguito da `ExecStartPre` nel servizio systemd fornito.

Le credenziali locali predefinite sono `postgres` / `postgres` su `localhost`.
Per cambiarle senza modificare il codice:

```bash
export DATABASE_URL='ecto://utente:password@127.0.0.1:5432/supavisor_dev'
mix setup
mix phx.server
```

Nella URL codifica i caratteri speciali della password (per esempio `@` come `%40`).
La console riutilizza automaticamente questo server e queste credenziali per
elencare e creare database. Un account separato `ADMIN_POSTGRES_*` serve solo
se vuoi usare credenziali amministrative diverse; l'account usato per creare
database deve avere i relativi permessi PostgreSQL.

### Cosa puoi fare

- **PostgreSQL**: vedere database, proprietari, dimensioni, numero di connessioni
  e ruoli; aggiornare l'elenco con **Refresh**.
- **Backup / restore**: export e import per database in formato `.dump` o ZIP,
  con coda, storico e backup di sicurezza prima del ripristino.
  Vedi [Database backups](database-backups.md) per formati, requisiti e limiti.
- **Connect database**: scegliere un database dall'elenco. Il pannello propone
  automaticamente il nome della connessione e il proprietario del database;
  inserisci la password dell'utente PostgreSQL già esistente.
- **Create database**: inserire il nome del nuovo database. Il pannello crea
  automaticamente il proprietario e la connessione Supavisor con lo stesso nome,
  genera una password e mostra i dati pronti per collegarsi. Salva la password
  mostrata al termine. I nomi possono essere personalizzati nelle opzioni avanzate.
- **Edit connection**: aggiornare credenziali memorizzate, utenti e parametri del pool.
  Lascia la password vuota per conservare quella già salvata.
- **Remove connection**: eliminare il profilo Supavisor. Il database e il ruolo
  PostgreSQL restano presenti.

I profili Supavisor non sono l'inventario dei database. Gli utenti nei profili
sono credenziali di accesso al pool: modificarli non esegue `ALTER ROLE` su PostgreSQL.
La pagina PostgreSQL consente di consultare i ruoli; i nuovi ruoli vengono creati
insieme ai database dal modulo di provisioning. Le configurazioni auth-query
usano un manager PostgreSQL già predisposto con i permessi per la query.

I form usano direttamente il server PostgreSQL configurato per l'installazione:
non occorre compilare host, porta o URL. Se sono configurati più server, scegli
quello desiderato dall'elenco. Pooling, TLS, regole di rete e autenticazione
tramite query restano disponibili nelle opzioni avanzate; i valori predefiniti
permettono di creare o collegare un database senza modificarle.

Esempio per il database `mia_app` creato con i nomi predefiniti:

```bash
psql -h 127.0.0.1 -p 6543 -U mia_app.mia_app -d mia_app -W
```

Per session pooling usa `-p 5452`. La porta `5432` continua a raggiungere PostgreSQL
direttamente. Per migrazioni applicative che richiedono una sessione stabile usa
la connessione diretta o la porta di sessione.

### Requisiti e problemi frequenti

- Elixir **1.19+**, Erlang/OTP **27+**, Rust, C/C++ toolchain, CMake e libclang.
  In questa sessione sono stati usati Elixir 1.20.2, OTP 29 e PostgreSQL 18.6.
- `eaddrinuse`: un'altra istanza usa già la porta. Ferma la vecchia istanza oppure
  configura `PORT`, `PROXY_PORT_SESSION`, `PROXY_PORT_TRANSACTION` e, se avvii
  più pooler, anche `PROXY_PORT`, `SESSION_PROXY_PORTS`, `TRANSACTION_PROXY_PORTS`.
- La sessione del browser dura 8 ore. Per generare o reimpostare una password
  usa `supavisor-admin-password` sul server oppure
  `mix supavisor.admin.reset_password` da un checkout locale.
- UI senza stile: esegui `mix assets.setup && mix assets.build` e ricarica.
- Verifica di salute: `curl -i http://localhost:4000/api/health` deve restituire `204`.

## Preparazione del server Linux senza Docker

Per l'installazione su `admin.sendvia.chat`, i percorsi del servizio, l'accesso
iniziale e le regole di rete sono documentati in
[Hetzner deployment](hetzner-deployment.md).

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
sudo install -m 700 deploy/systemd/supavisor-admin-password /usr/local/sbin/supavisor-admin-password
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

`PROXY_BIND_ADDRESS=127.0.0.1` mantiene tutti i listener PostgreSQL di Supavisor
su loopback. Se Nginx gira sullo stesso server e sostituisce gli header
`X-Forwarded-Proto`, `X-Forwarded-Port` e `X-Forwarded-For`, imposta
`TRUST_PROXY_HEADERS=true`: la console riconosce HTTPS e genera URL WSS e cookie
Secure. Gli header vengono accettati solo da connessioni locali.

Per il primo accesso o per reimpostare una password dimenticata, un
amministratore del server genera una password per un'email già presente in
`ADMIN_EMAILS`:

```bash
sudo supavisor-admin-password admin@example.com
```

Il comando genera e mostra una nuova password e invalida le sessioni precedenti.
Richiede un'email già autorizzata e il servizio attivo. Per vedere le istruzioni
senza modificare nulla: `sudo supavisor-admin-password --help`.

Questi file preparano l'installazione; non distribuiscono il progetto su un server remoto.

## Authorization and GitHub sign-in

Open **Authorization** in the console to manage the administrator email list.
The initial list comes from `ADMIN_EMAILS`; after the first save, PostgreSQL
stores the list in `_supavisor.admin_settings`. Keep your current address in the
list when saving. Admin access is checked again on requests, LiveView events,
navigation and MCP authorization requests.

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
palette (Ctrl/Cmd + K). Connections and PostgreSQL include search and pagination.
**MCP** connects external assistants through OAuth with explicit database
permissions. See [Database MCP](mcp.md) for connection and authorization setup.
Database import and export are available under **PostgreSQL → Backup / restore**
for each database; see [Database backups](database-backups.md).

### Live updates and memory

Connection lists use database pagination and LiveView Streams, selecting only the
visible page and user counts. PostgreSQL tables also use Streams, with bounded
catalog reads and ten visible rows per page. Connection changes are broadcast via
PubSub to refresh other open connection pages.

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
(10 minutes). LiveView updates arrive through PubSub. **Pause live** unsubscribes that view without stopping the shared
collector. There are no metric tables, migrations, PostgreSQL metric writes or
per-request logs. History and request totals reset when the collector restarts.
Unavailable Linux counters show `—`; CPU needs two readings to calculate a delta.

Collection definitions follow the
[Linux `/proc` documentation](https://www.kernel.org/doc/html/latest/filesystems/proc.html).
