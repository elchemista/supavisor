defmodule SupavisorWeb.Admin.BackupLive do
  use SupavisorWeb, :live_view
  alias Supavisor.Backups
  alias SupavisorWeb.Admin.ServiceUI, as: UI

  @impl true
  def mount(_, session, socket) do
    if connected?(socket) do
      Backups.subscribe()
      Process.send_after(self(), :backup_tick, 1000)
    end

    {:ok,
     socket
     |> assign(
       service_session: session,
       target: nil,
       database: "",
       server: 0,
       loading: true,
       target_error: nil,
       info: nil,
       dirty: false,
       job_count: 0,
       active_count: 0,
       tab: "export",
       format: "dump",
       confirmation: "",
       restore_mode: "add",
       ownership: "preserve",
       tools: Backups.tools()
     )
     |> stream(:jobs, [])
     |> allow_upload(:backup,
       accept: ~w(.dump .backup .zip),
       max_entries: 1,
       max_file_size: Backups.max_bytes(),
       auto_upload: true,
       writer: fn _, _, _ -> {Backups.UploadWriter, []} end
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    index =
      case Integer.parse(params["server"] || "0") do
        {value, ""} when value >= 0 -> value
        _ -> -1
      end

    target = if index >= 0, do: Enum.at(Backups.targets(), index)
    database = params["database"] || ""

    socket =
      Enum.reduce(socket.assigns.uploads.backup.entries, socket, fn entry, acc ->
        discard_upload(acc, entry)
      end)

    socket =
      socket
      |> cancel_async(:target)
      |> assign(
        target: target,
        database: database,
        server: index,
        loading: true,
        info: nil,
        target_error: nil,
        confirmation: ""
      )
      |> load()

    if target do
      {host, port} = target

      {:noreply,
       start_async(socket, :target, fn -> Backups.target_info(host, port, database) end)}
    else
      {:noreply,
       assign(socket, loading: false, target_error: "Choose a database from the PostgreSQL page.")}
    end
  end

  @impl true
  def handle_async(:target, {:ok, {:ok, info}}, socket),
    do: {:noreply, assign(socket, info: info, loading: false)}

  def handle_async(:target, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, target_error: error, loading: false)}

  def handle_async(:target, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket, target_error: "Cannot reach this PostgreSQL server.", loading: false)}

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["export", "import"],
    do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("export_format", %{"format" => format}, socket) when format in ["dump", "zip"],
    do: {:noreply, assign(socket, :format, format)}

  def handle_event("export", %{"format" => format}, socket) when format in ["dump", "zip"] do
    enqueue(socket, %{operation: "export", format: format})
  end

  def handle_event("validate_import", params, socket) do
    {:noreply,
     assign(socket,
       confirmation: params["confirmation"] || "",
       restore_mode: params["restore_mode"] || "add",
       ownership: params["ownership"] || "preserve"
     )}
  end

  def handle_event("import", params, socket) do
    {complete, pending} = uploaded_entries(socket, :backup)

    cond do
      !socket.assigns.info ->
        {:noreply, put_flash(socket, :error, "Choose an available database first.")}

      params["confirmation"] != socket.assigns.database ->
        {:noreply, put_flash(socket, :error, "Type the exact destination database name.")}

      length(complete) != 1 or pending != [] ->
        {:noreply, put_flash(socket, :error, "Wait for one backup file to finish uploading.")}

      true ->
        results =
          consume_uploaded_entries(socket, :backup, fn meta, entry ->
            attrs =
              target_attrs(socket)
              |> Map.merge(%{
                operation: "import",
                format:
                  if(String.ends_with?(String.downcase(entry.client_name), ".zip"),
                    do: "zip",
                    else: "dump"
                  ),
                restore_mode: params["restore_mode"],
                ownership: params["ownership"],
                confirmation: params["confirmation"]
              })

            case Backups.enqueue(attrs, socket.assigns.current_admin_email, meta.path) do
              {:ok, job} -> {:ok, {:ok, job}}
              {:error, error} -> {:postpone, {:error, error}}
            end
          end)

        case results do
          [{:ok, _}] ->
            {:noreply,
             socket
             |> assign(:confirmation, "")
             |> load()
             |> put_flash(:info, "Restore queued. A safety backup is created before any changes.")}

          [{:error, error}] ->
            {:noreply, put_flash(socket, :error, error)}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not queue this restore.")}
        end
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    case Enum.find(socket.assigns.uploads.backup.entries, &(&1.ref == ref)) do
      nil -> {:noreply, socket}
      entry -> {:noreply, discard_upload(socket, entry)}
    end
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Backups.cancel(id, socket.assigns.current_admin_email) do
      :ok ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, "Cancellation requested. Wait for the final status before retrying.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Backups.delete(id, socket.assigns.current_admin_email) do
      :ok ->
        {:noreply,
         socket |> load() |> put_flash(:info, "Backup files and history entry removed.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error)}
    end
  end

  @impl true
  def handle_info(:backups_changed, socket), do: {:noreply, assign(socket, :dirty, true)}

  def handle_info(:backup_tick, socket) do
    Process.send_after(self(), :backup_tick, 1000)

    case UI.check_session(socket) do
      {:ok, _} -> {:noreply, if(socket.assigns.dirty, do: load(socket), else: socket)}
      _ -> {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  defp enqueue(socket, attrs) do
    if socket.assigns.info do
      case Backups.enqueue(
             Map.merge(target_attrs(socket), attrs),
             socket.assigns.current_admin_email
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> load()
           |> put_flash(:info, "Export queued. You can leave this page while it runs.")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, error)}
      end
    else
      {:noreply, put_flash(socket, :error, "Choose an available database first.")}
    end
  end

  defp target_attrs(socket) do
    {host, port} = socket.assigns.target
    %{host: host, port: port, database: socket.assigns.database}
  end

  defp discard_upload(socket, %{done?: true} = entry) do
    consume_uploaded_entry(socket, entry, fn %{path: path} ->
      File.rm(path)
      {:ok, :removed}
    end)

    socket
  end

  defp discard_upload(socket, entry), do: cancel_upload(socket, :backup, entry.ref)

  defp load(socket) do
    jobs =
      case socket.assigns.target do
        {host, port} -> Backups.list(host, port, socket.assigns.database)
        _ -> []
      end

    socket
    |> assign(
      dirty: false,
      job_count: length(jobs),
      active_count: Enum.count(jobs, &(&1.status in ["queued", "running"]))
    )
    |> UI.sync_stream(:jobs, jobs)
  end

  defp size(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
  defp size(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp size(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp size(bytes), do: "#{bytes} B"
  defp upload_error(:too_large), do: "File exceeds the configured size limit."
  defp upload_error(:not_accepted), do: "Choose a .dump, .backup or .zip file."
  defp upload_error(:too_many_files), do: "Upload one backup at a time."
  defp upload_error(_), do: "Upload failed. Check server storage and try again."

  @impl true
  def render(assigns) do
    ~H"""
    <div class="backup-workspace">
      <.link navigate={~p"/admin/postgres?#{[server: @server]}"} class="text-button backup-back">
        <span class="hero-arrow-left" aria-hidden="true"></span> PostgreSQL
      </.link>
      <UI.header
        title="Database backups"
        subtitle="Export a snapshot or restore a backup to this database."
      >
        <:actions>
          <span class="status-badge">
            <span class="hero-circle-stack" aria-hidden="true"></span> {@database}
          </span>
        </:actions>
      </UI.header>
      <p :if={@loading} role="status" class="workspace-footnote">Checking database connection…</p>
      <p :if={@target_error} role="alert" class="notice notice-error">{@target_error}</p>
      <p :if={Enum.any?(@tools, fn {_, path} -> is_nil(path) end)} class="notice notice-error">
        Missing server tools: {Enum.filter(@tools, fn {_, path} -> is_nil(path) end)
        |> Enum.map_join(", ", &elem(&1, 0))}.
        Install PostgreSQL client tools and build the native backup worker to enable backups.
      </p>
      <div :if={@target} class="backup-context">
        <span>
          <span class="muted">Server</span> <code>{elem(@target, 0)}:{elem(@target, 1)}</code>
        </span>
        <span :if={@info}><span class="muted">Owner</span> <code>{@info.owner}</code></span>
        <span><span class="muted">In progress</span> {@active_count}</span>
        <span><span class="muted">File limit</span> {size(Backups.max_bytes())}</span>
      </div>
      <UI.tabs tabs={[{"export", "Export backup"}, {"import", "Import / restore"}]} active={@tab} />
      <section hidden={@tab != "export"} class="backup-editor">
        <div class="backup-explanation">
          <h2>A portable database snapshot</h2>
          <p>
            Includes schemas, tables, data and database objects. Export runs in the background; your database stays available.
          </p>
          <p class="muted">
            Cluster-wide roles and tablespaces are not included. Download a copy to keep it outside this server.
          </p>
        </div>
        <form
          phx-submit="export"
          phx-change="export_format"
          class="backup-form"
          id="backup-export-form"
        >
          <.input
            type="select"
            name="format"
            label="Download format"
            value={@format}
            options={[
              {"PostgreSQL archive (.dump) — compressed", "dump"},
              {"ZIP archive (.zip) — dump + manifest", "zip"}
            ]}
          />
          <div class="form-actions">
            <button
              type="submit"
              class="primary-button"
              disabled={!@info || Enum.any?(@tools, fn {_, path} -> is_nil(path) end)}
              phx-disable-with="Queuing…"
            >
              <span class="hero-arrow-down-tray" aria-hidden="true"></span> Create backup
            </button>
          </div>
        </form>
      </section>
      <section hidden={@tab != "import"} class="backup-editor">
        <div class="backup-explanation">
          <h2>Restore with a safety copy</h2>
          <p>
            The uploaded archive is checked first. A backup of <strong>{@database}</strong>
            is then saved before the restore starts.
          </p>
          <p class="muted">
            Only import backups from a trusted source. A restore can execute SQL from the archive. Use a maintenance window to avoid concurrent application writes.
          </p>
          <p :if={Backups.protected_database?(@database)} class="notice">
            This database stores the console itself. Export is available; restore it offline while the console is stopped.
          </p>
        </div>
        <form
          :if={!Backups.protected_database?(@database)}
          id="backup-import-form"
          phx-submit="import"
          phx-change="validate_import"
          class="backup-form"
        >
          <div class="backup-upload" phx-drop-target={@uploads.backup.ref}>
            <label for={@uploads.backup.ref}>Backup file</label>
            <.live_file_input upload={@uploads.backup} />
            <p class="workspace-footnote">
              Drop or select one .dump, .backup or ZIP containing one PostgreSQL archive. Up to {size(
                Backups.max_bytes()
              )}.
            </p>
            <div :for={entry <- @uploads.backup.entries} class="backup-upload-progress">
              <div>
                <strong>{entry.client_name}</strong><span>{entry.progress}%</span><button
                  type="button"
                  class="text-button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                >Remove</button>
              </div>
              <progress
                value={entry.progress}
                max="100"
                aria-label={"Upload progress for " <> entry.client_name}
              >
                {entry.progress}%
              </progress>
              <p
                :for={error <- upload_errors(@uploads.backup, entry)}
                role="alert"
                class="notice notice-error"
              >
                {upload_error(error)}
              </p>
            </div>
            <p :for={error <- upload_errors(@uploads.backup)} role="alert" class="notice notice-error">
              {upload_error(error)}
            </p>
          </div>
          <.input
            type="select"
            name="restore_mode"
            label="Existing objects"
            value={@restore_mode}
            options={[
              {"Keep existing objects — stop on conflicts", "add"},
              {"Replace objects included in the backup", "replace"}
            ]}
          />
          <p class="workspace-footnote">
            Replace drops and recreates objects listed in the archive. Other objects remain. A failed restore rolls back its changes.
          </p>
          <.input
            type="select"
            name="ownership"
            label="Ownership and permissions"
            value={@ownership}
            options={[
              {"Preserve archive owners and permissions", "preserve"},
              {"Use destination owner; skip archive permissions", "target"}
            ]}
          />
          <p class="workspace-footnote">
            Preserving ownership requires the original PostgreSQL roles to exist. Destination owner mode is useful when moving between servers.
          </p>
          <.input
            type="text"
            name="confirmation"
            label={"Type “#{@database}” to confirm the destination"}
            value={@confirmation}
            autocomplete="off"
            required
          />
          <div class="form-actions">
            <button
              type="submit"
              class="primary-button"
              phx-disable-with="Queuing…"
              disabled={
                !@info || @confirmation != @database || @uploads.backup.entries == [] ||
                  Enum.any?(@uploads.backup.entries, &(!&1.done?)) ||
                  Enum.any?(@tools, fn {_, path} -> is_nil(path) end)
              }
            >
              <span class="hero-arrow-up-tray" aria-hidden="true"></span> Back up &amp; restore
            </button>
          </div>
        </form>
      </section>
      <section class="backup-history" aria-labelledby="backup-history-heading">
        <div class="workbench-toolbar">
          <h2 id="backup-history-heading">History <span class="muted small">{@job_count}</span></h2>
          <span class="muted small" role="status">Updates automatically</span>
        </div>
        <p :if={@job_count == 0} class="empty-copy">
          No backups yet. Create your first snapshot or upload an archive to restore.
        </p>
        <div id="backup-history" phx-update="stream" class="backup-jobs">
          <article :for={{id, job} <- @streams.jobs} id={id} class="backup-job">
            <div class="backup-job-title">
              <span class={UI.status_class(job.status)}>{String.capitalize(job.status)}</span>
              <strong>
                {if job.operation == "export", do: "Export", else: "Restore"}
                <span class="muted">· {String.upcase(job.format)}</span>
              </strong>
              <time datetime={DateTime.to_iso8601(job.inserted_at)}>{UI.time(job.inserted_at)}</time>
            </div>
            <div class="backup-job-body">
              <span>{job.stage}</span><span :if={job.bytes > 0}>{size(job.bytes)}</span><code>{UI.short(job.id)}</code>
            </div>
            <div class="backup-job-actions">
              <a
                :if={job.operation == "export" && job.status == "completed"}
                href={~p"/admin/postgres/backups/#{job.id}/export"}
                class="text-button"
              >
                <span class="hero-arrow-down-tray" aria-hidden="true"></span>
                Download {String.upcase(job.format)}
              </a>
              <a
                :if={job.safety_bytes > 0 && job.status not in ["queued", "running"]}
                href={~p"/admin/postgres/backups/#{job.id}/safety"}
                class="text-button"
              >
                <span class="hero-shield-check" aria-hidden="true"></span>
                Safety backup · {size(job.safety_bytes)}
              </a>
              <button
                :if={job.status in ["queued", "running"]}
                class="text-button"
                phx-click="cancel"
                phx-value-id={job.id}
                phx-disable-with="Cancelling…"
              >
                Cancel operation
              </button>
              <button
                :if={job.status not in ["queued", "running"]}
                class="text-button muted"
                phx-click="delete"
                phx-value-id={job.id}
                data-confirm="Permanently remove this history entry and all of its backup files? Download anything you want to keep first."
              >
                Remove
              </button>
            </div>
            <details
              :if={job.error || job.sha256 || job.operation == "import"}
              class="backup-job-details"
            >
              <summary>{if job.error, do: "Operation details", else: "Backup details"}</summary>
              <p :if={job.operation == "import"}>
                Restore mode: {job.restore_mode}. Ownership: {job.ownership}. Destination: {job.database}.
              </p>
              <p :if={job.sha256}>SHA-256: <code>{job.sha256}</code></p>
              <pre :if={job.error}>{job.error}</pre>
            </details>
          </article>
        </div>
      </section>
      <p class="workspace-footnote">
        Backups run one at a time on this server. Files stay on server storage until you remove them; database records contain only status and file metadata. Storage quota: {size(
          Backups.config()[:quota_bytes]
        )}.
      </p>
    </div>
    """
  end
end
