defmodule Supavisor.Services.Mailbox do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @schema_prefix "_supavisor"
  schema "service_mailboxes" do
    field :name, :string
    field :address, :string
    field :hostname, :string, default: "localhost"
    field :enabled, :boolean, default: true
    field :delivery_mode, :string, default: "local"
    field :dkim_enabled, :boolean, default: false
    field :dkim_selector, :string, default: "mail"
    field :webhook_enabled, :boolean, default: false
    field :webhook_url, :string
    field :webhook_token, Supavisor.Encrypted.Binary, redact: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(mailbox, params) do
    params =
      if Map.get(params, "webhook_token") in [nil, ""],
        do: Map.delete(params, "webhook_token"),
        else: params

    params =
      if params["clear_webhook_token"] == "true",
        do: Map.put(params, "webhook_token", nil),
        else: params

    mailbox
    |> cast(params, [
      :name,
      :address,
      :hostname,
      :enabled,
      :delivery_mode,
      :dkim_enabled,
      :dkim_selector,
      :webhook_enabled,
      :webhook_url,
      :webhook_token
    ])
    |> update_change(:address, &String.downcase(String.trim(&1)))
    |> update_change(:name, &String.trim/1)
    |> update_change(:hostname, &String.downcase(String.trim(&1)))
    |> validate_required([:name, :address, :hostname, :delivery_mode, :dkim_selector])
    |> validate_length(:name, max: 80)
    |> validate_length(:address, max: 254)
    |> validate_format(
      :address,
      ~r/\A[A-Za-z0-9.!#$%&'*+\/?^_`{|}~-]+@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/
    )
    |> validate_format(:hostname, ~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/)
    |> validate_length(:hostname, max: 253)
    |> validate_inclusion(:delivery_mode, ["local", "direct"])
    |> validate_format(:dkim_selector, ~r/\A[a-zA-Z0-9_-]{1,63}\z/)
    |> validate_length(:webhook_url, max: 2048)
    |> validate_length(:webhook_token, max: 2048)
    |> validate_format(:webhook_token, ~r/\A[^\x00-\x20\x7f]+\z/,
      message: "must not contain whitespace or control characters"
    )
    |> validate_webhook()
    |> unique_constraint(:address)
  end

  defp validate_webhook(changeset) do
    if get_field(changeset, :webhook_enabled) do
      url = get_field(changeset, :webhook_url) || ""
      uri = URI.parse(url)

      valid =
        is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and is_nil(uri.fragment) and
          (uri.scheme == "https" or
             (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"]))

      if valid,
        do: changeset,
        else: add_error(changeset, :webhook_url, "use HTTPS, or HTTP on localhost")
    else
      changeset
    end
  end
end
