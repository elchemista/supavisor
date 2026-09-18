defmodule Supavisor.Services.ModelIdle do
  @moduledoc "Shared five-minute idle policy. Only native model use renews the deadline."
  @timeout_ms 300_000

  def timeout_ms, do: @timeout_ms
  def now, do: System.monotonic_time(:millisecond)
  def expired?(last_used), do: now() - last_used >= @timeout_ms

  def schedule(last_used) do
    token = make_ref()

    timer =
      Process.send_after(self(), {:model_idle, token}, max(0, last_used + @timeout_ms - now()))

    {timer, token}
  end

  def cancel(nil), do: nil

  def cancel({timer, _}) do
    Process.cancel_timer(timer)
    nil
  end
end
