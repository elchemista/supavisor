defmodule Supavisor.Monitoring.ModelMetrics do
  @moduledoc """
  Bounded, in-memory request metrics for model integrations.

  Wrap the complete provider operation, including consuming a streamed response:

      ModelMetrics.track(:ai_model, fn -> provider_request() end)

  Supported services are :ai_model, :embedding, :stt and :tts. A returned
  {:error, reason}, exception, throw or exit counts as a failure. Retries inside
  the function count as one logical request. No prompts, responses, request IDs
  or user-controlled model names are retained.
  """

  @table __MODULE__
  @handler_id {__MODULE__, :requests}
  @prefix [:supavisor, :model, :request]
  @services [:ai_model, :embedding, :stt, :tts]

  def services, do: @services

  def init do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      write_concurrency: true,
      read_concurrency: true
    ])

    for service <- @services, do: :ets.insert(@table, {service, 0, 0, 0, 0})
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        Enum.map([:start, :stop, :exception], &(@prefix ++ [&1])),
        &__MODULE__.handle_event/4,
        nil
      )
  end

  def detach, do: :telemetry.detach(@handler_id)

  def track(service, fun) when service in @services and is_function(fun, 0) do
    :telemetry.span(@prefix, %{service: service}, fn ->
      result = fun.()
      outcome = if match?({:error, _}, result), do: :error, else: :ok
      {result, %{service: service, outcome: outcome}}
    end)
  end

  def handle_event(@prefix ++ [:start], _measurements, %{service: service}, _)
      when service in @services do
    update(service, [{5, 1}])
  end

  def handle_event(@prefix ++ [event], %{duration: duration}, %{service: service} = metadata, _)
      when event in [:stop, :exception] and service in @services and is_integer(duration) do
    failure? = event == :exception || metadata[:outcome] == :error
    # Each row is {service, successes, errors, total_duration_us, in_flight}.
    update(service, [
      {if(failure?, do: 3, else: 2), 1},
      {4, max(0, System.convert_time_unit(duration, :native, :microsecond))},
      {5, -1, 0, 0}
    ])
  end

  def handle_event(_, _, _, _), do: :ok

  def snapshot do
    Enum.map(@services, fn service ->
      case :ets.lookup(@table, service) do
        [{^service, successes, errors, duration_us, in_flight}] ->
          completed = successes + errors

          %{
            id: service,
            completed: completed,
            successes: successes,
            errors: errors,
            in_flight: in_flight,
            average_ms: if(completed > 0, do: duration_us / completed / 1000, else: nil)
          }
      end
    end)
  end

  defp update(service, operations) do
    :ets.update_counter(@table, service, operations)
    :ok
  rescue
    # Metrics must never interrupt a provider request during collector restarts.
    ArgumentError -> :ok
  end
end
