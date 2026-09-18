defmodule Supavisor.Services.Mail do
  @moduledoc "Mailbox administration and a durable, bounded outbound/inbound store."
  import Ecto.Query
  alias Supavisor.Repo
  alias Supavisor.Services.{Mailbox, MailMessage, Events}
  alias Supavisor.ServiceAPI.KeyCache
  @page_size 20
  @metadata [
    :id,
    :mailbox_id,
    :owner,
    :direction,
    :status,
    :sender,
    :recipient,
    :subject,
    :read_at,
    :started_at,
    :finished_at,
    :receipt,
    :error,
    :webhook_status,
    :webhook_attempts,
    :webhook_next_at,
    :webhook_error,
    :inserted_at
  ]

  def mailboxes, do: Repo.all(from m in Mailbox, order_by: m.address, limit: 100)

  def public_mailboxes(principal),
    do:
      mailboxes()
      |> Enum.filter(&KeyCache.mailbox?(principal, &1.id))
      |> Enum.map(&Map.take(&1, [:id, :name, :address, :enabled, :delivery_mode]))

  def mailbox(id), do: if(Events.uuid?(id), do: Repo.get(Mailbox, id))

  def save_mailbox(id, params) do
    current = if id, do: mailbox(id), else: %Mailbox{}

    cond do
      is_nil(current) ->
        {:error, "Mailbox not found."}

      is_nil(id) and Repo.aggregate(Mailbox, :count) >= 100 ->
        {:error, "This workspace supports up to 100 mailboxes."}

      true ->
        case current |> Mailbox.changeset(params) |> Repo.insert_or_update() do
          {:ok, saved} ->
            Events.changed()
            {:ok, saved}

          error ->
            error
        end
    end
  end

  def delete_mailbox(id) do
    if Events.uuid?(id) do
      case Repo.transaction(fn ->
             current = Repo.one(from m in Mailbox, where: m.id == ^id, lock: "FOR UPDATE")

             cond do
               is_nil(current) ->
                 Repo.rollback("Mailbox not found.")

               Repo.exists?(from m in MailMessage, where: m.mailbox_id == ^id) ->
                 Repo.rollback(
                   "Delete the mailbox’s stored messages first, or disable it to keep them."
                 )

               true ->
                 Repo.delete!(current)
             end
           end) do
        {:ok, _} ->
          Events.changed()
          :ok

        error ->
          error
      end
    else
      {:error, "Mailbox not found."}
    end
  end

  def list(params \\ %{}, principal \\ %{admin: true}) do
    direction = Map.get(params, "direction", "inbound")
    search = if is_binary(params["search"]), do: String.slice(params["search"], 0, 100), else: ""
    page = parse_page(Map.get(params, "page", 1))
    query = from m in MailMessage, order_by: [desc: m.inserted_at]

    query =
      if direction == "queue",
        do:
          where(
            query,
            [m],
            m.status in ["queued", "sending"] or
              m.webhook_status in ["pending", "sending", "retrying"]
          ),
        else: where(query, [m], m.direction == ^direction)

    query =
      if Events.uuid?(params["mailbox_id"]),
        do: where(query, [m], m.mailbox_id == ^params["mailbox_id"]),
        else: query

    query =
      if principal[:admin] || principal.mailbox_ids == [],
        do: query,
        else: where(query, [m], m.mailbox_id in ^principal.mailbox_ids)

    query =
      if search == "",
        do: query,
        else:
          where(
            query,
            [m],
            ilike(m.subject, ^("%" <> escape(search) <> "%")) or
              ilike(m.sender, ^("%" <> escape(search) <> "%")) or
              ilike(m.recipient, ^("%" <> escape(search) <> "%"))
          )

    count = Repo.aggregate(query, :count)
    pages = max(1, ceil(count / @page_size))
    page = min(page, pages)

    rows =
      Repo.all(
        from m in query,
          limit: @page_size,
          offset: ^((page - 1) * @page_size),
          select: map(m, ^@metadata)
      )

    %{rows: rows, total: count, page: page, pages: pages}
  end

  def get(id, principal, mark_read \\ false) do
    message = if Events.uuid?(id), do: Repo.get(MailMessage, id)

    cond do
      is_nil(message) ->
        Events.error("not_found", "Message not found.")

      !KeyCache.mailbox?(principal, message.mailbox_id) ->
        Events.error("forbidden", "This key cannot access the mailbox.")

      !principal[:admin] and !KeyCache.allowed?(principal, "mail:read") ->
        Events.error("forbidden", "mail:read permission required.")

      true ->
        message =
          if mark_read and is_nil(message.read_at) do
            updated = Repo.update!(Ecto.Changeset.change(message, read_at: DateTime.utc_now()))
            Events.changed()
            wake()
            updated
          else
            message
          end

        {:ok, Map.merge(summary(message), %{body: decode_content(message)})}
    end
  end

  def request(id, principal) do
    message = if Events.uuid?(id), do: Repo.get(MailMessage, id)

    cond do
      is_nil(message) ->
        Events.error("not_found", "Request not found.")

      !principal[:admin] and message.owner != KeyCache.owner(principal) ->
        Events.error("not_found", "Request not found.")

      true ->
        {:ok, summary(message)}
    end
  end

  def enqueue(params, principal) when is_map(params) do
    box = mailbox(params["mailbox_id"])
    subject = Map.get(params, "subject", "")
    text = Map.get(params, "text", "")
    html = Map.get(params, "html", "")
    to = Map.get(params, "to", "")
    idempotency = Map.get(params, "idempotency_key")

    cond do
      !KeyCache.allowed?(principal, "mail:send") ->
        Events.error("forbidden", "mail:send permission required.")

      is_nil(box) or !box.enabled ->
        Events.error("mailbox_unavailable", "Select an enabled mailbox.")

      !KeyCache.mailbox?(principal, box.id) ->
        Events.error("forbidden", "This key cannot use the mailbox.")

      !Enum.all?([subject, text, html, to], &is_binary/1) ->
        Events.error("invalid_input", "Recipient, subject and bodies must be strings.")

      byte_size(subject) > 512 or byte_size(text) + byte_size(html) > 128_000 ->
        Events.error(
          "payload_too_large",
          "Use a subject up to 512 bytes and bodies up to 128 KB."
        )

      idempotency != nil and (!is_binary(idempotency) or byte_size(idempotency) not in 1..128) ->
        Events.error("invalid_input", "Idempotency key must contain 1–128 bytes.")

      true ->
        input = %{from: box.address, to: to, subject: subject, text: text, html: html}

        case Postbeam.Message.new(input) do
          {:ok, _} ->
            persist_outbound(box, input, principal, idempotency)

          {:error, _} ->
            Events.error(
              "invalid_email",
              "Check the recipient and message. Use one recipient per request."
            )
        end
    end
  end

  def enqueue(_, _), do: Events.error("invalid_input", "Expected a JSON object.")

  defp persist_outbound(box, input, principal, idempotency) do
    owner = KeyCache.owner(principal)
    content = Jason.encode!(input)
    digest = :crypto.hash(:sha256, box.id <> content)

    Repo.transaction(fn ->
      # Serialize retries across mailboxes, not only within one mailbox.
      if idempotency do
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          owner <> ":" <> idempotency
        ])
      end

      current = Repo.one!(from m in Mailbox, where: m.id == ^box.id, lock: "FOR UPDATE")

      unless current.enabled && current.address == box.address do
        Repo.rollback(%{
          code: "mailbox_unavailable",
          message: "Mailbox settings changed. Try again."
        })
      end

      existing =
        if idempotency,
          do:
            Repo.one(
              from m in MailMessage,
                where: m.owner == ^owner and m.idempotency_key == ^idempotency
            )

      cond do
        existing && existing.request_digest == digest ->
          summary(existing)

        existing ->
          Repo.rollback(%{
            code: "idempotency_conflict",
            message: "This idempotency key was used for another message."
          })

        Repo.aggregate(from(m in MailMessage, where: m.mailbox_id == ^box.id), :count) >= 1000 ->
          Repo.rollback(%{
            code: "mailbox_full",
            message: "Mailbox retention limit reached. Delete old messages."
          })

        Repo.aggregate(
          from(m in MailMessage,
            where: m.mailbox_id == ^box.id and m.status in ["queued", "sending"]
          ),
          :count
        ) >= 100 ->
          Repo.rollback(%{code: "queue_full", message: "Mailbox queue is full. Try again later."})

        true ->
          message =
            Repo.insert!(%MailMessage{
              mailbox_id: box.id,
              owner: owner,
              direction: "outbound",
              status: "queued",
              sender: input.from,
              recipient: input.to,
              subject: input.subject,
              content: content,
              idempotency_key: idempotency,
              request_digest: digest
            })

          summary(message)
      end
    end)
    |> case do
      {:ok, result} ->
        Events.request(owner, result)
        wake()
        {:ok, result}

      error ->
        error
    end
  end

  def cancel(id, principal) do
    with {:ok, message} <- request(id, principal), true <- message.status == "queued" do
      {count, _} =
        Repo.update_all(from(m in MailMessage, where: m.id == ^id and m.status == "queued"),
          set: [status: "cancelled", finished_at: DateTime.utc_now()]
        )

      result = request(id, principal)
      if count == 1, do: Events.request(message.owner, elem(result, 1))

      if count == 0,
        do: Events.error("not_cancellable", "The message is already processing."),
        else: result
    else
      false -> Events.error("not_cancellable", "Only queued messages can be cancelled.")
      error -> error
    end
  end

  def delete(id) do
    if Events.uuid?(id) do
      Repo.delete_all(
        from m in MailMessage,
          where:
            m.id == ^id and m.status not in ["queued", "sending"] and
              m.webhook_status not in ["sending", "pending", "retrying"]
      )

      Events.changed()
    end

    :ok
  end

  def retry_webhook(id) do
    if Events.uuid?(id) do
      Repo.update_all(from(m in MailMessage, where: m.id == ^id and m.webhook_status == "failed"),
        set: [
          webhook_status: "pending",
          webhook_attempts: 0,
          webhook_next_at: DateTime.utc_now(),
          webhook_error: nil
        ]
      )

      Events.changed()
      wake()
    end

    :ok
  end

  def stats do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)

    Repo.one(
      from m in MailMessage,
        select: %{
          queued: filter(count(m.id), m.status == "queued"),
          sending: filter(count(m.id), m.status == "sending"),
          unread: filter(count(m.id), m.direction == "inbound" and is_nil(m.read_at)),
          webhooks: filter(count(m.id), m.webhook_status in ["pending", "retrying", "sending"]),
          webhook_queued: filter(count(m.id), m.webhook_status in ["pending", "retrying"]),
          webhook_sending: filter(count(m.id), m.webhook_status == "sending"),
          accepted_today:
            filter(count(m.id), m.status in ["accepted", "local"] and m.finished_at > ^cutoff)
        }
    )
  end

  def summary(message), do: Map.take(message, @metadata) |> Map.put(:service, "mailer")
  def decode_content(%{direction: "outbound", content: content}), do: Jason.decode!(content)

  def decode_content(%{content: content}) do
    Postbeam.SMTP.MIME.decode(content) |> mime_content()
  rescue
    _ -> %{text: "The original message could not be decoded.", html: "", attachments: []}
  end

  def mime_content({type, subtype, _headers, _params, body}) do
    cond do
      type == "multipart" and is_list(body) ->
        Enum.reduce(body, %{text: "", html: "", attachments: []}, fn part, acc ->
          child = mime_content(part)

          %{
            text: acc.text <> child.text,
            html: acc.html <> child.html,
            attachments: acc.attachments ++ child.attachments
          }
        end)

      type == "text" and subtype == "plain" and is_binary(body) ->
        %{text: safe_text(body), html: "", attachments: []}

      type == "text" and subtype == "html" and is_binary(body) ->
        %{text: "", html: safe_text(body), attachments: []}

      true ->
        %{
          text: "",
          html: "",
          attachments: [
            %{
              type: "#{type}/#{subtype}",
              bytes: if(is_binary(body), do: byte_size(body), else: 0)
            }
          ]
        }
    end
  end

  def mime_content(_), do: %{text: "", html: "", attachments: []}
  def safe_text(binary), do: if(String.valid?(binary), do: binary, else: "[Non UTF-8 content]")
  defp parse_page(value) when is_integer(value), do: max(1, value)

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> max(1, n)
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp escape(value),
    do:
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

  def wake,
    do:
      if(Process.whereis(Supavisor.Services.MailWorker),
        do: send(Supavisor.Services.MailWorker, :wake)
      )
end
