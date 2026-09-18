defmodule Supavisor.ServiceAPI.AccessKey do
  @moduledoc "Named service credentials shared by REST and WebSocket clients."
  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset
  alias Supavisor.Repo

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "_supavisor"
  @scopes ~w(embedding:read embedding:run mail:read mail:send tts:run stt:run ai:run)
  schema "service_api_keys" do
    field :name, :string
    field :digest, :binary, redact: true
    field :fingerprint, :string
    field :scopes, {:array, :string}, default: []
    field :transports, {:array, :string}, default: []
    field :mailbox_ids, {:array, Ecto.UUID}, default: []
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def scopes, do: @scopes

  def list,
    do:
      Repo.all(
        from k in __MODULE__,
          order_by: [desc: k.inserted_at],
          limit: 100,
          select:
            map(k, [
              :id,
              :name,
              :fingerprint,
              :scopes,
              :transports,
              :mailbox_ids,
              :expires_at,
              :revoked_at,
              :inserted_at
            ])
      )

  def active,
    do:
      Repo.all(
        from k in __MODULE__,
          where:
            is_nil(k.revoked_at) and (is_nil(k.expires_at) or k.expires_at > ^DateTime.utc_now()),
          limit: 100
      )

  def create(params, actor) do
    supplied = Map.get(params, "token")

    token =
      if supplied in [nil, ""], do: Supavisor.ServiceAPI.Credential.generate(), else: supplied

    with :ok <- admin(actor),
         true <-
           (is_binary(token) and Regex.match?(~r/\A[A-Za-z0-9_-]{32,128}\z/, token)) ||
             {:error, "Use a random token of 32–128 letters, numbers, underscores or hyphens."},
         true <-
           Repo.aggregate(__MODULE__, :count) < 100 ||
             {:error, "Remove revoked keys before creating more."} do
      digest = :crypto.hash(:sha256, token)

      changeset =
        %__MODULE__{}
        |> cast(params, [:name, :scopes, :transports, :mailbox_ids, :expires_at])
        |> update_change(:name, &String.trim/1)
        |> validate_required([:name, :scopes, :transports])
        |> validate_length(:name, max: 80)
        |> validate_subset(:scopes, @scopes)
        |> validate_subset(:transports, ~w(rest websocket))
        |> validate_length(:mailbox_ids, max: 100)
        |> validate_change(:expires_at, fn :expires_at, expires ->
          if DateTime.compare(expires, DateTime.utc_now()) == :gt,
            do: [],
            else: [expires_at: "must be in the future"]
        end)
        |> validate_change(:mailbox_ids, fn :mailbox_ids, ids ->
          count =
            Repo.aggregate(
              from(m in Supavisor.Services.Mailbox, where: m.id in ^Enum.uniq(ids)),
              :count
            )

          if count == length(Enum.uniq(ids)),
            do: [],
            else: [mailbox_ids: "contains an unknown mailbox"]
        end)
        |> unique_constraint(:digest, message: "this token already belongs to a key")
        |> put_change(:digest, digest)
        |> put_change(:fingerprint, binary_part(Base.encode16(digest, case: :lower), 0, 12))

      case Repo.insert(changeset) do
        {:ok, key} ->
          Supavisor.ServiceAPI.KeyCache.refresh()
          Supavisor.Services.Events.changed()
          {:ok, key, token}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def revoke(id, actor) do
    with :ok <- admin(actor), {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.update_all(from(k in __MODULE__, where: k.id == ^id and is_nil(k.revoked_at)),
        set: [revoked_at: DateTime.utc_now()]
      )

      Supavisor.ServiceAPI.KeyCache.refresh()
      Supavisor.Services.Events.changed()
      :ok
    else
      _ -> {:error, "Could not revoke this key."}
    end
  end

  def delete(id, actor) do
    with :ok <- admin(actor), {:ok, id} <- Ecto.UUID.cast(id) do
      case Repo.delete_all(from k in __MODULE__, where: k.id == ^id and not is_nil(k.revoked_at)) do
        {1, _} ->
          Supavisor.Services.Events.changed()
          :ok

        _ ->
          {:error, "Only revoked keys can be removed."}
      end
    else
      _ -> {:error, "Only revoked keys can be removed."}
    end
  end

  def admin(email),
    do:
      if(email in SupavisorWeb.AdminSettings.uncached_admin_emails(),
        do: :ok,
        else: {:error, "Administrator access revoked."}
      )
end
