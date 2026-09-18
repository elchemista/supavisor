defmodule Supavisor.Services.Events do
  @moduledoc false
  def subscribe, do: Phoenix.PubSub.subscribe(Supavisor.PubSub, "admin:services")
  def changed, do: Phoenix.PubSub.broadcast(Supavisor.PubSub, "admin:services", :services_changed)

  def request(owner, data) do
    changed()
    Phoenix.PubSub.broadcast(Supavisor.PubSub, "services:key:#{owner}", {:request_updated, data})
  end

  def error(code, message), do: {:error, %{code: code, message: message}}

  def errors(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, opts}} ->
      message =
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      "#{field}: #{message}"
    end)
    |> Enum.join(" · ")
  end

  def errors(message) when is_binary(message), do: message
  def errors(_), do: "Could not save. Check the entered values."
  def uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
