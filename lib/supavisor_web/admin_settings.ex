defmodule SupavisorWeb.AdminSettings do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset
  alias Supavisor.Repo

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix "_supavisor"
  schema "admin_settings" do
    field :admin_emails, {:array, :string}, default: []
    field :github_enabled, :boolean, default: false
    field :github_client_id, :string
    field :github_client_secret, Supavisor.Encrypted.Binary, redact: true
    field :github_redirect_uri, :string
    timestamps()
  end

  def get, do: Repo.get(__MODULE__, "authorization") || defaults()

  def admin_emails, do: SupavisorWeb.AdminAccessCache.emails()

  def uncached_admin_emails do
    case Repo.one(from s in __MODULE__, where: s.id == "authorization", select: s.admin_emails) do
      nil -> defaults().admin_emails
      emails -> emails
    end
  end

  def github_config do
    config = get()

    if config.github_enabled && present?(config.github_client_id) &&
         present?(config.github_client_secret) do
      {:ok,
       %{
         client_id: config.github_client_id,
         client_secret: config.github_client_secret,
         redirect_uri: config.github_redirect_uri
       }}
    else
      :disabled
    end
  end

  def save_admins(raw, actor) when is_binary(raw) do
    emails = raw |> String.split(~r/[\s,;]+/, trim: true) |> Enum.map(&normalize/1) |> Enum.uniq()

    cond do
      byte_size(raw) > 25_500 || length(emails) > 100 ->
        {:error, "You can configure up to 100 administrators."}

      emails == [] ->
        {:error, "Keep at least one administrator."}

      Enum.any?(
        emails,
        &(String.length(&1) > 254 || !Regex.match?(~r/^[^\s@<>]+@[^\s@<>]+$/, &1))
      ) ->
        {:error, "Check the email addresses you entered."}

      normalize(actor) not in emails ->
        {:error, "Keep your own email in the list to preserve your access."}

      true ->
        persist_settings(actor, &change(&1, admin_emails: emails))
    end
  end

  def save_github(params, actor) do
    persist_settings(actor, fn settings ->
      params =
        Map.take(params, [
          "github_enabled",
          "github_client_id",
          "github_client_secret",
          "github_redirect_uri"
        ])

      params =
        if String.trim(params["github_client_secret"] || "") == "",
          do: Map.delete(params, "github_client_secret"),
          else: params

      settings
      |> cast(params, [
        :github_enabled,
        :github_client_id,
        :github_client_secret,
        :github_redirect_uri
      ])
      |> update_change(:github_client_id, &String.trim/1)
      |> update_change(:github_redirect_uri, &String.trim/1)
      |> validate_length(:github_client_id, max: 255)
      |> validate_length(:github_client_secret, max: 1024)
      |> validate_length(:github_redirect_uri, max: 2048)
      |> validate_github()
    end)
  end

  defp validate_github(changeset) do
    if get_field(changeset, :github_enabled) do
      changeset =
        changeset
        |> force_change(:github_client_id, get_field(changeset, :github_client_id))
        |> validate_required([:github_client_id, :github_client_secret, :github_redirect_uri])
        |> validate_format(:github_client_id, ~r/^[A-Za-z0-9_.-]+$/, message: "Invalid Client ID")

      if valid_callback?(get_field(changeset, :github_redirect_uri)) do
        changeset
      else
        add_error(
          changeset,
          :github_redirect_uri,
          "Use HTTPS (HTTP only on localhost) and the path /admin/auth/github/callback"
        )
      end
    else
      changeset
    end
  end

  defp valid_callback?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, uri} ->
        scheme_ok =
          uri.scheme == "https" ||
            (uri.scheme == "http" && uri.host in ["localhost", "127.0.0.1", "::1"])

        scheme_ok && present?(uri.host) && uri.port in 1..65_535 && uri.userinfo == nil &&
          uri.query == nil && uri.fragment == nil && uri.path == "/admin/auth/github/callback"

      _ ->
        false
    end
  end

  defp valid_callback?(_), do: false

  defp persist_settings(actor, fun) do
    result =
      Repo.transaction(fn ->
        Repo.insert!(defaults(), on_conflict: :nothing)

        settings =
          Repo.one!(from s in __MODULE__, where: s.id == "authorization", lock: "FOR UPDATE")

        if normalize(actor) not in settings.admin_emails,
          do: Repo.rollback("Administrator access revoked.")

        case Repo.update(fun.(settings)) do
          {:ok, saved} -> saved
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    if match?({:ok, _}, result), do: SupavisorWeb.AdminAccessCache.invalidate()
    result
  end

  defp defaults do
    config = Application.get_env(:supavisor, SupavisorWeb.AdminAuth, [])

    %__MODULE__{
      id: "authorization",
      admin_emails: Enum.map(config[:admin_emails] || [], &normalize/1),
      github_redirect_uri:
        String.trim_trailing(config[:base_url] || "http://localhost:4000", "/") <>
          "/admin/auth/github/callback"
    }
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()
  defp present?(value), do: is_binary(value) && String.trim(value) != ""
end
