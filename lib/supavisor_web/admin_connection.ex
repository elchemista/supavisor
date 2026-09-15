defmodule SupavisorWeb.AdminConnection do
  @moduledoc false

  def host, do: Application.get_env(:supavisor, :public_pooler_host, "localhost")

  def uri(scheme, username, password, database, port) do
    host = if String.contains?(host(), ":"), do: "[#{host()}]", else: host()
    "#{scheme}://#{encode(username)}:#{encode(password)}@#{host}:#{port}/#{encode(database)}"
  end

  defp encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
