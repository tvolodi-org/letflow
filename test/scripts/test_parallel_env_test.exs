defmodule Letflow.Scripts.TestParallelEnvTest do
  @moduledoc """
  Q-1037 / GH #2364: unit tests for `Letflow.Test.TestParallelEnv`, the shared helper that
  makes every test driving `scripts/test_parallel.sh` / `Mix.Tasks.Letflow.Check.Test.run/1`
  immune to the `TEST_PARALLEL_*` variables a sharded CI job exports.

  The expected-name list below is an INDEPENDENT oracle (written out by hand, not read from
  the helper) so removing one name from the helper fails here by name. A second test greps
  the real script for every `TEST_*` knob it reads and fails when the helper falls behind.
  `async: false`: mutates this VM's process environment.
  """

  use ExUnit.Case, async: false

  alias Letflow.Test.TestParallelEnv

  @must_scrub ~w(
    TEST_PARALLEL_N TEST_PARALLEL_SHARD TEST_PARALLEL_TOTAL TEST_PARALLEL_OFFSET
    TEST_PARALLEL_GROUP TEST_PARALLEL_EXTRA_ARGS TEST_PARALLEL_PRINT_SLOWEST
    TEST_PARALLEL_KEEP_LOGS TEST_PARALLEL_PARTITION_TIMEOUT_S TEST_PARALLEL_MANIFEST TEST_POOL_SIZE
  )

  defp script_path, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # Sets a sentinel for every VM-scrubbed name; the true ambient values are restored by an
  # on_exit registered FIRST, so it runs LAST (LIFO) -- after any restore under test.
  defp put_sentinels do
    original = Enum.map(TestParallelEnv.vm_names(), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {n, nil} -> System.delete_env(n)
        {n, v} -> System.put_env(n, v)
      end)
    end)

    Enum.each(TestParallelEnv.vm_names(), &System.put_env(&1, "sentinel-" <> &1))
  end

  for name <- @must_scrub do
    test "#{name} is scrubbed for a child process" do
      assert {unquote(name), nil} in TestParallelEnv.scrubbed()
    end
  end

  test "MIX_TEST_PARTITION is scrubbed for a child process but not from this VM" do
    assert {"MIX_TEST_PARTITION", nil} in TestParallelEnv.scrubbed()
    refute "MIX_TEST_PARTITION" in TestParallelEnv.vm_names()
  end

  test "every TEST_* knob scripts/test_parallel.sh reads is covered by the helper" do
    src = File.read!(script_path())

    read =
      ~r/\$\{?(TEST_[A-Z][A-Z_]*)/ |> Regex.scan(src) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    assert read != []
    missing = read -- TestParallelEnv.child_names()
    assert missing == [], "the script reads #{inspect(missing)} but the helper does not scrub it"
  end

  test "port_env/1 unsets every knob as `false`, charlist-encoded, and lets explicit values win" do
    env = TestParallelEnv.port_env([{"TEST_PARALLEL_N", "2"}, {"TEST_PARALLEL_SHARD", nil}])

    assert {~c"TEST_PARALLEL_N", ~c"2"} in env
    assert {~c"TEST_PARALLEL_SHARD", false} in env
    assert {~c"TEST_PARALLEL_TOTAL", false} in env
    assert {~c"MIX_TEST_PARTITION", false} in env
    assert Enum.uniq_by(env, &elem(&1, 0)) == env
  end

  test "port_env/1 accepts a map" do
    assert {~c"TEST_POOL_SIZE", ~c"4"} in TestParallelEnv.port_env(%{"TEST_POOL_SIZE" => "4"})
  end

  test "cmd_env/1 yields nil for scrubbed names and keeps explicit values" do
    env = TestParallelEnv.cmd_env([{"TEST_PARALLEL_N", "3"}])

    assert {"TEST_PARALLEL_N", "3"} in env
    assert {"TEST_PARALLEL_OFFSET", nil} in env
  end

  test "scrubbed env actually reaches a child: a spawned process sees none of the knobs" do
    put_sentinels()
    System.put_env("MIX_TEST_PARTITION", System.get_env("MIX_TEST_PARTITION") || "7")

    sh = System.find_executable("sh") || System.find_executable("bash")
    assert sh, "no sh/bash on PATH"

    {out, 0} =
      System.cmd(sh, ["-c", "env"], env: TestParallelEnv.cmd_env([{"TEST_PARALLEL_N", "9"}]))

    lines = out |> String.replace("\r", "") |> String.split("\n")
    assert "TEST_PARALLEL_N=9" in lines
    refute Enum.any?(lines, &String.starts_with?(&1, "TEST_PARALLEL_SHARD="))
    refute Enum.any?(lines, &String.starts_with?(&1, "TEST_PARALLEL_TOTAL="))
    refute Enum.any?(lines, &String.starts_with?(&1, "MIX_TEST_PARTITION="))
  end

  test "with_clean_env/1 removes the knobs inside and restores them after, also on raise" do
    put_sentinels()

    inside =
      TestParallelEnv.with_clean_env(fn ->
        Enum.map(TestParallelEnv.vm_names(), &System.get_env/1)
      end)

    assert Enum.all?(inside, &is_nil/1)
    assert System.get_env("TEST_PARALLEL_SHARD") == "sentinel-TEST_PARALLEL_SHARD"

    assert_raise RuntimeError, "boom", fn ->
      TestParallelEnv.with_clean_env(fn -> raise "boom" end)
    end

    assert System.get_env("TEST_PARALLEL_SHARD") == "sentinel-TEST_PARALLEL_SHARD"
    assert System.get_env("TEST_PARALLEL_N") == "sentinel-TEST_PARALLEL_N"
  end

  test "scrub_ambient!/0 deletes the knobs now and restores them when the test exits" do
    put_sentinels()

    # Registered AFTER put_sentinels' restore and BEFORE scrub_ambient!'s, so by LIFO order it
    # runs after scrub_ambient!'s restore and before put_sentinels'.
    on_exit(fn ->
      assert System.get_env("TEST_PARALLEL_SHARD") == "sentinel-TEST_PARALLEL_SHARD"
      assert System.get_env("TEST_PARALLEL_N") == "sentinel-TEST_PARALLEL_N"
    end)

    assert :ok = TestParallelEnv.scrub_ambient!()
    assert Enum.all?(TestParallelEnv.vm_names(), &(System.get_env(&1) == nil))
  end
end
