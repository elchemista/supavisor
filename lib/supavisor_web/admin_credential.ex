defmodule SupavisorWeb.AdminCredential do
  @moduledoc "Administrator passwords, independent of email delivery and database credentials."
  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset
  alias Supavisor.Repo
  alias SupavisorWeb.{AdminAccessCache, AdminAuth}

  @iterations 600_000
  @primary_key {:email, :string, autogenerate: false}
  @schema_prefix "_supavisor"
  schema "admin_credentials" do
    field :password_hash, :string, redact: true
    field :session_version, Ecto.UUID
    timestamps(type: :utc_datetime_usec)
  end

  def configured?(email), do: not is_nil(session_version(email))

  def session_version(email),
    do: Map.get(AdminAccessCache.credential_versions(), normalize(email))

  def versions do
    emails = SupavisorWeb.AdminSettings.uncached_admin_emails()

    Repo.all(
      from c in __MODULE__, where: c.email in ^emails, select: {c.email, c.session_version}
    )
    |> Map.new()
  end

  def authenticate(email, password) when is_binary(email) and is_binary(password) do
    email = normalize(email)
    credential = if byte_size(email) <= 254, do: Repo.get(__MODULE__, email)

    if verify(password, credential) and AdminAuth.admin_email?(email) do
      {:ok, credential.session_version}
    else
      {:error, :invalid_credentials}
    end
  end

  def authenticate(_, _), do: {:error, :invalid_credentials}

  @doc "Resets an existing administrator's password from the trusted server console only."
  def reset_password(email) when is_binary(email) do
    email = normalize(email)

    if AdminAuth.admin_email?(email) do
      password = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

      with {:ok, _version} <- persist(Repo.get(__MODULE__, email), email, password) do
        SupavisorWeb.AdminLoginLimiter.succeeded(email)
        {:ok, password}
      end
    else
      {:error, "That email is not an authorized administrator."}
    end
  end

  def save_password(email, params) when is_map(params) do
    email = normalize(email)
    credential = Repo.get(__MODULE__, email)
    password = params["new_password"]

    cond do
      not AdminAuth.admin_email?(email) ->
        {:error, "Administrator access revoked."}

      credential && not verify(params["current_password"], credential) ->
        {:error, "Your current password is incorrect."}

      not valid_new_password?(password) ->
        {:error, "Use a password of 15–128 characters."}

      password != params["password_confirmation"] ->
        {:error, "The new passwords do not match."}

      true ->
        persist(credential, email, password)
    end
  end

  defp persist(credential, email, password) do
    version = Ecto.UUID.generate()
    hash = hash_password(password)

    result =
      if credential do
        # A concurrent password change must not be overwritten using stale credentials.
        query =
          from c in __MODULE__,
            where: c.email == ^email and c.session_version == ^credential.session_version

        case Repo.update_all(query,
               set: [
                 password_hash: hash,
                 session_version: version,
                 updated_at: DateTime.utc_now()
               ]
             ) do
          {1, _} -> :ok
          _ -> :conflict
        end
      else
        %__MODULE__{email: email, password_hash: hash, session_version: version}
        |> change()
        |> unique_constraint(:email, name: :admin_credentials_pkey)
        |> Repo.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, _} -> :conflict
        end
      end

    case result do
      :ok ->
        AdminAccessCache.invalidate()
        {:ok, version}

      _ ->
        {:error, "Your password changed in another session. Sign in again."}
    end
  end

  defp valid_new_password?(password) when is_binary(password) do
    byte_size(password) <= 1024 and String.valid?(password) and
      String.length(password) in 15..128
  end

  defp valid_new_password?(_), do: false

  defp hash_password(password) do
    salt = :crypto.strong_rand_bytes(32)
    hash = :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32)
    Enum.join(["pbkdf2-sha256", @iterations, Base.encode64(salt), Base.encode64(hash)], "$")
  end

  defp verify(password, credential) when is_binary(password) and byte_size(password) <= 1024 do
    case credential do
      %__MODULE__{password_hash: encoded} ->
        with ["pbkdf2-sha256", iterations, salt, expected] <- String.split(encoded, "$"),
             {iterations, ""} when iterations in 600_000..2_000_000 <- Integer.parse(iterations),
             {:ok, salt} when byte_size(salt) == 32 <- Base.decode64(salt),
             {:ok, expected} when byte_size(expected) == 32 <- Base.decode64(expected) do
          actual = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)
          Plug.Crypto.secure_compare(actual, expected)
        else
          _ -> dummy_verify(password)
        end

      nil ->
        dummy_verify(password)
    end
  end

  defp verify(_, _), do: false

  defp dummy_verify(password) do
    # Unknown accounts still pay the same derivation cost; errors remain generic.
    :crypto.pbkdf2_hmac(:sha256, password, <<0::256>>, @iterations, 32)
    false
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
