defmodule Letflow.Scripts.TestParallelPoolClampTest do
  @moduledoc """
  GH #2630: arithmetic of the pool clamp in `scripts/test_parallel.sh` (Step 1.5), run as the
  script's own text (the block from the `TEST_POOL_SIZE` guard to the ISS-0297 marker) under
  bash with `N` preset, so nothing else the script does (compiling, DB) runs.

  Expected pool sizes are hand-computed oracles, not read from the script:
  `floor((max - superuser_reserved - headroom - nonpool_reserve - N*per_partition_headroom) / N)`.
  `async: true` is safe: each case is a child process with an explicit env.
  """

  use ExUnit.Case, async: true

  alias Letflow.Test.TestParallelEnv

  @script Path.expand("../../scripts/test_parallel" <> ".sh", __DIR__)

  defp clamp_block do
    src = File.read!(@script)
    [_, rest] = String.split(src, ~s(if [ -z "${TEST_POOL_SIZE:-}" ]; then), parts: 2)
    [block, _] = String.split(rest, "# ISS-0297", parts: 2)
    ~s(if [ -z "${TEST_POOL_SIZE:-}" ]; then) <> block
  end

  defp pool(n, env) do
    bash = System.find_executable("bash") || flunk("bash is required")
    script = "N=#{n}\n" <> clamp_block() <> "\necho \"POOL=$TEST_POOL_SIZE\"\n"

    {out, status} =
      System.cmd(bash, ["-c", script],
        env: TestParallelEnv.cmd_env(env),
        stderr_to_stdout: true
      )

    {status, out}
  end

  defp pool_value(out),
    do: out |> then(&Regex.run(~r/POOL=(\d+)/, &1)) |> Enum.at(1) |> String.to_integer()

  test "script default (reserve 5): N=4 gives 20, the pre-#2630 hosted-CI value" do
    assert {0, out} = pool(4, [])
    assert pool_value(out) == 20
    assert out =~ "nonpool_reserve=5"
  end

  test "CI reserve 16, N=4, max 100: (97 - 10 - 16) / 4 = 17; worst case 86 of 97" do
    assert {0, out} = pool(4, [{"TEST_NONPOOL_CONNECTION_RESERVE", "16"}])
    assert pool_value(out) == 17
    assert out =~ "nonpool_reserve=16"

    # 4 partitions x pool + 4 nested children x cap (4) + 2 external (probe, tune).
    cap = Letflow.Test.NestedMix.pool_size()
    assert 4 * 17 + 4 * cap + 2 == 86
    assert 86 <= 100 - 3
  end

  test "the reserve scales the budget: 16 -> 17, 5 -> 20, 0 -> 21 at N=4" do
    for {reserve, expected} <- [{"16", 17}, {"5", 20}, {"0", 21}] do
      assert {0, out} = pool(4, [{"TEST_NONPOOL_CONNECTION_RESERVE", reserve}])
      assert pool_value(out) == expected, "reserve #{reserve}: #{out}"
    end
  end

  test "a caller-set TEST_POOL_SIZE is never overridden by the clamp" do
    assert {0, out} = pool(4, [{"TEST_POOL_SIZE", "9"}])
    assert pool_value(out) == 9
    assert out =~ "caller override"
  end

  test "ci.yml: only backend_shard's `Run test shard` step env sets the reserve, to \"16\"" do
    jobs =
      Path.expand("../../.github/workflows/ci.yml", __DIR__)
      |> YamlElixir.read_from_file!()
      |> Map.fetch!("jobs")

    step_env = fn job ->
      for step <- Map.get(job, "steps", []),
          {k, v} <- Map.get(step, "env", %{}),
          do: {step["name"], k, v}
    end

    reserve = fn job ->
      job_level =
        for {k, v} <- Map.get(job, "env", %{}),
            k == "TEST_NONPOOL_CONNECTION_RESERVE",
            do: {nil, k, v}

      job_level ++
        Enum.filter(step_env.(job), fn {_, k, _} -> k == "TEST_NONPOOL_CONNECTION_RESERVE" end)
    end

    assert [{"Run test shard", "TEST_NONPOOL_CONNECTION_RESERVE", "16"}] =
             Enum.map(reserve.(jobs["backend_shard"]), fn {n, k, v} -> {n, k, to_string(v)} end)

    for {name, job} <- jobs, name != "backend_shard" do
      assert reserve.(job) == [], "job #{name} must not set the reserve"
    end
  end
end
