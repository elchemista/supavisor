# MCP database access

Supavisor exposes a remote Model Context Protocol endpoint at `/mcp` using
stateless Streamable HTTP with JSON responses. OAuth authorization grants control
which databases and operations a client can access. No AI model runs in Supavisor.

## Server address

MCP is always available and requires OAuth authorization. Its URL is derived from
the domain serving the console. For example, opening the console at
`https://admin.sendvia.chat` gives `https://admin.sendvia.chat/mcp`. No MCP enable
flag or base URL setting is required.

Run the normal Supavisor metadata migrations before starting the updated release:

```sh
mix supavisor.migrate
```

HTTPS is required except for localhost development. A local TLS reverse proxy
must preserve the public `Host` and forward `X-Forwarded-Proto`, `Authorization`,
`Origin`, and `MCP-Protocol-Version` headers. OAuth discovery, token audience checks,
and the endpoint displayed in the console use this request origin together. The
console and OAuth endpoints must be served at the same origin. OAuth requires the
existing console session and allowed administrator list; sign in with a password
or GitHub.

Requests without `Origin` are supported for server-side clients. Browser origins
default to the MCP origin; explicitly allow additional origins with comma-separated
`MCP_ALLOWED_ORIGINS`. The server does not offer cross-origin browser CORS access.

Open **MCP** in the console (`/admin/mcp`) to copy the endpoint and revoke your
authorized connections. `/admin/api` also opens this page for existing bookmarks.

## Connect a remote client

Add `https://db.example.com/mcp` as a remote MCP server in a client that supports
OAuth discovery, authorization-code flow with S256 PKCE, and Streamable HTTP.
The same standard endpoint is intended for clients such as ChatGPT and Claude;
availability and setup depend on the client's support for custom remote servers.

During authorization, choose the permissions and existing tenants. Reading is
selected by default. Database creation and migrations require explicit selection.
The optional “all current and future databases” choice is also explicit. Databases
created by a connection are automatically added to its own grant.

Permissions are `db:read`, `db:create`, and `db:migrate`. A client must request the
desired scopes in its authorization request; when scope is omitted, only
`db:read` is requested. The consent screen cannot add scopes the client did not
request. Declining redirects back to the registered client with `access_denied`.

Discovery endpoints:

- `/.well-known/oauth-protected-resource/mcp`
- `/.well-known/oauth-authorization-server`

Clients can register dynamically with `POST /oauth/register`. If a client needs
manually entered credentials, register its exact callback URL and copy the
returned `client_id` and optional `client_secret` into the client configuration:

```sh
curl https://db.example.com/oauth/register \
  -H 'Content-Type: application/json' \
  -d '{"client_name":"Database client","redirect_uris":["https://client.example.com/callback"],"token_endpoint_auth_method":"client_secret_post"}'
```

Registration supports `none`, `client_secret_post`, and `client_secret_basic`.
HTTPS callback URLs are required, with HTTP permitted only for localhost/loopback.
Callbacks must match exactly, except for the variable port on an HTTP loopback-IP
callback (`127.0.0.1` or `::1`) used by native clients. The callback host, path, and
query must still match, and the token exchange must use the redirect URI chosen
during authorization. Authorization and token requests must include
`resource=https://db.example.com/mcp`; tokens for another resource are rejected.
Credentials are shown once and only SHA-256 hashes are stored. Public registration
is rate limited and capped at 1,000 clients.

### Codex

Codex supports this remote Streamable HTTP and OAuth flow. In the desktop/IDE
MCP settings, add the server URL, then choose Authenticate. With the CLI:

```sh
codex mcp add supavisor --url https://admin.sendvia.chat/mcp --oauth-resource https://admin.sendvia.chat/mcp
codex mcp login supavisor --scopes db:read,db:create,db:migrate
```

Sign in to the console in the browser and choose databases and permissions.
The server advertises all available scopes so clients can show both reading and
optional creation/migrations. Consent still selects only reading by default.
You may approve a smaller set than the client requests. Revoke the connection
from the MCP page at any time. See the [official Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp).

Access tokens last one hour. Refresh tokens rotate on every use and expire 30 days
after the original authorization. Reusing a previously consumed refresh token
revokes its connection. After 2,048 refreshes, fresh browser authorization is
required. Revoking a connection invalidates both tokens.
Removing the administrator from the allowlist or changing their password/session
version also invalidates access. OAuth records persist across server restarts.

## Database tools

| Tool | Scope | Behavior |
| --- | --- | --- |
| `list_databases` | `db:read` | List up to 500 authorized Supavisor tenants. |
| `describe_database` | `db:read` | Inspect up to 200 schema columns. |
| `read_query` | `db:read` | Execute a single SELECT/WITH query with parameters. |
| `migration_history` | `db:read` | Read up to 200 migrations recorded through MCP. |
| `create_database` | `db:create` | Create a database, dedicated owner role, and tenant. |
| `apply_migration` | `db:migrate` | Apply and record a named atomic SQL migration. |

Reads and migrations use the selected tenant's stored, non-manager PostgreSQL role,
never the provisioning administrator. JIT/auth-query tenants without a stored role
are unsupported. Administrative roles, including roles with server-file/program
privileges, are rejected. The Supavisor metadata database is excluded. PostgreSQL
role privileges remain the final boundary: use a dedicated role per database.

Read queries run in a PostgreSQL read-only transaction, with a maximum of 200 rows,
5-second statement timeout, and 1-second lock timeout. Text fields are limited to
4,096 characters and responses to 1 MiB. Truncated results are marked. Use explicit
columns, ordering, and filters for larger schemas or datasets.

Creation automatically reuses the application's configured PostgreSQL server and
credentials. That account must be allowed to create databases and owner roles.
An optional separate provisioner or explicit creation disable is described in
[local admin](local-admin.md).
Only `database_name` is required; `external_id` and `role_name` default to that
name. `target_host` and
`target_port` optionally select a configured target. Database credentials never
appear in MCP responses; use the console to manage connection credentials.
For TLS upstreams, creation also accepts `upstream_ssl`, `upstream_verify`
(`none` or `peer`), `upstream_tls_ca` (PEM), and `enforce_ssl`.

## Apply a migration

Call `apply_migration` with a unique name and one SQL statement per array entry:

```json
{
  "tenant_id": "my_app",
  "name": "20261111_create_notes",
  "statements": [
    "CREATE TABLE public.notes (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, body text NOT NULL)",
    "CREATE INDEX notes_body_idx ON public.notes (body)"
  ]
}
```

Schema and data changes run in one transaction. Success records the name, SHA-256
checksum, SQL statements, timestamp, and authorizing administrator in
`_supavisor_mcp.migrations` inside the tenant database. Failure rolls back changes
and the history entry. An advisory transaction lock serializes concurrent MCP
migrations in the same database. Repeating an identical name and SQL is a no-op;
reusing the name with different SQL fails.

The tool accepts up to 100 statements and 256 KiB total SQL. It excludes transaction
control, role/database administration, and operations that cannot run in a
transaction (such as `CREATE INDEX CONCURRENTLY`). History covers MCP migrations;
it does not import another migration framework's history. The database owner can
modify this history, so it is an operational record rather than a tamper-proof log.

## Removed services and upgrades

The mail service, email sign-in links, local models, embedding, STT/TTS, audio
processing, service REST/WebSocket API, and Oban workers are removed. Password,
GitHub, PostgreSQL pooling, provisioning, backups, metrics, and the tenant REST API
remain available. Existing service tables and private downloaded models are not
deleted automatically; this upgrade does not destroy stored data. SMTP and local
model environment variables are no longer used.

The implementation follows the MCP [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
and [authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).
It negotiates protocol versions `2025-11-25`, `2025-06-18`, and `2025-03-26`.
The optional SSE listener and legacy HTTP+SSE transport are not implemented.
