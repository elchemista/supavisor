defmodule SupavisorWeb.Admin.ServicesLive do
  use SupavisorWeb, :live_view

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :service, service(socket.assigns.live_action))}
  end

  defp service(:mailer) do
    config = Application.get_env(:supavisor, Supavisor.Mailer, [])
    local? = config[:adapter] == Swoosh.Adapters.Local

    %{
      title: "Mailer",
      eyebrow: "MESSAGES THAT CONNECT",
      icon: "hero-envelope",
      headline: "Every message, in the right place.",
      description:
        "One place for workspace email: sign-in links, notifications and service messages.",
      status: if(local?, do: "Local adapter active", else: "Adapter configured"),
      ready: true,
      subtitle: "Your stack’s communication, organized.",
      chip: "EMAIL / SMTP",
      chip_bottom: "workspace → inbox",
      features: [
        {"hero-key", "Workspace sign-in",
         "Local sign-in is direct. On the server, sign-in links are sent to authorized administrators."},
        {"hero-server", "Your mail server",
         "The app’s SMTP configuration defines the relay, port, credentials and sender."},
        {"hero-inbox-stack", "Local development",
         "The local adapter keeps messages inside the app without delivering them to an external inbox."}
      ],
      setup_title: "Current configuration",
      setup_description:
        if(local?,
          do: "You do not need an email inbox to sign in locally.",
          else: "SMTP settings are read from the server configuration. Credentials stay private."
        ),
      config: [
        {"Adapter", inspect(config[:adapter])},
        {"Sender", format_sender(SupavisorWeb.AdminAuth.email_from())},
        {"Environment", if(local?, do: "Local", else: "Server")}
      ],
      note: "This status shows the configured adapter; SMTP delivery depends on your mail server."
    }
  end

  defp service(:embedding) do
    %{
      title: "Embedding",
      eyebrow: "GIVE YOUR DATA MEANING",
      icon: "hero-cube-transparent",
      headline: "Give your data a new dimension.",
      description:
        "A home for models that turn text and content into vectors for semantic search in your project.",
      subtitle: "From content to connections.",
      chip: "TEXT → VECTOR",
      chip_bottom: "semantic space",
      features: [
        {"hero-cube-transparent", "Vector models",
         "Choosing a model and dimensions will be the first step toward consistent embeddings."},
        {"hero-magnifying-glass", "Semantic search",
         "Embeddings can power search by meaning across your content."},
        {"hero-circle-stack", "PostgreSQL destination",
         "A database with vector support will need to be configured alongside your provider."}
      ],
      config: [
        {"Provider", "Not connected"},
        {"Model and dimensions", "Not selected"},
        {"Destination database", "Not configured"}
      ]
    }
    |> pending()
  end

  defp service(:stt) do
    %{
      title: "STT",
      eyebrow: "VOICE INTO KNOWLEDGE",
      icon: "hero-microphone",
      headline: "Turn voice into knowledge.",
      description:
        "A space for audio transcription, from voice notes to your project’s conversations.",
      subtitle: "Speech to text. A new shape for your voice.",
      chip: "AUDIO → TEXT",
      chip_bottom: "speech recognition",
      features: [
        {"hero-microphone", "Audio sources",
         "Your transcription integration will define supported audio formats and file limits."},
        {"hero-language", "Languages and models",
         "The provider you choose will determine available languages and transcription options."},
        {"hero-document-text", "Text ready to use",
         "Transcripts can become searchable content and inputs for your AI workflows."}
      ],
      config: [
        {"Provider STT", "Not connected"},
        {"Model", "Not selected"},
        {"Language", "Not configured"}
      ]
    }
    |> pending()
  end

  defp service(:tts) do
    %{
      title: "TTS",
      eyebrow: "A VOICE FOR YOUR IDEAS",
      icon: "hero-speaker-wave",
      headline: "Give your ideas a voice.",
      description:
        "Your starting point for speech synthesis: text, voices and audio from the provider you choose.",
      subtitle: "Text to speech. Your words, a new voice.",
      chip: "TEXT → AUDIO",
      chip_bottom: "voice synthesis",
      features: [
        {"hero-speaker-wave", "A recognizable voice",
         "Available voices will depend on the speech service connected to your workspace."},
        {"hero-adjustments-horizontal", "Audio controls",
         "Speed, language and format will follow the options supported by your selected model."},
        {"hero-arrow-down-tray", "Output for your apps",
         "The integration can produce audio files for the services in your project."}
      ],
      config: [
        {"Provider TTS", "Not connected"},
        {"Voice and model", "Not selected"},
        {"Audio format", "Not configured"}
      ]
    }
    |> pending()
  end

  defp service(:ai_model) do
    %{
      title: "AI model",
      eyebrow: "INTELLIGENCE, ON YOUR TERMS",
      icon: "hero-sparkles",
      headline: "The right model. In your workspace.",
      description:
        "A place to organize your project’s AI models and connect them to your services.",
      subtitle: "A home for your stack’s intelligence.",
      chip: "PROMPT → RESPONSE",
      chip_bottom: "your model, your choice",
      features: [
        {"hero-cpu-chip", "Model selection",
         "The integration will need a provider endpoint, model and authentication method."},
        {"hero-adjustments-horizontal", "Clear parameters",
         "Context, limits and generation settings will depend on the selected model."},
        {"hero-code-bracket", "Connected services",
         "The API section already provides a WebSocket channel that can be extended with model events."}
      ],
      config: [
        {"Provider / endpoint", "Not connected"},
        {"Default model", "Not selected"},
        {"Credentials", "Not configured"}
      ]
    }
    |> pending()
  end

  defp service(:imports) do
    %{
      title: "Imports",
      eyebrow: "BRING YOUR DATA HOME",
      icon: "hero-arrow-down-tray",
      headline: "Every source, a new beginning.",
      description:
        "A space for incoming data: sources, destinations and progress for future imports.",
      subtitle: "Your sources, flowing into your workspace.",
      chip: "SOURCE → WORKSPACE",
      chip_bottom: "data in motion",
      features: [
        {"hero-folder-open", "Data sources",
         "Your import workflow will be defined around the files and formats your project uses."},
        {"hero-circle-stack", "A clear destination",
         "Choose a database and mapping rules before transferring data."},
        {"hero-queue-list", "Visible progress",
         "Job processing will need to track results, errors and imports to resume."}
      ],
      config: [
        {"Sources", "Not defined"},
        {"Destination database", "Not selected"},
        {"File processing", "Not integrated"}
      ]
    }
    |> pending()
  end

  defp format_sender({name, email}), do: "#{name} <#{email}>"
  defp format_sender(email), do: to_string(email)

  defp pending(service) do
    Map.merge(service, %{
      status: "Not connected",
      ready: false,
      setup_title: "What you need to get started",
      setup_description:
        "This section is ready for your service. The integration still needs to be implemented and configured.",
      note:
        "No service is connected. The features above describe the planned workflow for this section."
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page-hero"><div><div class="eyebrow"><span class="eyebrow-line"></span><%= @service.eyebrow %></div><h1><%= @service.title %><span class="heading-dot">.</span></h1><p class="page-subtitle"><%= @service.subtitle %></p></div></section>
    <section class="service-hero">
      <div><span class={["status-badge", !@service.ready && "pending"]}><i class="status-dot"></i><%= @service.status %></span><h2><%= @service.headline %></h2><p><%= @service.description %></p><a href="#service-setup" class="secondary-button">Configuration details <span class="hero-arrow-down"></span></a></div>
      <div class="service-art" aria-hidden="true"><span class="art-orbit"></span><span class="art-orbit"></span><span class="art-orbit"></span><span class="art-core"><span class={@service.icon}></span></span><span class="art-chip top"><%= @service.chip %></span><span class="art-chip bottom"><%= @service.chip_bottom %></span></div>
    </section>
    <div class="service-section-title"><h2><%= if @service.ready, do: "In your workspace", else: "How it will fit your stack" %></h2></div>
    <div class="feature-grid"><article :for={{icon, title, description} <- @service.features} class="feature-card"><span class={icon}></span><h3><%= title %></h3><p><%= description %></p></article></div>
    <details class="setup-panel data-panel" id="service-setup" open>
      <summary><span class="hero-adjustments-horizontal"></span><%= @service.setup_title %><span class="hero-chevron-down"></span></summary>
      <div class="setup-content"><p><%= @service.setup_description %></p><dl class="config-list"><div :for={{label, value} <- @service.config}><dt><%= label %></dt><dd><%= value %></dd></div></dl></div>
    </details>
    <p class="service-note"><span class="hero-information-circle"></span><%= @service.note %></p>
    """
  end
end
