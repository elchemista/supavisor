defmodule SupavisorWeb.AdminNavigation do
  @moduledoc false

  def groups do
    [
      {"Workspace",
       [
         %{id: :tenants, label: "Tenants", path: "/admin", icon: "hero-square-3-stack-3d"},
         %{
           id: :postgres,
           label: "PostgreSQL",
           path: "/admin/postgres",
           icon: "hero-circle-stack"
         },
         %{id: :metrics, label: "Metrics", path: "/admin/metrics", icon: "hero-chart-bar-square"},
         %{id: :api, label: "API", path: "/admin/api", icon: "hero-code-bracket"},
         %{id: :mailer, label: "Mailer", path: "/admin/mailer", icon: "hero-envelope"},
         %{
           id: :authorization,
           label: "Authorization",
           path: "/admin/authorization",
           icon: "hero-shield-check"
         }
       ]},
      {"Intelligence",
       [
         %{
           id: :embedding,
           label: "Embedding",
           path: "/admin/embedding",
           icon: "hero-cube-transparent"
         },
         %{id: :stt, label: "STT", path: "/admin/stt", icon: "hero-microphone"},
         %{id: :tts, label: "TTS", path: "/admin/tts", icon: "hero-speaker-wave"},
         %{id: :ai_model, label: "AI model", path: "/admin/ai-model", icon: "hero-sparkles"}
       ]}
    ]
  end

  def items, do: Enum.flat_map(groups(), &elem(&1, 1))

  def section("/admin/postgres/backups"), do: section("/admin/postgres")

  def section("/admin/provision"), do: section("/admin/postgres")

  def section(path) do
    Enum.find(items(), &(&1.path == path)) || hd(items())
  end

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:navigation, section("/admin"))
      |> Phoenix.LiveView.attach_hook(:admin_navigation, :handle_params, fn _params,
                                                                            url,
                                                                            socket ->
        {:cont, Phoenix.Component.assign(socket, :navigation, section(URI.parse(url).path))}
      end)

    {:cont, socket}
  end
end
