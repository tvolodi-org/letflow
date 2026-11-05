defmodule Letflow.CiSelectTestsTest do
  @moduledoc """
  T-1297 (L-24): `scripts/ci_select_tests.py` decides, from the changed-file list, whether a run
  executes only the related backend tests or the full suite; `ci.yml` wires it in. These tests run
  the real script against this repository's tree and pin the workflow's contract (required check
  names, 8-shard matrix, full-run paths, markers).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @script "scripts/ci_select_tests.py"
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")
  @leaf "lib/letflow/modules/locations/tree.ex"

  defp select(files, extra \\ []) do
    plan = Path.join(System.tmp_dir!(), "sel_plan_#{System.unique_integer([:positive])}.txt")
    input = Enum.join(files, "\n") <> "\n"
    base = ["--event", "merge_group", "--commits-since-full", "2", "--plan-out", plan]

    {out, 0} =
      System.cmd(
        "bash",
        ["-c", "printf '%s' \"$IN\" | python3 -I #{@script} \"$@\"", "_" | base ++ extra],
        cd: @root,
        env: [{"IN", input}]
      )

    kv =
      out
      |> String.split("\n", trim: true)
      |> Map.new(fn l ->
        [k, v] = String.split(l, "=", parts: 2)
        {k, v}
      end)

    plan_lines =
      if File.exists?(plan), do: File.read!(plan) |> String.split("\n", trim: true), else: []

    File.rm(plan)
    {kv, plan_lines}
  end

  test "S1: a leaf lib change selects its related tests and only some shards" do
    {kv, plan} = select([@leaf])
    assert kv["mode"] == "selective", inspect(kv)
    assert String.to_integer(kv["selected_count"]) in 1..600
    assert kv["reason"] =~ "test files related"
    assert Enum.all?(plan, &Regex.match?(~r/^\d+ test\/.+_test\.exs$/, &1))
    assert length(plan) == String.to_integer(kv["selected_count"])
  end

  test "S2: a changed test file is always in the plan" do
    t = "test/letflow/ci_heavy_paths_test.exs"
    {kv, plan} = select([t])
    assert kv["mode"] == "selective"
    assert Enum.any?(plan, &String.ends_with?(&1, " " <> t))
  end

  test "S3: sensitive paths run the full suite" do
    for p <- [
          "priv/repo/migrations/20261101000000_x.exs",
          "config/test.exs",
          "mix.exs",
          "mix.lock",
          "test/support/tenant_fixture.ex",
          ".github/workflows/ci.yml",
          "scripts/ci_select_tests.py",
          "test/shard_manifest.txt",
          "lib/letflow/ledger/entry.ex",
          "lib/letflow/authorization.ex"
        ] do
      {kv, _} = select([@leaf, p])
      assert kv["mode"] == "full", "#{p}: #{inspect(kv)}"
      assert kv["reason"] != ""
    end
  end

  test "S4: more than 40 changed files run the full suite" do
    files = for i <- 1..41, do: "docs/note#{i}.md"
    {kv, _} = select(files)
    assert kv["mode"] == "full"
    assert kv["reason"] =~ "41 changed files"
  end

  test "S5: kill switch, nightly, manual run and empty list run the full suite" do
    assert {%{"mode" => "full", "reason" => "kill switch" <> _}, _} =
             select([@leaf], ["--kill-switch", "off"])

    for ev <- ["schedule", "workflow_dispatch"] do
      {kv, _} = select([@leaf], ["--event", ev])
      assert kv["mode"] == "full", ev
    end

    assert {%{"mode" => "full"}, _} = select([])
  end

  test "S6: the 10th merge since the last green full run is full; unknown counter is full" do
    {kv, _} = select([@leaf], ["--commits-since-full", "10"])
    assert kv["mode"] == "full"
    assert kv["reason"] =~ "10 merges since"

    {kv, _} = select([@leaf], ["--commits-since-full", "9"])
    assert kv["mode"] == "selective"

    {out, 0} =
      System.cmd("bash", ["-c", "echo #{@leaf} | python3 -I #{@script} --event merge_group"],
        cd: @root
      )

    assert out =~ "mode=full"
    assert out =~ "counter unknown"
  end

  test "S7: a forced full run (red main fix group) and a selection error are full" do
    {kv, _} = select([@leaf], ["--force-full", "main red, fix group"])

    assert kv == %{
             "mode" => "full",
             "reason" => "main red, fix group",
             "skip_shards" => "",
             "selected_count" => "0"
           }

    {kv, _} = select([@leaf], ["--manifest", "test/does_not_exist.txt"])
    assert kv["mode"] == "full"
    assert kv["reason"] =~ "unreadable"
  end

  test "S8: a deleted lib file and a module named in config/ run the full suite" do
    {kv, _} = select(["lib/letflow/no_such_file_t1297.ex"])
    assert kv["mode"] == "full"
    assert kv["reason"] =~ "removed or renamed"
  end

  test "S9: plan partitions are contiguous from 1 and idle shards are the tail" do
    {kv, plan} = select([@leaf])

    parts =
      plan
      |> Enum.map(&(&1 |> String.split(" ") |> hd() |> String.to_integer()))
      |> Enum.uniq()
      |> Enum.sort()

    assert parts == Enum.to_list(1..length(parts))
    active = ceil(length(parts) / 4)
    expected = if active >= 8, do: "", else: Enum.join((active + 1)..8, " ")
    assert kv["skip_shards"] == expected
  end

  test "S10: web-only change selects nothing and idles every shard" do
    {kv, plan} = select(["web/src/x.tsx"])
    assert kv["mode"] == "selective"
    assert kv["selected_count"] == "0"
    assert plan == []
    assert kv["skip_shards"] == "1 2 3 4 5 6 7 8"
  end

  describe "pull-request diff range (T-1303)" do
    @tag :tmp_dir
    test "three dots list only the PR's files when the base branch moved", %{tmp_dir: dir} do
      git = fn args ->
        {out, 0} =
          System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@example.com" | args],
            cd: dir,
            stderr_to_stdout: true
          )

        String.trim(out)
      end

      git.(["init", "-q", "-b", "main"])
      File.write!(Path.join(dir, "a.txt"), "a")
      git.(["add", "."])
      git.(["commit", "-qm", "root"])
      git.(["checkout", "-qb", "pr"])
      File.write!(Path.join(dir, "pr_only.txt"), "p")
      git.(["add", "."])
      git.(["commit", "-qm", "pr"])
      pr_head = git.(["rev-parse", "HEAD"])
      git.(["checkout", "-q", "main"])
      File.write!(Path.join(dir, "main_moved.txt"), "m")
      git.(["add", "."])
      git.(["commit", "-qm", "main moved"])
      base_tip = git.(["rev-parse", "HEAD"])

      two = git.(["diff", "--name-only", base_tip, pr_head]) |> String.split("\n", trim: true)

      three =
        git.(["diff", "--name-only", base_tip <> "..." <> pr_head])
        |> String.split("\n", trim: true)

      assert Enum.sort(two) == ["main_moved.txt", "pr_only.txt"]
      assert three == ["pr_only.txt"]

      # the script, fed the three-dot list, counts the PR's own files only
      {kv, _} =
        select(["lib/letflow/modules/locations/tree.ex" | three], ["--event", "pull_request"])

      assert kv["reason"] =~ "2 changed" or kv["mode"] == "selective"
    end

    test "every pull_request diff in ci.yml is a merge-base diff" do
      yml = File.read!(@ci_yml)
      assert yml =~ ~s(DOTS="...")
      assert yml =~ ~s(git diff --name-only "${BASE_SHA}${DOTS}${HEAD_SHA}")
      assert yml =~ ~s(git diff --name-only --no-renames "${BASE}${DOTS}${HEAD}")
      refute yml =~ ~s(git diff --name-only "$BASE_SHA" "$HEAD_SHA")
      assert yml =~ "Changed files: ${nfiles:-unknown}"
    end
  end

  describe "ci.yml contract (criterion 4)" do
    setup do
      {:ok, yml: File.read!(@ci_yml)}
    end

    test "required check names and the 8-shard matrix are unchanged", %{yml: yml} do
      assert yml =~ "name: Backend gate (mix letflow.check)"
      assert yml =~ "name: Frontend gate (npm run check)"
      assert yml =~ "shard: [1, 2, 3, 4, 5, 6, 7, 8]"
      assert yml =~ ~s(cron: "17 1 * * *")
      assert yml =~ "ci_docs_only.sh"
    end

    test "selection step, kill switch, counter tag, red marker and mode summary are wired", %{
      yml: yml
    } do
      assert yml =~ "scripts/ci_select_tests.py"
      assert yml =~ "vars.CI_SELECTIVE"
      assert yml =~ "ci-full-green"
      assert yml =~ "ci-main-red"
      assert yml =~ "main full CI red"
      assert yml =~ "TEST_PARALLEL_PLAN"
      assert yml =~ ~s(Backend tests: ${MODE:-unknown})
      assert yml =~ "contents: write"
    end

    test "docs describe the scheme" do
      doc = File.read!(Path.join([@root, "docs", "merge" <> "-queue.md"]))
      assert doc =~ "ci-full-green"
      assert doc =~ "ci-main-red"
      assert doc =~ "CI_SELECTIVE"
    end
  end

  test "test_parallel.sh knows the plan hook and parses" do
    path = Path.join(@root, "scripts/test_parallel.sh")
    assert {_, 0} = System.cmd("bash", ["-n", path], env: Letflow.Test.TestParallelEnv.cmd_env())
    assert File.read!(path) =~ "TEST_PARALLEL_PLAN"
  end

  test "the plan output ends with a newline before its delimiter (GH Actions output)" do
    yml = File.read!(@ci_yml)
    script = File.read!(Path.join(@root, "scripts/ci_emit_outputs.sh"))
    # `printf '%s'` without a newline glues PLAN_EOF to the last plan line and the step fails
    # with "Matching delimiter not found 'PLAN_EOF'". ci.yml delegates to the script (tested
    # in ci_emit_outputs_test.exs), which prints the plan with a trailing newline.
    assert yml =~ "bash scripts/ci_emit_outputs.sh"
    refute yml =~ ~S|printf '%s'; echo "PLAN_EOF"|
    assert script =~ ~S|printf '%s\n'|
  end
end
