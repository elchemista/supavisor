defmodule SupavisorWeb.AdminAuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn
  import Swoosh.TestAssertions

  alias SupavisorWeb.AdminAuth

  @endpoint SupavisorWeb.Endpoint
  use Phoenix.VerifiedRoutes,
    endpoint: SupavisorWeb.Endpoint,
    router: SupavisorWeb.Router,
    statics: SupavisorWeb.static_paths()

  setup :set_swoosh_global

  setup do
    original_config = Application.fetch_env!(:supavisor, AdminAuth)

    Application.put_env(:supavisor, AdminAuth,
      admin_emails: ["admin@example.com"],
      magic_link_ttl_seconds: 900,
      session_ttl_seconds: 28_800,
      email_from: {"Supavisor Admin", "admin@localhost"},
      base_url: "http://localhost:4002"
    )

    on_exit(fn ->
      Application.put_env(:supavisor, AdminAuth, original_config)
    end)

    :ok
  end

  test "allowed admin email receives a magic link" do
    assert {:ok, :sent} = AdminAuth.deliver_magic_link("Admin@Example.com")

    assert_email_sent(fn email ->
      assert email.to == [{"", "admin@example.com"}]
      assert email.subject == "Your Supavisor admin sign-in link"
      assert email.text_body =~ "http://localhost:4002/admin/magic/"
    end)
  end

  test "unlisted email does not receive a magic link" do
    assert :ok = AdminAuth.deliver_magic_link("other@example.com")
    refute_email_sent()
  end

  test "magic link can be used once" do
    assert {:ok, :sent} = AdminAuth.deliver_magic_link("admin@example.com")
    token = delivered_token()

    assert {:ok, "admin@example.com"} = AdminAuth.verify_magic_link(token)
    assert {:error, :invalid_or_expired} = AdminAuth.verify_magic_link(token)
  end

  test "magic link expires after configured ttl" do
    Application.put_env(:supavisor, AdminAuth,
      admin_emails: ["admin@example.com"],
      magic_link_ttl_seconds: 1,
      session_ttl_seconds: 28_800,
      email_from: {"Supavisor Admin", "admin@localhost"},
      base_url: "http://localhost:4002"
    )

    assert {:ok, :sent} = AdminAuth.deliver_magic_link("admin@example.com")
    token = delivered_token()
    Process.sleep(1100)

    assert {:error, :invalid_or_expired} = AdminAuth.verify_magic_link(token)
  end

  test "concurrent requests can consume a link only once" do
    {:ok, url} = AdminAuth.create_magic_link("admin@example.com")
    token = url |> String.split("/admin/magic/") |> List.last() |> URI.decode_www_form()

    results =
      1..12
      |> Task.async_stream(fn _ -> AdminAuth.verify_magic_link(token) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
  end

  test "a removed administrator cannot use a previously issued link" do
    {:ok, url} = AdminAuth.create_magic_link("admin@example.com")
    token = url |> String.split("/admin/magic/") |> List.last() |> URI.decode_www_form()

    Application.put_env(
      :supavisor,
      AdminAuth,
      Keyword.put(Application.fetch_env!(:supavisor, AdminAuth), :admin_emails, [])
    )

    assert {:error, :invalid_or_expired} = AdminAuth.verify_magic_link(token)
  end

  test "admin session expires after configured ttl" do
    Application.put_env(:supavisor, AdminAuth,
      admin_emails: ["admin@example.com"],
      magic_link_ttl_seconds: 900,
      session_ttl_seconds: -1,
      email_from: {"Supavisor Admin", "admin@localhost"},
      base_url: "http://localhost:4002"
    )

    conn =
      build_conn()
      |> init_test_session(%{
        "admin_email" => "admin@example.com",
        "admin_authenticated_at" => System.system_time(:second)
      })
      |> get(~p"/admin")

    assert redirected_to(conn) == ~p"/admin/login"
  end

  defp delivered_token do
    assert_received {:email, email}

    [_, token] =
      Regex.run(~r{/admin/magic/([^\s]+)}, email.text_body)

    URI.decode_www_form(token)
  end
end
