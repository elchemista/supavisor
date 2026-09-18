defmodule Supavisor.Services.Dispatcher do
  @moduledoc "One permission and service boundary for REST and Phoenix Channels."
  alias Supavisor.ServiceAPI.KeyCache
  alias Supavisor.Services.{Embeddings, Mail, Events, Inference, Media}

  def call(principal, event, params) when is_map(params) do
    dispatch(principal, event, params)
  rescue
    Ecto.Query.CastError ->
      Events.error("invalid_input", "Invalid resource identifier.")

    Ecto.NoResultsError ->
      Events.error("not_found", "Resource not found.")

    DBConnection.ConnectionError ->
      Events.error("unavailable", "Storage is unavailable. Try again shortly.")
  catch
    :exit, _ -> Events.error("unavailable", "Service is restarting. Try again shortly.")
  end

  def call(_, _, _), do: Events.error("invalid_input", "Expected a JSON object.")

  defp dispatch(principal, "gateway:status", _) do
    {:ok,
     %{
       status: "authenticated",
       transports: principal.transports,
       scopes: principal.scopes,
       services: ["embedding", "mailer", "tts", "stt", "ai"],
       time: DateTime.utc_now()
     }}
  end

  defp dispatch(principal, "models:list", %{"service" => service})
       when service in ["tts", "stt", "ai"] do
    service =
      case service do
        "tts" -> :tts
        "stt" -> :stt
        "ai" -> :ai_model
      end

    with :ok <- permit(principal, Supavisor.Services.LocalModels.Models.scope(service)) do
      model = Supavisor.Services.LocalModels.Models.info(service)

      {:ok,
       %{
         models: [Map.take(model, [:id, :name, :ready, :loaded, :bytes, :missing])],
         idle_timeout_seconds: 300
       }}
    end
  end

  defp dispatch(principal, "models:list", _) do
    with :ok <- permit(principal, "embedding:read") do
      state = Embeddings.snapshot()

      {:ok,
       %{
         models: state.models,
         active: state.active,
         loaded: state.loaded,
         memory_state: state.memory_state,
         idle_timeout_seconds: state.idle_timeout_seconds,
         loading: state.memory_state == "loading"
       }}
    end
  end

  defp dispatch(principal, "tts:run", params), do: Inference.submit(:tts, params, principal)
  defp dispatch(principal, "stt:run", params), do: Inference.submit(:stt, params, principal)
  defp dispatch(principal, "ai:run", params), do: Inference.submit(:ai_model, params, principal)

  defp dispatch(principal, "audio:upload:start", params),
    do: Media.start_upload(params, principal)

  defp dispatch(principal, "audio:upload:chunk", %{"id" => id, "offset" => offset, "data" => data})
       when is_binary(data) and byte_size(data) <= 65_536 do
    case Base.decode64(data) do
      {:ok, bytes} -> Media.chunk(id, offset, bytes, principal)
      _ -> Events.error("invalid_audio", "Chunk must be base64 audio bytes.")
    end
  end

  defp dispatch(principal, "audio:upload:finish", %{"id" => id}), do: Media.finish(id, principal)

  defp dispatch(principal, "audio:upload:abort", %{"id" => id}) do
    :ok = Media.abort(id, principal)
    {:ok, %{status: "cancelled"}}
  end

  defp dispatch(principal, "embedding:run", params), do: Embeddings.submit(params, principal)
  defp dispatch(principal, "mail:send", params), do: Mail.enqueue(params, principal)

  defp dispatch(principal, "mailboxes:list", _) do
    with :ok <- permit(principal, "mail:read"),
         do: {:ok, %{mailboxes: Mail.public_mailboxes(principal)}}
  end

  defp dispatch(principal, "mail:list", params) do
    with :ok <- permit(principal, "mail:read"), do: {:ok, Mail.list(params, principal)}
  end

  defp dispatch(principal, "mail:get", %{"id" => id}), do: Mail.get(id, principal)

  defp dispatch(principal, "request:get", %{"id" => id}) do
    case Embeddings.request(id, principal) do
      {:ok, result} ->
        {:ok, result}

      _ ->
        case Inference.request(id, principal) do
          {:ok, result} -> {:ok, result}
          _ -> Mail.request(id, principal)
        end
    end
  end

  defp dispatch(principal, "request:cancel", %{"id" => id}) do
    case Embeddings.request(id, principal) do
      {:ok, _} ->
        Embeddings.cancel(id, principal)

      _ ->
        case Inference.request(id, principal) do
          {:ok, _} -> Inference.cancel(id, principal)
          _ -> Mail.cancel(id, principal)
        end
    end
  end

  defp dispatch(principal, "request:submit", %{"service" => "embedding", "payload" => payload}),
    do: call(principal, "embedding:run", payload)

  defp dispatch(principal, "request:submit", %{"service" => "mailer", "payload" => payload}),
    do: call(principal, "mail:send", payload)

  defp dispatch(principal, "request:submit", %{"service" => service, "payload" => payload})
       when service in ["tts", "stt", "ai"], do: call(principal, service <> ":run", payload)

  defp dispatch(_, _, _),
    do: Events.error("unsupported_event", "Unknown event or missing parameters.")

  defp permit(principal, scope),
    do:
      if(KeyCache.allowed?(principal, scope),
        do: :ok,
        else: Events.error("forbidden", "#{scope} permission required.")
      )
end
