defmodule Supavisor.MCP.Auth do
  @moduledoc """
  OAuth authorization for the MCP resource. Codes and bearer credentials are
  stored as SHA-256 hashes; authorization codes and refresh tokens are consumed
  under row locks. Implements RFC 7636 S256 PKCE and resource audience binding.
  """
  import Ecto.Query
  alias Supavisor.Repo
  alias Supavisor.MCP.{AuthorizationCode, Client, Consent, Grant}
  alias SupavisorWeb.{AdminAuth, AdminCredential}

  @scopes ~w(db:read db:create db:migrate)
  @access_ttl 3_600
  @refresh_ttl 2_592_000
  @code_ttl 300
  @max_refresh_rotations 2_048

  def enabled?, do: true

  def base_url(origin \\ nil) do
    value = origin || SupavisorWeb.Endpoint.url()

    if valid_base_url?(value),
      do: String.trim_trailing(value, "/"),
      else:
        raise(
          ArgumentError,
          "MCP request origin must use HTTPS (HTTP is allowed only for localhost)"
        )
  end

  def valid_base_url?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    with {:ok, uri} <- URI.new(value),
         true <-
           uri.path in [nil, "", "/"] and uri.query == nil and uri.fragment == nil and
             uri.userinfo == nil,
         host when is_binary(host) and host != "" <- uri.host,
         true <- Regex.match?(~r/\A[A-Za-z0-9.:-]+\z/, host) do
      uri.scheme == "https" or
        (uri.scheme == "http" and host in ["localhost", "127.0.0.1", "::1"])
    else
      _ -> false
    end
  end

  def valid_base_url?(_), do: false

  def resource(origin \\ nil), do: base_url(origin) <> "/mcp"
  def scopes, do: @scopes
  def token_ttl, do: @access_ttl

  def metadata(origin \\ nil) do
    base = base_url(origin)

    %{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      revocation_endpoint: base <> "/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
      code_challenge_methods_supported: ["S256"],
      scopes_supported: scopes()
    }
  end

  def resource_metadata(origin \\ nil) do
    %{
      resource: resource(origin),
      authorization_servers: [base_url(origin)],
      scopes_supported: scopes(),
      bearer_methods_supported: ["header"],
      resource_name: "Supavisor databases"
    }
  end

  def register(params) when is_map(params) do
    uris = params["redirect_uris"]
    name = params["client_name"] || "MCP client"
    method = params["token_endpoint_auth_method"] || "none"

    with true <- is_binary(name) and byte_size(name) in 1..100,
         true <- is_list(uris) and length(uris) in 1..10 and Enum.all?(uris, &valid_redirect?/1),
         true <- method in ["none", "client_secret_post", "client_secret_basic"],
         true <-
           Map.get(params, "grant_types", ["authorization_code"]) in [
             ["authorization_code"],
             ["authorization_code", "refresh_token"],
             ["refresh_token", "authorization_code"]
           ],
         true <- Map.get(params, "response_types", ["code"]) == ["code"],
         true <- Repo.aggregate(Client, :count) < 1_000 do
      secret = if method == "none", do: nil, else: random_token()

      client = %Client{
        id: random_token(),
        name: name,
        redirect_uris: Enum.uniq(uris),
        auth_method: method,
        secret_hash: if(secret, do: hash(secret))
      }

      case Repo.insert(client) do
        {:ok, client} ->
          response = %{
            client_id: client.id,
            client_id_issued_at: System.system_time(:second),
            client_name: client.name,
            redirect_uris: client.redirect_uris,
            token_endpoint_auth_method: method,
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"]
          }

          {:ok,
           if(secret,
             do: Map.merge(response, %{client_secret: secret, client_secret_expires_at: 0}),
             else: response
           )}

        _ ->
          {:error, "invalid_client_metadata"}
      end
    else
      _ -> {:error, "invalid_client_metadata"}
    end
  end

  def register(_), do: {:error, "invalid_client_metadata"}

  def valid_redirect?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    with {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil, fragment: nil}} <-
           URI.new(value),
         true <- is_integer(port) and port in 1..65_535,
         true <- is_binary(host) and host != "" and Regex.match?(~r/\A[A-Za-z0-9.:-]+\z/, host) do
      scheme == "https" or (scheme == "http" and host in ["localhost", "127.0.0.1", "::1"])
    else
      _ -> false
    end
  end

  def valid_redirect?(_), do: false

  defp registered_redirect?(requested, registered_uris) do
    valid_redirect?(requested) and
      Enum.any?(registered_uris, fn registered ->
        requested == registered or loopback_redirect?(registered, requested)
      end)
  end

  # Native clients listen on a free ephemeral port selected after registration
  # (RFC 8252 section 7.3). Only HTTP loopback IP literals receive this exception;
  # every other URI component, including the raw path/query, must still match.
  defp loopback_redirect?(registered, requested) do
    with {:ok, %URI{scheme: "http", host: host} = registered} <- URI.new(registered),
         true <- host in ["127.0.0.1", "::1"],
         {:ok, %URI{scheme: "http", host: ^host} = requested} <- URI.new(requested) do
      fields = [:scheme, :host, :path, :query, :userinfo, :fragment]
      Map.take(registered, fields) == Map.take(requested, fields)
    else
      _ -> false
    end
  end

  def validate_authorization(params, expected_resource \\ resource())

  def validate_authorization(params, expected_resource) when is_map(params) do
    with %Client{} = client <- client(params["client_id"]),
         uri when is_binary(uri) <- params["redirect_uri"],
         true <- registered_redirect?(uri, client.redirect_uris),
         "code" <- params["response_type"],
         "S256" <- params["code_challenge_method"],
         challenge when is_binary(challenge) <- params["code_challenge"],
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, challenge),
         resource when is_binary(resource) <- params["resource"],
         true <- resource == expected_resource,
         {:ok, requested_scopes} <- parse_scopes(params["scope"] || "db:read"),
         true <- valid_state?(params["state"]) do
      request =
        Map.take(
          params,
          ~w(client_id redirect_uri response_type code_challenge code_challenge_method resource state)
        )

      {:ok, client, Map.put(request, "scope", Enum.join(requested_scopes, " "))}
    else
      _ -> {:error, "invalid_request"}
    end
  end

  def validate_authorization(_, _), do: {:error, "invalid_request"}

  def create_consent(email) do
    Repo.delete_all(from c in Consent, where: c.expires_at < ^DateTime.utc_now())
    nonce = random_token()

    case Repo.insert(%Consent{
           id: hash(nonce),
           admin_email: email,
           expires_at: after_seconds(600)
         }) do
      {:ok, _} -> {:ok, nonce}
      _ -> {:error, :unavailable}
    end
  end

  # An atomic SQL DELETE works across nodes and remains one-use even if the
  # browser replays the old signed session cookie against another instance.
  def consume_consent(email, nonce) when is_binary(nonce) and byte_size(nonce) <= 100 do
    case Repo.delete_all(
           from c in Consent,
             where:
               c.id == ^hash(nonce) and c.admin_email == ^email and
                 c.expires_at > ^DateTime.utc_now()
         ) do
      {1, _} -> :ok
      _ -> {:error, :invalid_consent}
    end
  end

  def consume_consent(_, _), do: {:error, :invalid_consent}

  def issue_code(request, email, selected_scopes, tenant_ids, expected_resource \\ resource()) do
    with true <- AdminAuth.admin_email?(email),
         {:ok, _client, request} <- validate_authorization(request, expected_resource),
         {:ok, requested} <- parse_scopes(request["scope"]),
         true <-
           is_list(selected_scopes) and selected_scopes != [] and
             Enum.all?(selected_scopes, &(&1 in requested)),
         true <- valid_tenant_ids?(tenant_ids) do
      code = random_token()

      record = %AuthorizationCode{
        id: hash(code),
        client_id: request["client_id"],
        admin_email: email,
        admin_version: AdminCredential.session_version(email),
        redirect_uri: request["redirect_uri"],
        challenge: request["code_challenge"],
        resource: request["resource"],
        scopes: Enum.uniq(selected_scopes),
        tenant_ids: Enum.uniq(tenant_ids),
        expires_at: after_seconds(@code_ttl)
      }

      case Repo.insert(record) do
        {:ok, _} -> {:ok, code}
        _ -> {:error, "invalid_request"}
      end
    else
      _ -> {:error, "invalid_request"}
    end
  end

  def exchange(params, expected_resource \\ resource())

  def exchange(params, expected_resource) when is_map(params) do
    with {:ok, client} <- authenticate_client(params) do
      case params["grant_type"] do
        "authorization_code" -> exchange_code(client, params, expected_resource)
        "refresh_token" -> refresh(client, params, expected_resource)
        _ -> {:error, "unsupported_grant_type"}
      end
    end
  end

  def exchange(_, _), do: {:error, "invalid_request"}

  def authorize(token, expected_resource \\ resource())

  def authorize(token, expected_resource) when is_binary(token) and byte_size(token) <= 1_024 do
    case Repo.get_by(Grant, access_hash: hash(token)) do
      %Grant{} = grant ->
        if active_admin?(grant) and grant.resource == expected_resource and
             future?(grant.expires_at),
           do: {:ok, grant},
           else: {:error, :invalid_token}

      _ ->
        {:error, :invalid_token}
    end
  end

  def authorize(_, _), do: {:error, :invalid_token}

  def allowed_tenant?(%Grant{tenant_ids: ids}, id), do: "*" in ids or id in ids
  def allowed_tenant?(_, _), do: false

  def grant_tenant(%Grant{id: id}, tenant_id) when is_binary(tenant_id) do
    Repo.transaction(fn ->
      grant = Repo.one(from g in Grant, where: g.id == ^id, lock: "FOR UPDATE")
      if grant == nil, do: Repo.rollback(:revoked)

      grant
      |> Ecto.Changeset.change(tenant_ids: Enum.uniq(grant.tenant_ids ++ [tenant_id]))
      |> Repo.update!()
    end)
  end

  def list_grants(email) do
    Repo.all(
      from g in Grant,
        join: c in Client,
        on: c.id == g.client_id,
        where: g.admin_email == ^email and g.refresh_expires_at > ^DateTime.utc_now(),
        order_by: [desc: g.inserted_at],
        select: %{g | client_name: c.name}
    )
  end

  def revoke_grant(id, email) when is_binary(id) and is_binary(email) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.delete_all(from g in Grant, where: g.id == ^id and g.admin_email == ^email)
      :ok
    else
      _ -> {:error, :invalid_id}
    end
  end

  def revoke_grant(_, _), do: {:error, :invalid_id}

  def revoke(params) when is_map(params) do
    with {:ok, client} <- authenticate_client(params),
         token when is_binary(token) and byte_size(token) <= 1_024 <- params["token"] do
      digest = hash(token)

      Repo.delete_all(
        from g in Grant,
          where:
            g.client_id == ^client.id and (g.access_hash == ^digest or g.refresh_hash == ^digest)
      )

      :ok
    else
      _ -> {:error, "invalid_client"}
    end
  end

  def revoke(_), do: {:error, "invalid_request"}

  # Cachex increments atomically; short-lived per-IP buckets bound unauthenticated abuse.
  def rate_limit(ip, action) do
    limit = if action == :register, do: 10, else: 60
    window = if action == :register, do: 3_600_000, else: 60_000
    bucket = div(System.system_time(:millisecond), window)
    key = {:mcp_oauth_rate, action, ip, bucket}

    case Cachex.incr(Supavisor.Cache, key, 1) do
      {:ok, count} ->
        Cachex.expire(Supavisor.Cache, key, window * 2)
        count <= limit

      _ ->
        false
    end
  end

  def parse_scopes(value) when is_binary(value) and byte_size(value) <= 100 do
    parsed = String.split(value, " ", trim: true) |> Enum.uniq()

    if parsed != [] and Enum.all?(parsed, &(&1 in @scopes)),
      do: {:ok, parsed},
      else: {:error, "invalid_scope"}
  end

  def parse_scopes(_), do: {:error, "invalid_scope"}

  defp exchange_code(client, params, expected_resource) do
    with code when is_binary(code) and byte_size(code) <= 1_024 <- params["code"],
         verifier when is_binary(verifier) <- params["code_verifier"],
         true <- Regex.match?(~r/\A[A-Za-z0-9._~-]{43,128}\z/, verifier),
         true <- params["resource"] == expected_resource do
      Repo.transaction(fn ->
        record =
          Repo.one(from c in AuthorizationCode, where: c.id == ^hash(code), lock: "FOR UPDATE")

        unless match?(%AuthorizationCode{}, record) and record.client_id == client.id and
                 record.redirect_uri == params["redirect_uri"] and
                 record.resource == expected_resource and
                 future?(record.expires_at) and active_admin?(record) and
                 Plug.Crypto.secure_compare(
                   record.challenge,
                   Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
                 ),
               do: Repo.rollback("invalid_grant")

        Repo.delete!(record)
        issue_tokens(record)
      end)
    else
      _ -> {:error, "invalid_grant"}
    end
  end

  defp refresh(client, params, expected_resource) do
    with token when is_binary(token) and byte_size(token) <= 1_024 <- params["refresh_token"],
         true <- params["resource"] == expected_resource do
      digest = hash(token)

      result =
        Repo.transaction(fn ->
          grant =
            Repo.one(
              from g in Grant,
                where: g.refresh_hash == ^digest or ^digest in g.used_refresh_hashes,
                lock: "FOR UPDATE"
            )

          unless match?(%Grant{}, grant) and grant.client_id == client.id and
                   grant.resource == expected_resource and
                   future?(grant.refresh_expires_at) and active_admin?(grant),
                 do: Repo.rollback("invalid_grant")

          # Retain the token family until its fixed expiry, so replay of any used
          # refresh token revokes its active successor (RFC 9700 section 4.14).
          # Require fresh browser consent after 2048 rotations to bound storage.
          if grant.refresh_hash != digest or
               length(grant.used_refresh_hashes) >= @max_refresh_rotations do
            Repo.delete!(grant)
            :revoked
          else
            selected =
              if params["scope"], do: parse_scopes(params["scope"]), else: {:ok, grant.scopes}

            case selected do
              {:ok, scopes} ->
                unless Enum.all?(scopes, &(&1 in grant.scopes)),
                  do: Repo.rollback("invalid_scope")

                rotate_tokens(grant, scopes)

              _ ->
                Repo.rollback("invalid_scope")
            end
          end
        end)

      case result do
        {:ok, :revoked} -> {:error, "invalid_grant"}
        other -> other
      end
    else
      _ -> {:error, "invalid_grant"}
    end
  end

  defp issue_tokens(record) do
    grant =
      struct(
        Grant,
        Map.take(record, [
          :client_id,
          :admin_email,
          :admin_version,
          :scopes,
          :tenant_ids,
          :resource
        ])
      )

    access = random_token()
    refresh = random_token()

    grant = %{
      grant
      | access_hash: hash(access),
        refresh_hash: hash(refresh),
        expires_at: after_seconds(@access_ttl),
        refresh_expires_at: after_seconds(@refresh_ttl)
    }

    Repo.insert!(grant)
    token_response(access, refresh, grant.scopes)
  end

  defp rotate_tokens(grant, scopes) do
    access = random_token()
    refresh = random_token()

    grant
    |> Ecto.Changeset.change(
      access_hash: hash(access),
      refresh_hash: hash(refresh),
      used_refresh_hashes: grant.used_refresh_hashes ++ [grant.refresh_hash],
      expires_at: after_seconds(@access_ttl),
      scopes: scopes
    )
    |> Repo.update!()

    token_response(access, refresh, scopes)
  end

  defp token_response(access, refresh, scopes),
    do: %{
      access_token: access,
      refresh_token: refresh,
      token_type: "Bearer",
      expires_in: @access_ttl,
      scope: Enum.join(scopes, " ")
    }

  defp authenticate_client(params) do
    case client(params["client_id"]) do
      %Client{auth_method: "none"} = client ->
        if Map.get(params, "_auth_method", "none") == "none",
          do: {:ok, client},
          else: {:error, "invalid_client"}

      %Client{} = client ->
        secret = params["client_secret"]
        method = Map.get(params, "_auth_method", "client_secret_post")

        if method == client.auth_method and is_binary(secret) and byte_size(secret) <= 1_024 and
             Plug.Crypto.secure_compare(client.secret_hash, hash(secret)),
           do: {:ok, client},
           else: {:error, "invalid_client"}

      _ ->
        {:error, "invalid_client"}
    end
  end

  defp client(id) when is_binary(id) and byte_size(id) <= 100, do: Repo.get(Client, id)
  defp client(_), do: nil
  defp valid_state?(nil), do: true
  defp valid_state?(state), do: is_binary(state) and byte_size(state) <= 2_048

  defp valid_tenant_ids?(ids),
    do:
      is_list(ids) and length(ids) <= 500 and
        Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..255))

  defp active_admin?(record),
    do:
      AdminAuth.admin_email?(record.admin_email) and
        record.admin_version == AdminCredential.session_version(record.admin_email)

  defp future?(value), do: DateTime.compare(value, DateTime.utc_now()) == :gt
  defp after_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
