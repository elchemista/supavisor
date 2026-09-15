defmodule Supavisor.ServiceAPI.Credential do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Supavisor.Repo

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix "_supavisor"
  schema "service_api_settings" do
    field :token_digest, :binary, redact: true
    field :token_fingerprint, :string
    field :generation, Ecto.UUID
    timestamps(type: :utc_datetime_usec)
  end

  def read, do: Repo.get(__MODULE__, "services")
  def generate, do: "svc_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  def digest(token), do: :crypto.hash(:sha256, token)

  def save(token, actor) do
    cond do
      actor not in SupavisorWeb.AdminSettings.uncached_admin_emails() ->
        {:error, "Administrator access revoked."}

      token != nil && (!is_binary(token) || !Regex.match?(~r/\A[A-Za-z0-9_-]{32,128}\z/, token)) ->
        {:error, "Use 32–128 characters: letters, numbers, underscores or hyphens."}

      true ->
        hashed = if token, do: digest(token)

        %__MODULE__{id: "services"}
        |> change(
          token_digest: hashed,
          token_fingerprint:
            if(hashed, do: binary_part(Base.encode16(hashed, case: :lower), 0, 12)),
          generation: Ecto.UUID.generate()
        )
        |> Repo.insert(
          on_conflict: {:replace, [:token_digest, :token_fingerprint, :generation, :updated_at]},
          conflict_target: [:id],
          returning: true
        )
        |> case do
          {:ok, saved} -> {:ok, saved}
          {:error, _} -> {:error, "Could not save the API token."}
        end
    end
  rescue
    _ -> {:error, "Could not save the API token. Check the database connection."}
  end
end
