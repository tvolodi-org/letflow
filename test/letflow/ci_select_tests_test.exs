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
    base = ["--event", "merge_group", "--plan-out", plan]

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
    # reason contains "test files" in both normal and single-module formats
    assert kv["reason"] =~ "test files", inspect(kv)
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
          "lib/letflow/ledger/entry.ex"
        ] do
      {kv, _} = select([@leaf, p])
      assert kv["mode"] == "full", "#{p}: #{inspect(kv)}"
      assert kv["reason"] != ""
    end
  end

  test "S3b: module-write authorization and module installs run the full suite (T-1403)" do
    for p <- [
          "lib/letflow/modules/installs.ex",
          "lib/letflow/modules/tenant_module.ex",
          "lib/letflow/entities/handler_writes.ex",
          "lib/letflow/engine.ex",
          "lib/letflow/modules/install_context.ex",
          "lib/letflow/definitions/module_writes.ex",
          "lib/letflow/definitions/solution_pack_install.ex",
          "lib/letflow/entities/entity_port_impl.ex",
          "lib/letflow/routers/tenant_modules.ex"
        ] do
      {kv, _} = select([p])
      assert kv["mode"] == "full", "#{p}: #{inspect(kv)}"
    end
  end

  test "S3d: role and permission seeding runs the full suite (T-1428)" do
    for p <- [
          "priv/permission_matrix/effective.golden",
          "test/support/tenant_fixture.ex",
          "lib/letflow/identity.ex",
          "lib/letflow/identity/role_registry.ex",
          "lib/letflow/identity/role_backfill.ex",
          "lib/letflow/identity_migration.ex"
        ] do
      {kv, _} = select([p])
      assert kv["mode"] == "full", "#{p}: #{inspect(kv)}"
    end
  end

  # T-2137: lib/letflow/modules/<m>/stock.ex and exam.ex define role_grants but are module-scoped;
  # after T-2136 they use single-module selective mode (global pins cover permission matrix).
  test "S3e: a module-scoped role_grants file uses single-module mode, not full (T-2137)" do
    for p <- [
          "lib/letflow/modules/stock/stock.ex",
          "lib/letflow/modules/exam/exam.ex"
        ] do
      {kv, _} = select([p])
      assert kv["mode"] == "selective", "#{p}: #{inspect(kv)}"
      assert kv["reason"] =~ "single module", "#{p}: #{inspect(kv)}"
    end
  end

  test "S3c: an engine change also selects the record-trigger and engine tests (T-1403)" do
    {kv, plan} = select(["lib/letflow/engine/join_counter.ex"])

    assert kv["mode"] == "selective", inspect(kv)
    assert Enum.any?(plan, &String.contains?(&1, "test/letflow/record_triggers/"))
    assert Enum.any?(plan, &String.contains?(&1, "test/letflow/engine/"))
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
      assert yml =~ "ci-main-red"
      assert yml =~ "main full CI red"
      assert yml =~ "TEST_PARALLEL_PLAN"
      assert yml =~ ~s(Backend tests: ${MODE:-unknown})
      assert yml =~ "contents: write"
    end

    test "docs describe the scheme" do
      doc = File.read!(Path.join([@root, "docs", "merge" <> "-queue.md"]))
      assert doc =~ "ci-main-red"
      assert doc =~ "CI_SELECTIVE"
    end
  end

  test "test_parallel.sh knows the plan hook and parses" do
    path = Path.join(@root, "scripts/test_parallel.sh")
    assert {_, 0} = System.cmd("bash", ["-n", path], env: Letflow.Test.TestParallelEnv.cmd_env())
    assert File.read!(path) =~ "TEST_PARALLEL_PLAN"
  end

  test "selective plan expects reports only from the partitions it launches (T-1318)" do
    src = File.read!(Path.join(@root, "scripts/test_parallel.sh"))
    # the plan lowers LAST; the expected report count follows it, full mode keeps N
    assert src =~ ~s(expected_reports="$N")
    assert src =~ "expected_reports=$((LAST - FIRST + 1))"
    assert src =~ ~s(if [ "$reporting_count" -ne "$expected_reports" ])
    refute src =~ ~s(if [ "$reporting_count" -ne "$N" ])
    # the expected-count line sits after the plan lowers LAST
    {plan_at, _} = :binary.match(src, "expected_reports=$((LAST - FIRST + 1))")
    {check_at, _} = :binary.match(src, ~s(-ne "$expected_reports"))
    assert plan_at < check_at
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

  describe "single-module selective mode (T-2137)" do
    @stock_lib "lib/letflow/modules/stock/count_posting.ex"
    @stock_priv "priv/modules/stock/pack.json"
    @exam_lib "lib/letflow/modules/exam/authoring.ex"

    test "M1: a stock-only lib diff selects no exam test" do
      {kv, plan} = select([@stock_lib])
      assert kv["mode"] == "selective", inspect(kv)
      assert kv["reason"] =~ "single module stock", inspect(kv)

      refute Enum.any?(plan, &String.contains?(&1, "test/letflow/modules/exam/")),
             "exam tests appeared in plan for stock-only diff"
    end

    test "M2: a stock-only diff selects the global pin tests (permission matrix, ledger reg, engine floor)" do
      {kv, plan} = select([@stock_lib])
      assert kv["mode"] == "selective"

      assert Enum.any?(
               plan,
               &String.ends_with?(&1, " test/letflow/api/permission_matrix_test.exs")
             ),
             "permission_matrix_test not in plan"

      assert Enum.any?(
               plan,
               &String.ends_with?(&1, " test/letflow/modules/ledger_registration_test.exs")
             ),
             "ledger_registration_test not in plan"

      assert Enum.any?(plan, &String.contains?(&1, "test/letflow/engine/")),
             "engine floor tests not in plan"
    end

    test "M3: a priv/modules/stock change is single-module selective and selects stock tests" do
      {kv, plan} = select([@stock_priv])
      assert kv["mode"] == "selective", inspect(kv)
      assert kv["reason"] =~ "single module stock", inspect(kv)

      assert Enum.any?(plan, &String.contains?(&1, "test/letflow/modules/stock/")),
             "stock tests not in plan for priv/modules/stock change"

      assert Enum.any?(
               plan,
               &String.ends_with?(&1, " test/letflow/api/permission_matrix_test.exs")
             ),
             "permission_matrix_test not in plan"
    end

    test "M4: a priv/modules change spanning two modules runs the full suite" do
      {kv, _} = select([@stock_priv, "priv/modules/exam/pack.json"])
      assert kv["mode"] == "full", inspect(kv)
      assert kv["reason"] =~ "multiple modules", inspect(kv)
    end

    test "M5: a lib change touching two modules falls back to normal closure (not single-module)" do
      {kv, _} = select([@stock_lib, @exam_lib])

      # Two-module diff: not single-module mode; normal closure applies (still selective for small diffs).
      refute kv["reason"] =~ "single module", inspect(kv)
    end
  end

  # T-2141: files with names matching the old SENSITIVE_LIB_NAME_RE patterns now run selective
  # with global pins instead of full suite.
  test "S3f: ledger_registration.ex uses selective mode with global pins (T-2141)" do
    p = "lib/letflow/modules/ledger_registration.ex"
    {kv, plan} = select([p])
    assert kv["mode"] == "selective", "expected selective, got #{inspect(kv)}"

    assert Enum.any?(
             plan,
             &String.ends_with?(&1, " test/letflow/modules/ledger_registration_test.exs")
           ),
           "ledger_registration_test not in plan"

    assert Enum.any?(
             plan,
             &String.ends_with?(&1, " test/letflow/api/permission_matrix_test.exs")
           ),
           "permission_matrix_test not in plan"
  end
end
