defmodule SupavisorWeb.Admin.GithubController do
  use SupavisorWeb, :controller
  alias SupavisorWeb.{AdminAuth, AdminSettings}
  @state_ttl :timer.minutes(10)

  def start(conn, _params) do
    case AdminSettings.github_config() do
      {:ok, config} ->
        state = random_token()
        verifier = random_token()

        context = %{
          verifier: verifier,
          client_id: config.client_id,
          redirect_uri: config.redirect_uri
        }

        {:ok, true} =
          Cachex.put(Supavisor.Cache, {:github_oauth, state}, context, ttl: @state_ttl)

        query =
          URI.encode_query(%{
            client_id: config.client_id,
            redirect_uri: config.redirect_uri,
            scope: "user:email",
            state: state,
            allow_signup: "false",
            code_challenge: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
            code_challenge_method: "S256"
          })

        conn
        |> put_session(:github_oauth_state, state)
        |> redirect(external: "https://github.com/login/oauth/authorize?" <> query)

      :disabled ->
        failure(conn, "GitHub sign-in has not been enabled yet.")
    end
  end

  def callback(conn, params) do
    expected = get_session(conn, :github_oauth_state)
    conn = delete_session(conn, :github_oauth_state)

    with {:ok, context} <- consume_state(params["state"], expected),
         {:ok, config} <- AdminSettings.github_config(),
         true <-
           config.client_id == context.client_id && config.redirect_uri == context.redirect_uri,
         code when is_binary(code) and byte_size(code) <= 2048 <- params["code"],
         {:ok, token} <- exchange(code, context, config),
         {:ok, email} <- verified_admin_email(token) do
      conn
      |> AdminAuth.log_in_admin(email)
      |> put_flash(:info, "Signed in with GitHub.")
      |> redirect(to: ~p"/admin")
    else
      {:error, :not_allowed} ->
        failure(conn, "None of your verified GitHub email addresses is on the admin list.")

      _ ->
        failure(conn, "GitHub sign-in could not be completed. Please try again.")
    end
  end

  defp consume_state(state, expected)
       when is_binary(state) and is_binary(expected) and byte_size(state) <= 128 do
    if Plug.Crypto.secure_compare(state, expected) do
      case Cachex.take(Supavisor.Cache, {:github_oauth, state}) do
        {:ok, context} when is_map(context) -> {:ok, context}
        _ -> :error
      end
    else
      :error
    end
  end

  defp consume_state(_, _), do: :error

  defp exchange(code, context, config) do
    case Req.post("https://github.com/login/oauth/access_token",
           form: [
             client_id: config.client_id,
             client_secret: config.client_secret,
             code: code,
             redirect_uri: context.redirect_uri,
             code_verifier: context.verifier
           ],
           headers: [{"accept", "application/json"}],
           retry: false,
           redirect: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      _ ->
        :error
    end
  end

  defp verified_admin_email(token) do
    case Req.get("https://api.github.com/user/emails?per_page=100",
           headers: [
             {"authorization", "Bearer " <> token},
             {"accept", "application/vnd.github+json"},
             {"user-agent", "Supavisor-Console"},
             {"x-github-api-version", "2022-11-28"}
           ],
           retry: false,
           redirect: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: emails}} when is_list(emails) ->
        allowed = AdminAuth.admin_emails()

        case Enum.find(emails, fn
               %{"email" => email, "verified" => true} when is_binary(email) ->
                 String.downcase(email) in allowed

               _ ->
                 false
             end) do
          %{"email" => email} -> {:ok, email}
          _ -> {:error, :not_allowed}
        end

      _ ->
        :error
    end
  end

  defp failure(conn, message),
    do: conn |> put_flash(:error, message) |> redirect(to: ~p"/admin/login")

  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
