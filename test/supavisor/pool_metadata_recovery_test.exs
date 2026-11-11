defmodule Supavisor.PoolMetadataRecoveryTest do
  use ExUnit.Case, async: false

  require Supavisor

  alias Supavisor.{ClientHandler, Repo, Tenants}
  alias Supavisor.Errors.PoolConfigNotFoundError
  alias Supavisor.Tenants.Tenant

  setup do
    tenant = "metadata_recovery_#{System.unique_integer([:positive])}"
    user = "recovery_user"
    cache_key = {:pool_config_cache, tenant, user}

    :meck.new(Repo, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.unload(Repo)
      Cachex.del(Supavisor.Cache, cache_key)
    end)

    {:ok, tenant: tenant, user: user, cache_key: cache_key}
  end

  test "a failed metadata query is not cached and the next lookup recovers", ctx do
    :meck.expect(Repo, :all, fn _ ->
      raise DBConnection.ConnectionError, "metadata database unavailable"
    end)

    assert {:error, %Cachex.ExecutionError{}} =
             Tenants.get_pool_config_cache(ctx.tenant, ctx.user)

    assert {:ok, nil} = Cachex.get(Supavisor.Cache, ctx.cache_key)

    config = [%Tenant{external_id: ctx.tenant}]
    :meck.expect(Repo, :all, fn _ -> config end)

    assert ^config = Tenants.get_pool_config_cache(ctx.tenant, ctx.user)

    :meck.expect(Repo, :all, fn _ ->
      raise DBConnection.ConnectionError, "metadata database unavailable again"
    end)

    assert ^config = Tenants.get_pool_config_cache(ctx.tenant, ctx.user)
  end

  test "PostgreSQL shutdown reaches the bounded subscription retry instead of crashing", ctx do
    :meck.expect(Repo, :all, fn _ ->
      raise Postgrex.Error,
        postgres: %{
          code: :admin_shutdown,
          message: "terminating connection due to administrator command"
        }
    end)

    id =
      Supavisor.id(
        type: :single,
        tenant: ctx.tenant,
        user: ctx.user,
        mode: :transaction,
        db: "postgres"
      )

    secrets = %{user: ctx.user}

    assert {:error, %PoolConfigNotFoundError{id: ^id}} =
             Supavisor.start_local_pool(id, secrets)

    :meck.new(Supavisor, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Supavisor) end)

    :meck.expect(Supavisor, :start_dist, fn pool_id, pool_secrets, _options ->
      Supavisor.start_local_pool(pool_id, pool_secrets)
    end)

    data = %{
      id: id,
      connection_params: %{secrets: secrets},
      tenant_availability_zone: nil,
      subscribe_retries: 0
    }

    assert {:keep_state, %{subscribe_retries: 1}, {:timeout, 500, :subscribe}} =
             ClientHandler.handle_event(:internal, :subscribe, :auth_scram_final_wait, data)
  end
end
