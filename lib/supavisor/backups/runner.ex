defmodule Supavisor.Backups.Runner do
  @moduledoc false
  alias Supavisor.Backups

  def run(job, coordinator) do
    with true <- Backups.admin?(job.created_by),
         {:ok, info} <- Backups.target_info(job.host, job.port, job.database) do
      provisioner =
        Application.fetch_env!(:supavisor, SupavisorWeb.AdminProvisioning)[:provisioner]

      ssl_opts = provisioner[:ssl_opts] || []

      ssl_mode =
        cond do
          !provisioner[:ssl] -> "disable"
          ssl_opts[:verify] == :verify_none -> "require"
          true -> "verify-full"
        end

      payload = %{
        operation: job.operation,
        format: job.format,
        mode: job.restore_mode,
        ownership: job.ownership,
        owner: info.owner,
        database: job.database,
        server_version: info.version,
        host: job.host,
        port: job.port,
        username: provisioner[:username],
        password: provisioner[:password],
        ssl_mode: ssl_mode,
        ssl_root_cert: to_string(ssl_opts[:cacertfile] || "system"),
        directory: Backups.job_dir(job.id),
        root: Backups.root(),
        max_bytes: Backups.max_bytes(),
        quota_bytes: Backups.config()[:quota_bytes],
        timeout: Backups.config()[:timeout_seconds],
        tools: Backups.tools()
      }

      port =
        Port.open({:spawn_executable, String.to_charlist(Backups.tools()["service_runner"])}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:line, 65_536}
        ])

      Port.command(port, Jason.encode!(payload) <> "\n")

      try do
        collect(port, coordinator, job.id, nil, "")
      after
        if Port.info(port), do: Port.close(port)
      end
    else
      _ ->
        %{
          status: "failed",
          error: "Administrator access or database connection is no longer available."
        }
    end
  rescue
    _ ->
      %{
        status: "failed",
        error: "Backup process failed to start. Check tools, permissions and storage."
      }
  end

  defp collect(port, coordinator, id, result, fragment) do
    receive do
      {^port, {:data, {:noeol, data}}} ->
        collect(
          port,
          coordinator,
          id,
          result,
          binary_part(fragment <> data, 0, min(byte_size(fragment <> data), 65_536))
        )

      {^port, {:data, {:eol, data}}} ->
        case Jason.decode(fragment <> data) do
          {:ok, %{"event" => "stage", "stage" => stage}} ->
            GenServer.cast(coordinator, {:stage, id, String.slice(stage, 0, 100)})
            collect(port, coordinator, id, result, "")

          {:ok, %{"event" => "result"} = data} ->
            result = %{
              status: data["status"],
              error: data["error"],
              bytes: data["bytes"] || 0,
              safety_bytes: data["safety_bytes"] || 0,
              sha256: data["sha256"]
            }

            collect(port, coordinator, id, result, "")

          _ ->
            collect(port, coordinator, id, result, "")
        end

      {^port, {:exit_status, code}} ->
        if code != 0 && result && result.status == "completed" do
          %{
            result
            | status: "failed",
              error:
                "Command worker exited unexpectedly after reporting completion. Check the destination before retrying an import."
          }
        else
          result ||
            %{
              status: "failed",
              error: "Backup worker interrupted. Check the target before retrying an import."
            }
        end

      :cancel ->
        Port.command(port, "cancel\n")
        collect(port, coordinator, id, result, fragment)
    after
      (Backups.config()[:timeout_seconds] + 30) * 1000 ->
        Port.command(port, "cancel\n")

        %{
          status: "failed",
          error: "Backup operation timed out. Check the target before retrying."
        }
    end
  end
end
