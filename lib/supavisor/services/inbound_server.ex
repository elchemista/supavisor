defmodule Supavisor.Services.InboundServer do
  @moduledoc "Controls the local SMTP receiver; binding and TLS are deployment configuration."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def status, do: GenServer.call(__MODULE__, :status)
  def toggle(enabled), do: GenServer.call(__MODULE__, {:toggle, enabled})
  @impl true
  def init(_) do
    config = Application.get_env(:supavisor, :inbound_smtp, [])
    state = %{pid: nil, error: nil, config: config}
    {:ok, if(config[:enabled], do: start(state), else: state)}
  end

  @impl true
  def handle_call(:status, _, state) do
    running =
      Enum.any?(DynamicSupervisor.which_children(Supavisor.InboundSupervisor), fn {_, pid, _, _} ->
        is_pid(pid)
      end)

    {:reply,
     %{
       running: running,
       error: state.error,
       port: state.config[:port],
       address: state.config[:address] |> :inet.ntoa() |> to_string(),
       hostname: state.config[:hostname]
     }, state}
  end

  def handle_call({:toggle, true}, _, state), do: {:reply, :ok, start(state)}

  def handle_call({:toggle, false}, _, state) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Supavisor.InboundSupervisor),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(Supavisor.InboundSupervisor, pid)

    Supavisor.Services.Events.changed()
    {:reply, :ok, %{state | pid: nil, error: nil}}
  end

  defp start(state) do
    if DynamicSupervisor.count_children(Supavisor.InboundSupervisor).active > 0 do
      state
    else
      opts =
        Keyword.drop(state.config, [:enabled]) ++
          [
            name: Supavisor.ServiceSMTP,
            adapter: Supavisor.Services.IncomingMail,
            decode: true,
            max_size: 1_048_576,
            max_recipients: 10,
            max_connections: 50,
            num_acceptors: 2
          ]

      case DynamicSupervisor.start_child(Supavisor.InboundSupervisor, {Postbeam.Inbound, opts}) do
        {:ok, pid} ->
          Supavisor.Services.Events.changed()
          %{state | pid: pid, error: nil}

        {:error, _} ->
          %{
            state
            | pid: nil,
              error: "Could not bind the SMTP listener. Check the address and port."
          }
      end
    end
  end
end
