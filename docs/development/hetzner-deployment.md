# Hetzner deployment

## Installation

- Console and database MCP: `https://admin.sendvia.chat`.
- Administrator: `yuriy.zhar@gmail.com`.
- Host: Ubuntu 24.04 ARM64, `89.167.44.148`, IPv6 `2a01:4f9:c014:ee00::1`.
- DNS: `admin` A → `89.167.44.148`; AAAA → `2a01:4f9:c014:ee00::1`.
- Nginx terminates TLS and forwards HTTP and LiveView WebSockets to
  `127.0.0.1:4000`. Certbot renews the certificate automatically.
- Supavisor runs as the unprivileged `supavisor` user under systemd.
- Release builds run separately as `supavisor-build`, using Elixir 1.20.4 and
  Erlang/OTP 28.5.0.6 on the target architecture.

Runtime configuration and credentials are in `/etc/supavisor/supavisor.env`,
owned by root with mode `0600`. Never add that file to Git. Preserve
`VAULT_ENC_KEY`, the metadata database, and `/var/lib/supavisor` together when
moving or recovering the installation.

The dedicated `supavisor` database stores console metadata in `_supavisor`.
Its login is not a superuser. The separate `supavisor_console` role administers
the existing databases and is a superuser, because the console can provision
roles and restore databases owned by other roles. Existing PostgreSQL HBA rules
only allow that new role over loopback. Its password is stored in the protected
environment file, not in a browser or client API key.

### Application connection profiles

| Tenant | Existing database | PostgreSQL role | Pool username |
| --- | --- | --- | --- |
| `rdm` | `rdmdb` | `rdm_app` | `rdm_app.rdm` |
| `sendvia_prod` | `send_via_prod` | `send_via_app` | `send_via_app.sendvia_prod` |
| `freelance` | `freelance_prod` | `freelance_app` | `freelance_app.freelance` |

These profiles use the existing passwords, encrypted in Supavisor, and connect
to PostgreSQL over loopback (`127.0.0.1:5432`). Each has a default pool size of 5
and a 50-client limit. Client allowlists include loopback and that application's
existing egress IP. Vext has no tenant. Creating these profiles does not migrate
the applications: their direct mTLS PostgreSQL connections remain separate.
Both transaction (`127.0.0.1:6543`) and session (`127.0.0.1:5452`) pooling were
verified with read-only queries. Remote pool access needs an SSH tunnel or
private network; the pool ports are not publicly exposed.

**Connect database** lets you choose an existing database. The server address
comes from configuration automatically; a server selector appears only when
multiple distinct servers are configured. The form suggests a connection name
and the database's login-capable owner. Enter the role's password; PostgreSQL
cannot return plaintext passwords. Advanced settings are collapsed, and saving
shows a connection URL ready to copy. Lists load asynchronously and are cached in memory
for 30 seconds without database-size or connection-count scans.
LiveView reconnects preserve the draft's selected server and database. The form
fits narrow mobile screens; connection examples scroll within their own panel.

### Prepared application deployments

The local RDM, SendVia and Freelance repositories now contain production-only
Supavisor configuration and a managed SSH tunnel in their release entrypoints.
Fly has staged `SUPAVISOR_PASSWORD` and `SUPAVISOR_SSH_KEY_B64` secrets for each
app; the application deployments are still performed separately by the owner.
Application traffic uses transaction pooling; release migrations use the
session pool. Existing direct PostgreSQL configuration remains available for
rollback with `DATABASE_CONNECTION_MODE=direct`.

The dedicated system accounts `supavisor-rdm`, `supavisor-sendvia` and
`supavisor-freelance` accept only their application key and can forward only
`127.0.0.1:6543` and `127.0.0.1:5452`. SSH configuration sets `MaxSessions 0`,
permits local forwarding only and disables agent, X11 and Unix socket forwarding.
The accounts cannot open shells or SFTP sessions. Their key files are under
`/home/<account>/.ssh/authorized_keys`. No new public ports are opened.

The restrictions are appended to `/etc/ssh/sshd_config`; its preceding copy is
`/var/backups/sshd_config.before-supavisor-apps-20260918`. Verify configuration
with `sshd -t` before reloading SSH. The verified host public key is pinned in
each app release. Fly egress IPs are not assumed static for these tunnels;
authentication uses the separate restricted keys. Existing direct PostgreSQL
IP allowlists have not been changed.

## Sign in and authorize MCP clients

Normal sign-in uses the administrator email and password, with no SMTP
dependency. An initial password has been configured for the administrator and
delivered privately; it is not stored in this document. Change it under
**Authorization → Update your sign-in password**.

For a new installation without an administrator password, generate it on the
server with `sudo supavisor-admin-password [ADMIN_EMAIL]`. Password changes
require the current password and invalidate other sessions. There is no public
administrator registration endpoint.

Configure GitHub login under **Authorization**, using callback
`https://admin.sendvia.chat/admin/auth/github/callback`.

External assistants connect to `/mcp` and authenticate through OAuth. Each
connection asks an authenticated administrator to approve database permissions.
See [Database MCP](mcp.md) for setup. Native Ecto/Postgrex connections continue
to use PostgreSQL tenant credentials.

Passwords use PBKDF2-HMAC-SHA256 with 600,000 iterations and a random 32-byte
salt, implemented with Erlang/OTP crypto. Only hashes are stored. Sign-in
attempts are limited by IP and account in bounded ETS storage; there are no
per-attempt database writes. Session versions and admin permissions are cached
briefly and invalidated on changes. See the
[OWASP password storage guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
and [OTP crypto documentation](https://www.erlang.org/docs/28/apps/crypto/crypto.html#pbkdf2_hmac/5).

Password and GitHub sign-in starts require the
**I'm not a robot** checkbox powered by
[PhoenixCap](https://github.com/elchemista/phoenix_cap). Verification happens
before password checking or OAuth state creation, and each token works once.
The widget, WASM solver and browser decompression fallback are served locally.
Challenges and tokens expire in ETS and do not write to PostgreSQL. The
`/admin/cap/` endpoints require the login session's CSRF token and are limited
to 20 requests per IP per minute and 100 requests in total per minute.
Existing password/IP limits also apply. JavaScript is required to sign in.
The SSH password reset command remains available independently.

### Reset a forgotten password over SSH

```bash
ssh -t hetzner 'sudo supavisor-admin-password yuriy.zhar@gmail.com'
```

The command generates a random password, prints it once in your SSH terminal
and invalidates previous admin sessions. It never asks for the old password,
sends email or writes a plaintext password file. Save the output in your
password manager. The password itself is never a command-line argument and
is not sent to the service journal. Run `sudo supavisor-admin-password --help`
to see usage without changing anything.

The command requires root/sudo and an active Supavisor service. It uses the
service account and protected runtime environment internally. It can only
reset an email already on the administrator allowlist; it does not create an
administrator. With a single administrator you may omit the email.

The portable release equivalent is `bin/reset-admin-password [ADMIN_EMAIL]`
with the service account/environment. For a source checkout with no application
already running, use `mix supavisor.admin.reset_password [ADMIN_EMAIL]`.

## Network policy

| Port | Reachability |
| --- | --- |
| 80 | Public, ACME validation and redirect to HTTPS |
| 443 | Public, HTTPS and WSS |
| 22 | SSH administration; root requires an SSH key |
| 5432 | Existing application IPs only, retaining their mTLS authentication |
| 4000, 5452, 6543, 5412, 12100–12107 | Supavisor loopback only |
| Erlang distribution / EPMD | Loopback only |

The retained PostgreSQL client addresses are `89.222.119.29` (freelance),
`89.222.119.3` (RDM) and `89.222.108.17` (SendVia). Reassess these rules if the
applications' egress addresses change. Migrate their connections before
removing the remaining PostgreSQL firewall exceptions.

PostgreSQL certificates, application passwords and database contents are
preserved. Existing PostgreSQL is not restarted as part of this deployment.

`TRUST_PROXY_HEADERS=true` trusts forwarded protocol, port and client IP only
from loopback. Nginx replaces those headers. Session cookies use Secure over
HTTPS, HttpOnly and SameSite=Lax. Sign-in paths and token query strings are not
written to Nginx access logs. OAuth authorization, token and MCP requests must
also avoid recording credentials and authorization codes.

## Operations

```bash
sudo systemctl status supavisor nginx
sudo journalctl -u supavisor -n 100 --no-pager
sudo systemctl restart supavisor
sudo nginx -t
sudo systemctl list-timers certbot.timer
curl --fail --silent --show-error https://admin.sendvia.chat/api/health
```

The health endpoint returns HTTP 204. `/admin` requires an authenticated admin;
`/mcp` requires an OAuth access token with the scopes approved during consent.

Database backup files remain in the configured backup directory. Old embedding
models, audio and mail files from previous releases are no longer used by the
application; removing existing files is a separate storage maintenance action.
The service has a 6 GiB memory ceiling and a five-core CPU quota to leave
capacity for PostgreSQL.

Before deployment, database dumps, role definitions, PostgreSQL configuration,
certificates and firewall configuration were saved under
`/var/backups/supavisor-deploy/20260918T151541Z` (root only). This is a local
recovery snapshot, not an off-site backup policy. Restore individual files only
after checking which component needs recovery; do not blindly restore old
application databases over newer data.

Versioned releases live under `/opt/supavisor/releases`; the active release is
`/opt/supavisor/current`. The build workspace is `/opt/supavisor-build/source`.
Do not copy a release built on x86_64 to this ARM64 server. Before an upgrade,
back up the metadata database and configuration and retain the previous release.
Database migrations must be reviewed before attempting a binary rollback.
