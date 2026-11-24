defmodule Letflow.CiSelectTestsTest do
  @moduledoc """
  T-1297 (L-24): `scripts/ci_select_tests.py` decides, from the changed-file list, whether a run
  executes bounded related backend tests or the extended suite; `ci.yml` wires it in. These tests run
  the real script against this repository's tree and pin the workflow's contract (required check
  names, 8-shard matrix, full-run paths, markers).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @script "scripts/ci_select_tests.py"
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")
  @leaf "lib/letflow/modules/locations/tree.ex"

  @inventory_tests ~w(
    test/letflow/routers/tenant_admin_routes_test.exs
    test/letflow/routers/platform_scope_routes_test.exs
    test/letflow/api/platform_scope_inventory_test.exs
    test/letflow/scope_enforcement_on_e2e_test.exs
    test/letflow/scope_enforcement_flip_authority_test.exs
  )

  for {rule, path} <- [
        {"router", "lib/letflow/routers/me.ex"},
        {"module router", "lib/letflow/modules/stock/router.ex"},
        {"root router", "lib/letflow/router.ex"},
        {"route table", "lib/letflow/api/route_scope.ex"},
        {"route fixture", "test/fixtures/route_scope/tenant_wide_default_routes.txt"},
        {"plug", "lib/letflow/plugs/api_pipeline.ex"},
        {"authorization", "lib/letflow/api/authorization.ex"},
        {"permission", "lib/letflow/api/permission_matrix.ex"},
        {"scope", "lib/letflow/scope_enforcement/on_gate.ex"},
        {"module policies", "lib/letflow/modules/stock/stock.ex"},
        {"deleted router", "lib/letflow/routers/removed_t2223.ex"}
      ] do
    @tag timeout: 30_000
    test "I1 #{rule}: inventory checks survive bounded admission" do
      {kv, plan} = select([unquote(path)])
      assert kv["mode"] == "selective"
      assert length(plan) <= 160

      for test <- @inventory_tests do
        assert Enum.any?(plan, &String.ends_with?(&1, " " <> test)),
               "#{unquote(path)}: missing #{test}"
      end
    end
  end

  for path <- [
        "lib/letflow/engine/join_counter.ex",
        "priv/modules/stock/pack.json",
        "priv/repo/migrations/deleted_t2223.exs",
        "config/runtime.exs",
        "scripts/ci_select_tests.py",
        "scripts/new_t2223.py",
        ".github/workflows/ci.yml",
        ".github/actions/new_t2223/action.yml",
        "deploy/new_t2223.conf",
        "rel/overlays/new_t2223.sh",
        "mix.exs"
      ] do
    @tag timeout: 30_000
    test "I2 flag scan input #{path}: AC24 is in the final plan" do
      {kv, plan} = select([unquote(path)])
      assert kv["mode"] == "selective"

      assert Enum.any?(
               plan,
               &String.ends_with?(&1, " test/letflow/scope_enforcement_flip_authority_test.exs")
             )
    end
  end

  test "I3: unrelated web changes do not reserve conditional inventories" do
    {_, plan} = select(["web/src/x.tsx"])

    for test <- @inventory_tests do
      refute Enum.any?(plan, &String.ends_with?(&1, " " <> test))
    end
  end

  test "I4: every audit-route and platform-scope sibling is reserved" do
    siblings =
      Path.wildcard(Path.join(@root, "test/**/*_test.exs"))
      |> Enum.filter(fn path ->
        text = File.read!(path)
        String.contains?(text, "audit_routes") or String.contains?(text, "platform-scope route")
      end)
      |> Enum.map(&Path.relative_to(&1, @root))

    {_, plan} = select(["lib/letflow/routers/me.ex"])

    for test <- siblings -- ["test/letflow/ci_select_tests_test.exs"] do
      assert Enum.any?(plan, &String.ends_with?(&1, " " <> test)), "missing sibling #{test}"
    end
  end

  test "I5: inventories precede overflow and fail closed if the budget cannot hold them" do
    code = """
    import importlib.util, types
    spec = importlib.util.spec_from_file_location('selector', 'scripts/ci_select_tests.py')
    s = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(s)
    files = [p for p in s.tracked('.') if p.startswith('test/') and p.endswith('_test.exs')]
    changed = ['lib/letflow/routers/me.ex']
    args = types.SimpleNamespace(root='.', shards=8, per_shard=4, target_ms=120000, standard_max_tests=160)
    weights, _ = s.read_manifest('test/shard_manifest.txt')
    lines, _, deferred = s.bounded_plan(files, changed, weights, args, files)
    required = s.inventory_tests(changed, files, '.')
    assert required <= {line.split()[1] for line in lines}
    assert required.isdisjoint(deferred)
    assert deferred and len(lines) <= 160
    totals = {}
    for line in lines:
        part, test = line.split()
        totals[part] = totals.get(part, 0) + max(1000, weights.get(test) or 15000)
    assert max(totals.values()) <= args.target_ms
    args.target_ms = 1
    try:
        s.bounded_plan(files, changed, weights, args, files)
    except ValueError as error:
        assert 'mandatory global check does not fit' in str(error)
    else:
        raise AssertionError('required checks must never be silently deferred')
    print('inventory budget PASS')
    """

    assert {"inventory budget PASS\n", 0} =
             System.cmd("python3", ["-I", "-B", "-c", code], cd: @root, stderr_to_stdout: true)
  end

  test "B7: identity risk coverage includes the enforcement family of root-level tests" do
    code = """
    import importlib.util
    spec = importlib.util.spec_from_file_location('selector', 'scripts/ci_select_tests.py')
    s = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(s)
    family = ['test/letflow/scope_enforcement_test.exs',
              'test/letflow/scope_enforcement_on_e2e_test.exs',
              'test/letflow/scope_enforcement_flip_authority_test.exs']
    unrelated = 'test/letflow/scope_node_paths_test.exs'
    selected = s.risk_tests(['lib/letflow/identity.ex'], family + [unrelated], '.')
    assert selected == set(family), selected
    print('enforcement family PASS')
    """

    assert {"enforcement family PASS\n", 0} =
             System.cmd("python3", ["-I", "-B", "-c", code], cd: @root, stderr_to_stdout: true)
  end

  @tag timeout: 120_000
  test "B1: standard fallback cases always produce a bounded plan" do
    for event <- ["pull_request", "merge_group", "push"],
        files <- [
          ["lib/letflow/modules/stock/stock.ex", "docs/roles.md"],
          ["config/config.exs"],
          ["lib/letflow/identity.ex"],
          ["priv/permission_matrix/effective.golden"],
          for(i <- 1..45, do: "docs/note#{i}.md")
        ] do
      {kv, plan} = select(files, ["--event", event])
      assert kv["mode"] == "selective", "#{event} #{inspect(files)}: #{inspect(kv)}"
      assert plan != []
      assert length(plan) <= 160

      assert Enum.any?(
               plan,
               &String.ends_with?(&1, " test/letflow/api/permission_matrix_test.exs")
             )
    end
  end

  test "B5: stock and web changes retain fixed identity, global and security-probe pins" do
    for changed <- ["lib/letflow/modules/stock/stock.ex", "web/src/x.tsx"] do
      {_, plan} = select([changed])

      for test <- [
            "test/letflow/api/permission_matrix_test.exs",
            "test/letflow/identity/binding_writers_scan_test.exs",
            "test/letflow/identity/tenant_update_changeset_removed_test.exs",
            "test/letflow/security_probe/g01_matrix_shard_0_test.exs",
            "test/letflow/security_probe/g01_matrix_shard_1_test.exs",
            "test/letflow/security_probe/g01_matrix_shard_2_test.exs",
            "test/letflow/security_probe/g01_matrix_shard_3_test.exs",
            "test/letflow/security_probe/g01_route_role_matrix_test.exs",
            "test/letflow/security_probe/g02_writer_start_inventory_test.exs",
            "test/letflow/security_probe/g05_audit_writer_matrix_test.exs",
            "test/letflow/security_probe/g05_audit_row_schema_test.exs",
            "test/letflow/security_probe/g08_uat_safety_equivalence_test.exs",
            "test/letflow/security_probe/g09_migration_impact_test.exs",
            "test/letflow/security_probe/g06_outbound_http_inventory_test.exs",
            "test/letflow/security_probe/g06_outbound_dispatch_probes_test.exs",
            "test/letflow/security_probe/g07_cursor_codec_probe_test.exs",
            "test/letflow/security_probe/g07_cursor_traversal_probe_test.exs",
            "test/letflow/security_probe/g03_source_provenance_test.exs",
            "test/letflow/security_probe/g13_malformed_input_matrix_test.exs",
            "test/letflow/security_probe/g13_route_no_5xx_test.exs",
            "test/letflow/security_probe/g11_route_inventory_probe_test.exs",
            "test/letflow/security_probe/g11_secret_scan_probe_test.exs"
          ] do
        assert Enum.any?(plan, &String.ends_with?(&1, " " <> test)), "#{changed}: missing #{test}"
      end
    end

    backend =
      @ci_yml |> YamlElixir.read_from_file!() |> get_in(["jobs", "changes", "outputs", "backend"])

    assert backend == "true"
  end

  # G-09: a tenant-migration change shifts the manifest positions the tenant tests pin. The
  # manifest-position, table-oracle and replay cases are mandatory for it: they may not be
  # deferred to the nightly run.
  test "B5m: a migration change runs every manifest-position, table-oracle and replay test" do
    for changed <- [
          "priv/repo/migrations/20261121100001_allow_zero_count_set_legs.exs",
          "lib/letflow/tenant_provisioning.ex"
        ] do
      {kv, plan} = select([changed])
      assert kv["mode"] == "selective", "#{changed}: #{inspect(kv)}"

      listed =
        "test/fixtures/security_probes/g09_migration_impact_tests.txt"
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

      assert listed != [], "the migration impact list is empty"

      for test <- listed do
        assert Enum.any?(plan, &String.ends_with?(&1, " " <> test)), "#{changed}: missing #{test}"
      end
    end
  end

  @tag :tmp_dir
  test "B6: a bounded green push cannot clear a red nightly", %{tmp_dir: dir} do
    step =
      @ci_yml
      |> YamlElixir.read_from_file!()
      |> get_in(["jobs", "full_run_marker", "steps"])
      |> Enum.find(&(&1["name"] == "Move the markers"))

    git = Path.join(dir, "git")

    File.write!(
      git,
      "#!/bin/sh\necho \"$*\" >> \"$GIT_CALLS\"\n[ \"$*\" != 'rev-parse HEAD' ] || echo head456\nexit 0\n"
    )

    File.chmod!(git, 0o755)
    calls = Path.join(dir, "calls.txt")

    for {event, frontend, clears?} <- [
          {"push", "success", false},
          {"schedule", "success", true},
          {"workflow_dispatch", "success", true},
          {"schedule", "failure", false}
        ] do
      File.write!(calls, "")

      {out, 0} =
        System.cmd("bash", ["-c", step["run"]],
          cd: @root,
          stderr_to_stdout: true,
          env: [
            {"PATH", dir <> ":" <> System.get_env("PATH")},
            {"GIT_CALLS", calls},
            {"RESULT", "success"},
            {"EVENT_NAME", event},
            {"FRONTEND_RESULT", frontend},
            {"MOBILE_RESULT", "success"},
            {"GITHUB_STEP_SUMMARY", Path.join(dir, "summary.md")}
          ]
        )

      assert String.contains?(File.read!(calls), "push origin :refs/tags/ci-main-red") == clears?,
             out
    end
  end

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

  @tag timeout: 120_000
  test "S3: sensitive paths select bounded high-risk coverage" do
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
      assert kv["mode"] == "selective", "#{p}: #{inspect(kv)}"
      assert kv["reason"] != ""
    end
  end

  @tag timeout: 120_000
  test "S3b: module-write authorization and module installs select high-risk tests" do
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
      assert kv["mode"] == "selective", "#{p}: #{inspect(kv)}"
    end
  end

  @tag timeout: 120_000
  test "S3d: role and permission seeding selects bounded coverage" do
    for p <- [
          "priv/permission_matrix/effective.golden",
          "test/support/tenant_fixture.ex",
          "lib/letflow/identity.ex",
          "lib/letflow/identity/role_registry.ex",
          "lib/letflow/identity/role_backfill.ex",
          "lib/letflow/identity_migration.ex"
        ] do
      {kv, _} = select([p])
      assert kv["mode"] == "selective", "#{p}: #{inspect(kv)}"
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

  test "S4: more than 40 changed files select bounded coverage" do
    files = for i <- 1..41, do: "docs/note#{i}.md"
    {kv, _} = select(files)
    assert kv["mode"] == "selective"
    assert kv["reason"] =~ "41 changed files"
  end

  test "S5: only nightly and manual run can run the full suite" do
    {kv, plan} = select([@leaf], ["--kill-switch", "off"])
    assert kv["mode"] == "selective"
    assert kv["reason"] =~ "kill switch"
    assert plan != []

    for ev <- ["schedule", "workflow_dispatch"] do
      {kv, _} = select([@leaf], ["--event", ev])
      assert kv["mode"] == "full", ev
    end

    assert {%{"mode" => "selective"}, [_ | _]} = select([])
  end

  test "S7: red-main fix and missing timing manifest stay bounded" do
    {kv, _} = select([@leaf], ["--force-full", "main red, fix group"])

    assert kv["mode"] == "selective"
    assert kv["reason"] =~ "main red, fix group (bounded repair)"

    {kv, _} = select([@leaf], ["--manifest", "test/does_not_exist.txt"])
    assert kv["mode"] == "selective"
    assert kv["reason"] =~ "unreadable"
  end

  test "S8: a deleted lib file uses the bounded safety set" do
    {kv, _} = select(["lib/letflow/no_such_file_t1297.ex"])
    assert kv["mode"] == "selective"
    assert kv["reason"] =~ "removed or renamed"
  end

  test "B2: partition budgets defer overflow in priority order" do
    code = """
    import importlib.util, json, types
    spec = importlib.util.spec_from_file_location('selector', 'scripts/ci_select_tests.py')
    s = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(s)
    files = ['test/letflow/example/case%d_test.exs' % i for i in range(200)]
    args = types.SimpleNamespace(root='.', shards=2, per_shard=4, target_ms=10000, standard_max_tests=160)
    weights = dict.fromkeys(files, 3000)
    lines, skip, deferred = s.bounded_plan(files, [files[-1]], weights, args, files)
    chosen = [line.split()[1] for line in lines]
    totals = {}
    for line in lines:
        part, test = line.split()
        totals[part] = totals.get(part, 0) + weights[test]
    assert files[-1] in chosen, 'changed test has first priority'
    assert max(totals.values()) <= args.target_ms
    assert set(chosen).isdisjoint(deferred)
    assert set(chosen) | set(deferred) == set(files)
    assert len(chosen) == 24 and len(deferred) == 176
    print('bounded priority and overflow PASS')
    """

    assert {"bounded priority and overflow PASS\n", 0} =
             System.cmd("python3", ["-I", "-B", "-c", code], cd: @root, stderr_to_stdout: true)
  end

  @tag :tmp_dir
  test "B3: nightly summary names missed failures and handles missing evidence", %{tmp_dir: dir} do
    logs = Path.join(dir, "letflow_test_parallel.fixture")
    File.mkdir_p!(logs)
    plan = Path.join(dir, "standard.txt")
    File.write!(plan, "1 test/letflow/known_test.exs\n")

    File.write!(Path.join(logs, "partition-1.log"), """
      1) test missed branch (Letflow.MissedTest)
         test/letflow/missed_test.exs:12
         Assertion failed
      2) test already covered (Letflow.KnownTest)
         test/letflow/known_test.exs:9
    """)

    {out, 0} =
      System.cmd(
        "python3",
        [
          "-I",
          @script,
          "--nightly-log-dir",
          dir,
          "--standard-plan",
          plan,
          "--commit-range",
          "base123..head456"
        ],
        cd: @root
      )

    assert out =~ "selector miss count: 1"
    assert out =~ "Compared commit range: `base123..head456`"
    assert out =~ "selector miss: `test/letflow/missed_test.exs` — test missed branch"
    refute out =~ "selector miss: `test/letflow/known_test.exs`"

    {out, 0} =
      System.cmd("python3", ["-I", @script, "--nightly-log-dir", dir], cd: @root)

    assert out =~ "Selector coverage unavailable"
    refute out =~ "selector miss count: 0"
  end

  @tag :tmp_dir
  test "B4: the workflow fails closed on selector failure or an unbounded response", %{
    tmp_dir: dir
  } do
    step =
      @ci_yml
      |> YamlElixir.read_from_file!()
      |> get_in(["jobs", "changes", "steps"])
      |> Enum.find(&(&1["id"] == "select"))

    File.mkdir_p!(Path.join(dir, "scripts"))

    for script <- ["ci_kill_switch.sh", "ci_emit_outputs.sh"] do
      File.cp!(Path.join([@root, "scripts", script]), Path.join([dir, "scripts", script]))
    end

    for body <- [
          "raise SystemExit(1)",
          "print('mode=full\\nreason=unsafe fallback\\nskip_shards=')",
          "print('mode=broken\\nreason=malformed\\nskip_shards=')",
          "print('mode=selective\\nreason=missing plan\\nskip_shards=')"
        ] do
      File.write!(Path.join([dir, "scripts", "ci_select_tests.py"]), body)
      output = Path.join(dir, "outputs.txt")
      File.write!(output, "")

      {out, status} =
        System.cmd("bash", ["-c", step["run"]],
          cd: dir,
          stderr_to_stdout: true,
          env: [
            {"EVENT_NAME", "push"},
            {"RUNNER_TEMP", dir},
            {"GITHUB_OUTPUT", output},
            {"GITHUB_STEP_SUMMARY", Path.join(dir, "summary.md")},
            {"PUSH_BEFORE", String.duplicate("0", 40)},
            {"PUSH_AFTER", "unavailable"},
            {"KILL", ""},
            {"PROBE", "false"},
            {"FORCE_FULL", "bounded repair test"}
          ]
        )

      assert status == 1, out
      assert out =~ "refusing to run without a bounded plan"
      refute File.read!(output) =~ "mode=full"
    end
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

  test "S10: web-only change runs the fixed safety set" do
    {kv, plan} = select(["web/src/x.tsx"])
    assert kv["mode"] == "selective"
    assert String.to_integer(kv["selected_count"]) >= 9
    assert plan != []
    refute kv["skip_shards"] == "1 2 3 4 5 6 7 8"
  end

  # T-2606 (G18): the UAT runner tooling has no mix test of its own; the test that runs its stdlib suite
  # is a mandatory check for a change of that tooling, so it may not be deferred to the nightly run.
  describe "UAT runner tooling (T-2606)" do
    @tag timeout: 30_000
    test "a change of the UAT runner runs the test of that tooling" do
      {kv, plan} = select(["scripts/uat/runner.py"])
      assert kv["mode"] == "selective"
      assert Enum.any?(plan, &String.ends_with?(&1, " test/scripts/uat_tooling_test.exs"))
    end

    @tag timeout: 30_000
    test "a change of a test of the UAT tooling runs the test of that tooling" do
      {_, plan} = select(["scripts/uat/tests/test_platform_residue.py"])
      assert Enum.any?(plan, &String.ends_with?(&1, " test/scripts/uat_tooling_test.exs"))
    end
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

    test "M4: a priv/modules change spanning two modules stays bounded" do
      {kv, _} = select([@stock_priv, "priv/modules/exam/pack.json"])
      assert kv["mode"] == "selective", inspect(kv)
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
