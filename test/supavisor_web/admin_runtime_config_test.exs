defmodule SupavisorWeb.AdminRuntimeConfigTest do
  use ExUnit.Case, async: false

  @env %{
    "DATABASE_URL" => "ecto://metadata:password@127.0.0.1/supavisor",
    "VAULT_ENC_KEY" => String.duplicate("a", 32),
    "SECRET_KEY_BASE" => String.duplicate("b", 64),
    "ADMIN_BASE_URL" => "https://db.example.com",
    "ADMIN_EMAILS" => "owner@example.com, second@example.com",
    "POOLER_HOST" => "pool.example.com",
    "HTTP_BIND_ADDRESS" => "127.0.0.1",
    "CLUSTER_POSTGRES" => "false",
    "ADMIN_PROVISIONING_ENABLED" => "true",
    "ADMIN_POSTGRES_HOST" => "db.internal",
    "ADMIN_POSTGRES_PORT" => "5439",
    "ADMIN_POSTGRES_USER" => "provisioner",
    "ADMIN_POSTGRES_PASSWORD" => "example-password",
    "SMTP_HOST" => "smtp.example.com",
    "SMTP_PORT" => "587",
    "SMTP_USERNAME" => "mailer@example.com",
    "SMTP_PASSWORD" => "example-smtp-password",
    "SMTP_SSL" => "false"
  }

  setup do
    original = Map.new(@env, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(@env)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "production config reads admin, SMTP, provisioner, URL and bind address at runtime" do
    config = Config.Reader.read!("config/runtime.exs", env: :prod)
    app = config[:supavisor]

    assert app[SupavisorWeb.AdminAuth][:admin_emails] == [
             "owner@example.com",
             "second@example.com"
           ]

    assert app[SupavisorWeb.Endpoint][:url] == [
             scheme: "https",
             host: "db.example.com",
             port: 443
           ]

    assert app[SupavisorWeb.Endpoint][:http][:ip] == {127, 0, 0, 1}
    assert app[:public_pooler_host] == "pool.example.com"
    assert app[SupavisorWeb.AdminProvisioning][:allowed_targets] == [{"db.internal", 5439}]
    assert app[SupavisorWeb.AdminProvisioning][:enabled]
    assert app[Supavisor.Mailer][:adapter] == Swoosh.Adapters.SMTP
    assert app[Supavisor.Mailer][:tls] == :always
    assert config[:libcluster][:topologies] == []
  end

  test "invalid Vault key is rejected before startup" do
    System.put_env("VAULT_ENC_KEY", "too-short")

    assert_raise RuntimeError, ~r/VAULT_ENC_KEY must contain exactly 32 bytes/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end

  test "admin URL cannot contain credentials or a path" do
    System.put_env("ADMIN_BASE_URL", "https://user:pass@example.com/path")

    assert_raise RuntimeError, ~r/ADMIN_BASE_URL must be/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod)
    end
  end
end
