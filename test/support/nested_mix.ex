defmodule Letflow.Test.NestedMix do
  @moduledoc """
  GH #2630: how a test spawns a nested `mix` child that STARTS the app (and so opens its own
  `Letflow.Repo` pool against the shared test Postgres). `nested_mix_test.exs` scans the whole
  `test/` tree and requires every other mix spawn to be on an explicit no-pool allowlist.

  `config/test.exs` sizes the pool from `TEST_POOL_SIZE`, which `scripts/test_parallel.sh`
  exports for the partition (20 on a 100-connection CI server). A child spawned with
  `System.cmd/3` inherits that, so such a child opens a full partition-sized pool (a further
  20 connections) that the `N * TEST_POOL_SIZE` clamp does not budget for. That this caused
  the hosted-CI FATAL 53300 is a hypothesis consistent with the measurement, not proven.

  `cmd/3` is `System.cmd/3` with `TEST_POOL_SIZE` forced to `pool_size/0`. The same cap
  `executor_test.exs`'s nested `mix test` uses, and the figure
  `docs/migration/decisions/0009-test-parallel-pool-sizing.md`'s GH #2630 addendum assumes
  (reserve = partitions * pool_size). Children that never start the app
  (`mix run --no-start`, `mix compile`) open no pool and do not need this.
  """

  @pool_size 4

  @doc "The pool size a nested app-starting child is capped to."
  @spec pool_size() :: pos_integer()
  def pool_size, do: @pool_size

  @doc "Returns `env` (a `System.cmd/3` env list) with `TEST_POOL_SIZE` set to the cap."
  @spec env([{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def env(env \\ []) do
    [{"TEST_POOL_SIZE", Integer.to_string(@pool_size)} | List.keydelete(env, "TEST_POOL_SIZE", 0)]
  end

  @doc "`System.cmd/3` with the child's pool capped; any `:env` the caller passes is kept."
  @spec cmd(String.t(), [String.t()], keyword()) :: {Collectable.t(), non_neg_integer()}
  def cmd(command, args, opts \\ []) do
    System.cmd(command, args, Keyword.put(opts, :env, env(Keyword.get(opts, :env, []))))
  end
end
