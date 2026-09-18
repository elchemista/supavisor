defmodule Supavisor.Services.MailDelivery do
  alias Supavisor.Services.Mail
  alias Supavisor.ServiceAPI.KeyCache

  def options(box) do
    domain = box.address |> String.split("@") |> List.last()

    [
      hostname: box.hostname,
      tls: :always,
      smtp_timeout: 30_000,
      dns_timeout: 5_000,
      dkim: if(box.dkim_enabled, do: [d: domain, s: box.dkim_selector]),
      key_store:
        {Postbeam.KeyStore.File,
         directory: Application.fetch_env!(:supavisor, :service_mail_key_dir)}
    ]
  end

  def dkim_record(box) do
    Postbeam.DKIM.setup(options(%{box | dkim_enabled: true}))
  end

  def deliver(message) do
    box = Mail.mailbox(message.mailbox_id)

    authorized =
      String.starts_with?(message.owner, "admin:") or
        case KeyCache.get(message.owner) do
          {:ok, key} ->
            KeyCache.allowed?(key, "mail:send") and KeyCache.mailbox?(key, message.mailbox_id)

          _ ->
            false
        end

    cond do
      is_nil(box) or !box.enabled ->
        {:failed, "Mailbox disabled.", %{}}

      !authorized ->
        {:cancelled, "API key revoked or access expired.", %{}}

      box.delivery_mode == "local" ->
        {:local, nil, %{"mode" => "local", "note" => "Stored locally; no external delivery."}}

      true ->
        content = Jason.decode!(message.content)

        input = [
          from: message.sender,
          to: message.recipient,
          subject: message.subject,
          text: content["text"],
          html: content["html"]
        ]

        case Postbeam.deliver(input, options(box)) do
          {:ok, receipt} ->
            {:accepted, nil,
             Map.take(receipt, [:message_id, :mx]) |> Map.new(fn {k, v} -> {to_string(k), v} end)}

          {:error, {:uncertain, detail}} ->
            {:uncertain, "SMTP acceptance is uncertain. Review before resending.",
             diagnostic(detail)}

          {:error, {:permanent, detail}} ->
            {:failed, "Recipient server rejected this message.", diagnostic(detail)}

          {:error, {:exhausted, detail}} ->
            {:failed, "All SMTP delivery attempts failed.", diagnostic(detail)}

          {:error, {:dns, _, _, _}} ->
            {:failed, "Recipient DNS lookup failed.", %{}}

          {:error, {:dkim, _}} ->
            {:failed, "DKIM signing failed. Check the domain key.", %{}}

          {:error, _} ->
            {:failed, "Delivery failed. Check mailbox and domain configuration.", %{}}
        end
    end
  rescue
    _ -> {:uncertain, "Delivery interrupted. Review before resending.", %{}}
  catch
    _, _ -> {:uncertain, "Delivery interrupted. Review before resending.", %{}}
  end

  def webhook(message) do
    box = Mail.mailbox(message.mailbox_id)

    if box && box.enabled && box.webhook_enabled do
      body = Mail.decode_content(message)

      payload = %{
        event: "email.received",
        event_id: message.id,
        received_at: message.inserted_at,
        mailbox: %{id: box.id, address: box.address},
        from: message.sender,
        to: [message.recipient],
        subject: message.subject,
        text: body.text,
        html: body.html,
        attachments: body.attachments
      }

      headers = [{"x-postbeam-event-id", message.id}, {"idempotency-key", message.id}]

      headers =
        if box.webhook_token,
          do: [{"authorization", "Bearer " <> box.webhook_token} | headers],
          else: headers

      case Req.post(box.webhook_url,
             json: payload,
             headers: headers,
             retry: false,
             redirect: false,
             receive_timeout: 10_000,
             connect_options: [timeout: 5_000],
             decode_body: false,
             into: fn {:data, _chunk}, acc -> {:cont, acc} end
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:delivered, nil}

        {:ok, %{status: status}} when status == 408 or status == 429 or status >= 500 ->
          {:retry, "Webhook returned HTTP #{status}."}

        {:ok, %{status: status}} ->
          {:failed, "Webhook returned HTTP #{status}."}

        {:error, _} ->
          {:retry, "Webhook connection failed or timed out."}
      end
    else
      {:disabled, "Webhook disabled for this mailbox."}
    end
  rescue
    _ -> {:retry, "Webhook delivery failed."}
  end

  defp diagnostic(details) when is_map(details),
    do: Map.take(details, [:message_id, :mx]) |> Map.new(fn {k, v} -> {to_string(k), v} end)

  defp diagnostic(_), do: %{}
end
