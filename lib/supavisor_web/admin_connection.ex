defmodule SupavisorWeb.AdminConnection do
  @moduledoc false

  def host(request_host \\ nil) do
    Application.get_env(:supavisor, :public_pooler_host) || request_host ||
      URI.parse(SupavisorWeb.Endpoint.url()).host || "localhost"
  end

  def uri(scheme, username, password, database, port, hostname \\ host()) do
    host = if String.contains?(hostname, ":"), do: "[#{hostname}]", else: hostname
    "#{scheme}://#{encode(username)}:#{encode(password)}@#{host}:#{port}/#{encode(database)}"
  end

  defp encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
