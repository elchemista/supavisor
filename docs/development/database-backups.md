# Database backups

Open **PostgreSQL → Backup / restore** beside a database. The English LiveView
workspace provides exports, uploads, a live operation history and authenticated
downloads. Jobs continue when the page closes. One operation runs at a time per
node, with at most five running/queued jobs and 100 retained history entries.

## Export

- **PostgreSQL archive (.dump):** a compressed, custom-format `pg_dump` archive.
- **ZIP (.zip):** the same compressed archive as `database.dump`, with a small
  `manifest.json` containing the database name, server version and dump SHA-256.
  ZIP uses stored entries because the PostgreSQL archive is already compressed.

Exports include database schemas, objects and data. They are logical snapshots,
not cluster backups: global roles, tablespaces, configuration, WAL and point-in-time
recovery are outside their scope. Download copies to separate storage; keeping
all backup files on the database server does not protect against losing that server.

The PostgreSQL client uses the configured `ADMIN_POSTGRES_*` credentials and only
servers allowed by the console. Downloads require a current administrator session.
The history displays the final archive SHA-256 under **Backup details**.

## Import / restore

1. Choose the **destination database** and open **Import / restore**.
2. Upload one custom-format `.dump` / `.backup` file, or a ZIP containing exactly
   one such archive and optionally `manifest.json`. Plain SQL, directory-format
   dumps, encrypted ZIPs and archives containing unrelated files are rejected.
3. Choose how to handle existing objects:
   - **Keep existing objects:** restore without dropping objects. A conflict
     stops the operation and rolls back its changes. Best suited to an empty database.
   - **Replace objects included in the backup:** use `--clean --if-exists` to
     drop and recreate the objects listed in the archive. Objects absent from the
     archive remain; this is not a drop/recreate of the entire destination database.
4. Choose ownership:
   - **Preserve archive owners and permissions:** the original roles must exist
     and the configured administrator must be allowed to restore their ownership.
   - **Use destination owner:** skip archived ownership/ACLs and restore as the
     current owner of the destination database. The configured administrator must
     be allowed to `SET ROLE` to that owner. This does not reconstruct the original grants.
5. Type the exact destination name and select **Back up & restore**.

The worker validates the archive, then exports the destination to `safety.dump`
**before** executing the restore. If this safety export fails, no restore starts.
The safety backup remains downloadable after a successful, failed or cancelled
restore. It is retained until the administrator removes that history entry.

Restores use `pg_restore --single-transaction --exit-on-error --no-tablespaces`.
Errors roll back the restore transaction. A cancellation racing with a completed
commit cannot undo it; inspect the final status and destination before retrying.
Use a maintenance window for application consistency: other clients can continue
to write before or during preparation, and their committed work is not part of
the restore transaction. The console never terminates their sessions automatically.

Only import trusted archives. PostgreSQL restores can execute SQL chosen by the
source database administrator, including during selective restores.

The console's own metadata database can be **exported**, but live import into a
database with that name is blocked. Restore it offline while Supavisor is stopped,
using PostgreSQL tools and retaining the original `VAULT_ENC_KEY`. Mailbox secrets,
stored passwords and other encrypted configuration depend on that key.

## Server requirements and configuration

Install `pg_dump` and `pg_restore` on the host, including when
running an Erlang release. These executables are not bundled into the release.
Use PostgreSQL client tools compatible with your server and archive; matching the
server major version is the simplest option. An older `pg_dump` cannot dump a newer
PostgreSQL server. Restoring an archive to an older PostgreSQL version is not guaranteed.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `BACKUP_DIRECTORY` | `$SERVICE_DATA_DIR/backups` | Private persistent storage for uploads and backup files |
| `BACKUP_NODE_ID` | Machine hostname | Stable identity of the node owning local backup files |
| `BACKUP_PG_BIN` | Search `PATH` | Optional directory containing `pg_dump` and `pg_restore` |
| `BACKUP_MAX_BYTES` | `2147483648` | Maximum uploaded, extracted or generated file size: 2 GiB |
| `BACKUP_QUOTA_BYTES` | `21474836480` | Aggregate backup storage budget: 20 GiB |
| `BACKUP_TIMEOUT_SECONDS` | `3600` | Maximum runtime per operation, including validation and safety export |

Set `SERVICE_DATA_DIR=/var/lib/supavisor/services` for the included Linux service.
Its `StateDirectory=supavisor` permits writing there. If `BACKUP_DIRECTORY` is
outside `/var/lib/supavisor`, grant the service user access and add the exact path
to the unit's `ReadWritePaths`; the example service has `ProtectSystem=strict`.
Use a stable, unique `BACKUP_NODE_ID` and separate backup storage for each running
node. Do not run multiple app instances with the same backup node identity/directory.
When moving to a replacement host, move the files and preserve that identity.

Uploads and outputs stream through disk, not through large LiveView assigns or
database blobs. Imports need room for the upload, extracted dump and safety copy;
ZIP exports temporarily need room for both the dump and ZIP. Storage checks apply
while commands run and when uploads arrive, with a 64 MiB free-space reserve for
the worker. Filesystem growth is checked periodically rather than reserved, so
allow extra headroom for concurrent uploads and other software using that disk.

Directories use mode `0700`; generated/uploaded files use `0600`. Credentials
reach the helper over its input pipe and PostgreSQL through the child environment,
never through command-line password arguments or backup job records. Protect
the backup directory with encrypted storage if encryption at rest is required.

The `_supavisor.database_backups` table stores only small job records. Progress
updates are broadcast through PubSub and streamed into LiveView. Finished backups
are never removed automatically. Unconsumed uploads expire after 24 hours.
On restart, interrupted jobs and queued imports are marked failed and any complete
safety backup is retained; imports are never automatically replayed. Queued exports
can resume. Removing an entry deletes its associated files as well as its metadata.

Apply migrations with `mix supavisor.migrate` (the included Linux service does this
before starting). Use `mix assets.build` after frontend changes.

References: [PostgreSQL pg_dump](https://www.postgresql.org/docs/current/app-pgdump.html)
and [PostgreSQL pg_restore](https://www.postgresql.org/docs/current/app-pgrestore.html).

The release includes a Rust backup worker compiled for the host architecture.
It streams PostgreSQL archives and ZIP files without loading them into memory,
checks time/storage limits, stops child processes on cancellation or parent
exit, and keeps passwords on stdin/environment rather than command arguments.
No Python runtime is used. Building a release requires Rust/Cargo, already
needed for the other native dependencies.
