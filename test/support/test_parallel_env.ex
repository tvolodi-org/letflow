defmodule Letflow.Test.TestParallelEnv do
  @moduledoc """
  Q-1037 / GH #2364: hermetic environment for tests that drive the real
  `scripts/test_parallel.sh` (with stub `mix`/`psql`) or `Mix.Tasks.Letflow.Check.Test`.

  Inside a sharded CI job the ambient environment carries `TEST_PARALLEL_N` (set by the
  workflow step) and `TEST_PARALLEL_SHARD=K/M` (exported by `mix letflow.check.test
  --shard K/M` to the script, whose child `mix test` processes inherit it). A test that
  spawns the script, or calls `run/1`, inherits them and sees a sliced partition space
  instead of the one it set up. This module is the single place that lists every knob the
  script reads, so each such test can scrub them before applying its own explicit env.

  Two entry points:

    * `scrubbed/0` / `port_env/1` -- for a CHILD process (`System.cmd/3` `env:` option,
      `Port.open/2` `:env`): `{name, nil}` pairs that UNSET the variable in the child.
    * `scrub_ambient!/0` -- for tests that call `run/1` inside the SAME BEAM: deletes the
      variables from this VM's environment and restores them in `on_exit/1`. The tests
      using it are `async: false`, so no concurrently running test observes the gap.

  The list is static on purpose (a completeness test in `test_parallel_env_test.exs`
  greps the script for every `TEST_*` knob it reads and fails when this list
  falls behind).
  """

  # Every environment variable that changes what scripts/test_parallel.sh does, except the
  # DB connection coordinates (LETFLOW_DB_*), which tests set themselves or which are
  # irrelevant to partition selection.
  @script_knobs ~w(
    TEST_PARALLEL_N
    TEST_PARALLEL_SHARD
    TEST_PARALLEL_TOTAL
    TEST_PARALLEL_OFFSET
    TEST_PARALLEL_GROUP
    TEST_PARALLEL_EXTRA_ARGS
    TEST_PARALLEL_PRINT_SLOWEST
    TEST_PARALLEL_KEEP_LOGS
    TEST_PARALLEL_PARTITION_TIMEOUT_S
    TEST_PARALLEL_PARTITION_KILL_GRACE_S
    TEST_PARALLEL_MAX_CONCURRENT_CREATES
    TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS
    TEST_PARALLEL_SAMPLE_CONNECTIONS
    TEST_PARALLEL_TEMPLATE_READY_DIR
    TEST_PARALLEL_MANIFEST
    TEST_POOL_SIZE
    TEST_MIN_POOL_SIZE
    TEST_MAX_CONNECTIONS
    TEST_CONNECTION_HEADROOM
    TEST_NONPOOL_CONNECTION_RESERVE
    TEST_PER_PARTITION_HEADROOM
    TEST_SUPERUSER_RESERVED
  )

  # The script sets this per child command itself; an ambient value (a shard job's own
  # `mix test` partition) must not leak into a script run under test. Scrubbed for CHILD
  # processes only: the BEAM running the suite already configured its Repo from it.
  @child_only ~w(MIX_TEST_PARTITION)

  @doc "Names scrubbed from a spawned child's environment."
  @spec child_names() :: [String.t()]
  def child_names, do: @script_knobs ++ @child_only

  @doc "Names removed from this VM's own environment by `scrub_ambient!/0`."
  @spec vm_names() :: [String.t()]
  def vm_names, do: @script_knobs

  @doc """
  `{name, nil}` for every ambient knob, ready to prepend to a child env list so the
  test's own explicit values (applied afterwards) win.
  """
  @spec scrubbed() :: [{String.t(), nil}]
  def scrubbed, do: Enum.map(child_names(), &{&1, nil})

  @doc """
  Builds a `Port.open/2` `:env` list: every ambient knob unset, then `env` (a list or map
  of `{name, value | nil}`) applied on top. `nil` unsets the variable.
  """
  @spec port_env(Enumerable.t()) :: [{charlist(), charlist() | false}]
  def port_env(env \\ []) do
    scrubbed()
    |> Map.new()
    |> Map.merge(Map.new(env))
    |> Enum.map(fn {k, v} -> {to_charlist(k), if(v == nil, do: false, else: to_charlist(v))} end)
  end

  @doc """
  Builds a `System.cmd/3` `env:` list (strings, `nil` unsets): every ambient knob unset,
  then `env` applied on top.
  """
  @spec cmd_env(Enumerable.t()) :: [{String.t(), String.t() | nil}]
  def cmd_env(env \\ []) do
    scrubbed() |> Map.new() |> Map.merge(Map.new(env)) |> Enum.to_list()
  end

  @doc """
  Removes every ambient knob from this VM's environment and registers an `on_exit/1`
  that restores each one to its previous value (or leaves it unset). Call from `setup`.
  """
  @spec scrub_ambient!() :: :ok
  def scrub_ambient! do
    saved = Enum.map(vm_names(), &{&1, System.get_env(&1)})
    Enum.each(vm_names(), &System.delete_env/1)

    ExUnit.Callbacks.on_exit(fn -> restore(saved) end)
  end

  @doc """
  Runs `fun` with every ambient knob removed from this VM's environment, restoring them
  afterwards (also when `fun` raises).
  """
  @spec with_clean_env((-> result)) :: result when result: var
  def with_clean_env(fun) when is_function(fun, 0) do
    saved = Enum.map(vm_names(), &{&1, System.get_env(&1)})
    Enum.each(vm_names(), &System.delete_env/1)

    try do
      fun.()
    after
      restore(saved)
    end
  end

  defp restore(saved) do
    Enum.each(saved, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
