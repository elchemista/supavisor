defmodule SupavisorWeb.AdminConnectionTest do
  use ExUnit.Case, async: false

  test "connection URL escapes credentials and database names and supports IPv6" do
    previous = Application.get_env(:supavisor, :public_pooler_host)
    Application.put_env(:supavisor, :public_pooler_host, "2001:db8::1")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:supavisor, :public_pooler_host, previous),
        else: Application.delete_env(:supavisor, :public_pooler_host)
    end)

    assert SupavisorWeb.AdminConnection.uri(
             "postgresql",
             "user@org.tenant",
             "a b+c@d",
             "my/db",
             6543
           ) ==
             "postgresql://user%40org.tenant:a%20b%2Bc%40d@[2001:db8::1]:6543/my%2Fdb"
  end
end
