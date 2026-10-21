defmodule Letflow.Support.BpmDefaultRealmDisplacementGateTest do
  @moduledoc """
  Regression test for GH #2656: a test-partition BEAM held 10 Postgres connections
  beyond its Ecto pool of 20 (hosted CI, runs 38764249729 and 38863398664).

  Root cause: `BpmDefaultRealmDisplacement` opened a dedicated, unpooled `Postgrex`
  connection for EVERY `displace!/0` and `with_lock/1` caller before that caller blocked
  on `pg_advisory_lock`. N concurrent callers in one BEAM therefore held N connections
  outside Ecto's pool while they waited their turn. Reproduced locally (one partition,
  pool_size 20, 12 concurrent `with_lock/1` callers): 20 pool backends became 32 open
  sockets to the test database while the callers waited, and fell back to 20 after.

  The bound asserted here is `pool_size + 1`: at most one dedicated lock connection per
  BEAM at any moment (the in-BEAM gate in `BpmDefaultRealmDisplacement`). The count is
  taken in the BEAM itself (every TCP port of this VM whose peer is the test database
  port), so it does not depend on `application_name`, which sibling partitions in one
  `scripts/test_parallel.sh` run may share.
  """

  use ExUnit.Case, async: false

  alias Letflow.Repo
  alias Letflow.Support.BpmDefaultRealmDisplacement, as: Displacement

  # Concurrent `with_lock/1` callers. Each would previously hold its own connection.
  @contenders 12
  # The lock connection a single holder opens. Anything above this is the GH #2656 leak.
  @max_dedicated_connections 1
  # How long the first holder keeps the lock while the other contenders queue behind it.
  @hold_ms 1_500
  # Time for every contender to have reached the lock before the count is taken.
  @settle_ms 500

  # Number of TCP ports of this BEAM connected to the test database (pool and dedicated
  # connections alike). `:inet.peername/1` is `{:error, _}` for non-socket ports.
  defp open_db_sockets do
    db_port = Repo.config() |> Keyword.fetch!(:port)

    :erlang.ports()
    |> Enum.count(fn port ->
      match?({:ok, {_ip, ^db_port}}, :inet.peername(port))
    end)
  end

  # Fills Ecto's pool to `pool_size` by holding `pool_size` connections busy at once,
  # so the bound below is measured against a full pool.
  defp fill_pool!(pool_size) do
    1..pool_size
    |> Task.async_stream(fn _ -> Repo.query!("SELECT pg_sleep(0.5)") end,
      max_concurrency: pool_size,
      timeout: 30_000
    )
    |> Stream.run()
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "concurrent with_lock/1 callers never open more than pool_size plus one connection" do
    pool_size = Repo.config() |> Keyword.fetch!(:pool_size)

    fill_pool!(pool_size)
    assert open_db_sockets() >= pool_size

    holders =
      for i <- 1..@contenders do
        hold_ms = if i == 1, do: @hold_ms, else: 0

        Task.async(fn ->
          Displacement.with_lock(fn -> Process.sleep(hold_ms) end)
        end)
      end

    Process.sleep(@settle_ms)
    during = open_db_sockets()

    Task.await_many(holders, 30_000)

    assert during <= pool_size + @max_dedicated_connections,
           "this BEAM held #{during} database connections while #{@contenders} " <>
             "with_lock/1 callers waited; pool_size is #{pool_size}, the bound is " <>
             "pool_size + #{@max_dedicated_connections}"
  end
end
