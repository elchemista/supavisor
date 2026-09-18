defmodule Supavisor.Services.IncomingMail do
  @behaviour Postbeam.Inbound
  import Ecto.Query
  alias Supavisor.Repo
  alias Supavisor.Services.{Mailbox, MailMessage, Mail, Events}

  @impl true
  def accept_recipient(address, _) do
    if Repo.exists?(
         from m in Mailbox, where: m.address == ^String.downcase(address) and m.enabled
       ), do: :ok, else: {:error, {:permanent, "Unknown mailbox"}}
  rescue
    _ -> {:error, {:temporary, "Mailbox lookup unavailable"}}
  end

  @impl true
  def handle_message(message, _) do
    recipients = Enum.map(message.to, &String.downcase/1) |> Enum.uniq()

    result =
      Repo.transaction(fn ->
        boxes =
          Repo.all(
            from m in Mailbox,
              where: m.address in ^recipients and m.enabled,
              order_by: m.id,
              lock: "FOR UPDATE"
          )

        if length(boxes) != length(recipients), do: Repo.rollback(:unknown_mailbox)

        for box <- boxes do
          if Repo.aggregate(from(m in MailMessage, where: m.mailbox_id == ^box.id), :count) >=
               1000,
             do: Repo.rollback(:mailbox_full)

          Repo.insert!(%MailMessage{
            mailbox_id: box.id,
            owner: "inbound",
            direction: "inbound",
            status: "received",
            sender: message.from,
            recipient: box.address,
            subject: subject(message.decoded),
            content: message.data,
            webhook_status: if(box.webhook_enabled, do: "pending", else: "disabled"),
            webhook_next_at: DateTime.utc_now()
          })
        end
      end)

    case result do
      {:ok, _} ->
        Events.changed()
        Mail.wake()
        :ok

      {:error, _} ->
        {:error, {:temporary, "Mailbox unavailable or full"}}
    end
  rescue
    _ -> {:error, {:temporary, "Message storage unavailable"}}
  end

  defp subject({_, _, headers, _, _}) do
    headers
    |> Enum.find_value("(No subject)", fn {key, value} ->
      if String.downcase(to_string(key)) == "subject", do: Mail.safe_text(to_string(value))
    end)
    |> String.slice(0, 512)
  end

  defp subject(_), do: "(Undecoded message)"
end
