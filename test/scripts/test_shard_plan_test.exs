defmodule Letflow.Scripts.TestShardPlanTest do
  @moduledoc """
  GH #2380 step 2: `scripts/test_shard_plan.sh` builds the timing manifest
  (`--from-tsv`, LPT over measured per-module times) and keeps it in step with the test tree
  (`--append`). Each test runs the real script under bash on a small tree in `tmp_dir`, so the
  expected output is fixed by hand and does not depend on the repository's own test files.

  Needs a real `bash` (on Windows set `TEST_PARALLEL_BASH` or `UAT_PF_BASH`).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_shard_plan.sh", __DIR__)

  defp tree(root, paths) do
    for path <- paths do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "")
    end
  end

  # Returns {exit_status, lines} with the tool's own diagnostics (`test_shard_plan:`) removed.
  defp run_tool(root, args) do
    {out, status} =
      System.cmd(bash(), [script(), "--root", root | args], stderr_to_stdout: true)

    lines =
      out
      |> String.replace("\r", "")
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "test_shard_plan:"))

    {status, lines}
  end

  defp body(lines), do: Enum.reject(lines, &String.starts_with?(&1, "#"))

  test "PS-1: --from-tsv places the heaviest file first, into the lightest partition", %{
    tmp_dir: tmp
  } do
    tree(tmp, ~w(test/a_test.exs test/b_test.exs test/c_test.exs test/d_test.exs))

    tsv = Path.join(tmp, "run.tsv")

    File.write!(
      tsv,
      "r1\tj1\t1\tA\t100\ttest/a_test.exs\n" <>
        "r1\tj1\t1\tB\t60\ttest/b_test.exs\n" <>
        "r1\tj1\t2\tC\t50\ttest/c_test.exs\n"
    )

    {0, lines} = run_tool(tmp, ["--from-tsv", tsv, "--partitions", "2"])

    assert "# partitions: 2" in lines
    assert "# source: run r1 jobs j1" in lines

    # a (100) -> 1; b (60) -> 2; c (50) -> 2 (load 60 < 100); d (no timing, 0) -> 1 (load 100 < 110)
    assert body(lines) == [
             "1 test/a_test.exs 100.00",
             "1 test/d_test.exs 0.00",
             "2 test/b_test.exs 60.00",
             "2 test/c_test.exs 50.00"
           ]

    # deterministic: the same inputs give the same bytes
    assert run_tool(tmp, ["--from-tsv", tsv, "--partitions", "2"]) == {0, lines}
  end

  test "PS-2: --append drops a stale line and adds a new file with the median weight to the lightest partition",
       %{tmp_dir: tmp} do
    tree(tmp, ~w(test/a_test.exs test/b_test.exs test/c_test.exs))

    manifest = Path.join(tmp, "manifest.txt")

    File.write!(
      manifest,
      "# partitions: 2\n" <>
        "1 test/a_test.exs 100.00\n" <>
        "2 test/b_test.exs 60.00\n" <>
        "2 test/gone_test.exs 5.00\n"
    )

    # kept weights 100 and 60: lower median 60; loads 100 (p1) and 60 (p2), so c goes to p2
    assert run_tool(tmp, ["--append", manifest]) ==
             {0,
              [
                "# partitions: 2",
                "1 test/a_test.exs 100.00",
                "2 test/b_test.exs 60.00",
                "2 test/c_test.exs 60.00"
              ]}
  end
end
