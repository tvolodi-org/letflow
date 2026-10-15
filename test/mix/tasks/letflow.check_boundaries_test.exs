defmodule Mix.Tasks.Letflow.CheckBoundariesTest do
  @moduledoc """
  Unit tests for `Mix.Tasks.Letflow.CheckBoundaries` — pure function tests for
  `classify_edge/2` and `parse_xref_output/1`, no DB or I/O required.

  REQ-405, WF02-REQ405-20260925. Design:
  `lib/letflow/design/req405-check-boundaries.md` §5.2.

  All tests are `async: true` — no shared state, no side effects.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckBoundaries, as: CB

  # ================================================================
  # classify_edge/2 — AC1 unit tests (one per case from design §2.3)
  # ================================================================

  describe "classify_edge/2" do
    test "VIOLATION: core file outside modules imports module-subdir file" do
      # Rule 5: source outside all module subdirs, target inside one
      edge = {"lib/letflow/routers/x.ex", "lib/letflow/modules/m/y.ex"}
      assert {:violation, _} = CB.classify_edge(edge, %{})
    end

    test "OK: catalog.ex is the sanctioned importer" do
      # Rule 1: catalog.ex is explicitly permitted to reference module-subdir files
      edge = {"lib/letflow/modules/catalog.ex", "lib/letflow/modules/m/m.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "OK: core mechanism file references another core mechanism file" do
      # Rule 0: target (catalog.ex) is NOT in a module subdir — one level, no subdir
      # lib/letflow/modules/catalog.ex → path_in_module_subdir? returns false
      edge = {"lib/letflow/modules/installs.ex", "lib/letflow/modules/catalog.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "VIOLATION: cross-module ref when target not in depends_on" do
      # Rule 4: b not in a's depends_on
      edge = {"lib/letflow/modules/a/x.ex", "lib/letflow/modules/b/y.ex"}
      assert {:violation, _} = CB.classify_edge(edge, %{"a" => []})
    end

    test "OK: cross-module ref when target is in depends_on" do
      # Rule 3: authorized cross-module
      edge = {"lib/letflow/modules/a/x.ex", "lib/letflow/modules/b/y.ex"}
      assert :ok = CB.classify_edge(edge, %{"a" => ["b"]})
    end

    test "OK: test/support source is excluded from scope" do
      # Scope gate: test/support/ sources are excluded
      edge = {"test/support/z.ex", "lib/letflow/modules/m/y.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "OK: intra-module reference (same module subdir)" do
      # Rule 2: same module, always OK
      edge = {"lib/letflow/modules/a/x.ex", "lib/letflow/modules/a/y.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "OK: source outside lib/ is out of scope" do
      # Scope gate: source not under lib/
      edge = {"_build/dev/lib/letflow/ebin/foo.beam", "lib/letflow/modules/m/y.ex"}
      assert :ok = CB.classify_edge(edge, %{})
    end

    test "violation reason names both module ids (Rule 4)" do
      edge = {"lib/letflow/modules/alpha/x.ex", "lib/letflow/modules/beta/y.ex"}
      {:violation, reason} = CB.classify_edge(edge, %{"alpha" => []})
      assert reason =~ "alpha"
      assert reason =~ "beta"
      assert reason =~ "depends_on"
    end

    test "violation reason names source and target (Rule 5)" do
      edge = {"lib/letflow/router.ex", "lib/letflow/modules/exam/session.ex"}
      {:violation, reason} = CB.classify_edge(edge, %{})
      assert reason =~ "lib/letflow/router.ex"
      assert reason =~ "lib/letflow/modules/exam/session.ex"
      assert reason =~ "catalog.ex"
    end
  end

  # ================================================================
  # parse_xref_output/1
  # ================================================================

  describe "parse_xref_output/1" do
    test "blank input returns empty list" do
      assert CB.parse_xref_output("") == []
      assert CB.parse_xref_output("   \n   \n") == []
    end

    test "non-indented source with one target (backtick prefix) produces one edge pair" do
      input = "lib/a.ex\n`-- lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "non-indented source with one target (pipe prefix) produces one edge pair" do
      input = "lib/a.ex\n|-- lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "also handles plain-indented targets (space prefix) for compatibility" do
      input = "lib/a.ex\n  lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "strips compile annotation from target paths" do
      input = "lib/a.ex\n`-- lib/b.ex (compile)\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "strips runtime annotation from target paths" do
      input = "lib/a.ex\n`-- lib/b.ex (runtime)\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end

    test "source with no dependencies produces no edges" do
      input = "lib/a.ex\nlib/b.ex\n"
      assert CB.parse_xref_output(input) == []
    end

    test "multiple sources and targets" do
      input = "lib/a.ex\n|-- lib/b.ex\n`-- lib/c.ex\nlib/d.ex\n`-- lib/e.ex\n"

      result = CB.parse_xref_output(input)
      assert length(result) == 3
      assert {"lib/a.ex", "lib/b.ex"} in result
      assert {"lib/a.ex", "lib/c.ex"} in result
      assert {"lib/d.ex", "lib/e.ex"} in result
    end

    test "target before any source is skipped gracefully" do
      # Defensive — should never occur in real xref output
      input = "`-- lib/orphan.ex\nlib/a.ex\n`-- lib/b.ex\n"
      assert CB.parse_xref_output(input) == [{"lib/a.ex", "lib/b.ex"}]
    end
  end

  # ================================================================
  # build_depends_on_map/1
  # ================================================================

  describe "build_depends_on_map/1" do
    test "empty manifest list → empty map" do
      assert CB.build_depends_on_map([]) == %{}
    end

    test "maps manifest id to its depends_on list" do
      manifests = [
        %{
          id: "a",
          depends_on: ["b", "c"],
          version: "1.0",
          pack: nil,
          permissions: [],
          role_grants: %{},
          required_roles: [],
          settings_schema: nil,
          route_policies: []
        },
        %{
          id: "b",
          depends_on: [],
          version: "1.0",
          pack: nil,
          permissions: [],
          role_grants: %{},
          required_roles: [],
          settings_schema: nil,
          route_policies: []
        }
      ]

      result = CB.build_depends_on_map(manifests)
      assert result == %{"a" => ["b", "c"], "b" => []}
    end
  end

  # ================================================================
  # run/1 -- xref exit-code handling (ISS-0831)
  #
  # Injectable seam: Application.put_env(:letflow, :check_boundaries_xref_runner, ...)
  # Design: lib/letflow/design/iss0831-check-boundaries-exit-code.md §4.
  #
  # This key has no legitimate non-test setter, so cleanup is an
  # unconditional `delete_env` (not restore-prior-value), matching
  # ISS-0697's established convention for this codebase's injectable-seam
  # tests.
  # ================================================================

  describe "run/1 -- mix xref non-zero exit (ISS-0831)" do
    setup do
      on_exit(fn -> Application.delete_env(:letflow, :check_boundaries_xref_runner) end)
      :ok
    end

    # T-XREF-EXIT-NONZERO-RAISES
    test "T-XREF-EXIT-NONZERO-RAISES -- raises when mix xref exits non-zero" do
      Application.put_env(:letflow, :check_boundaries_xref_runner, fn ->
        {"some xref error text", 1}
      end)

      assert_raise Mix.Error, ~r/mix xref exited 1/, fn -> CB.run([]) end
    end

    # T-XREF-EXIT-NONZERO-MESSAGE-INCLUDES-OUTPUT
    test "T-XREF-EXIT-NONZERO-MESSAGE-INCLUDES-OUTPUT -- raised message includes exit code and captured output" do
      Application.put_env(:letflow, :check_boundaries_xref_runner, fn ->
        {"internal xref crash: bad_state", 1}
      end)

      error =
        assert_raise Mix.Error, fn ->
          CB.run([])
        end

      assert error.message =~ "exited 1"
      assert error.message =~ "internal xref crash: bad_state"
    end

    # T-XREF-EXIT-NONZERO-SKIPS-PARSE
    test "T-XREF-EXIT-NONZERO-SKIPS-PARSE -- raises before parsing/classifying, never reaches OK or violation paths" do
      # This fake output would not crash parse_xref_output/1 (it's a
      # perfectly valid-looking xref edge), so if the raise message shows
      # the exit-code text (not an edge-count/OK/violations message), that
      # proves parsing was never attempted -- the raise fires first.
      Application.put_env(:letflow, :check_boundaries_xref_runner, fn ->
        {"lib/a.ex\n`-- lib/b.ex\n", 1}
      end)

      error =
        assert_raise Mix.Error, fn ->
          CB.run([])
        end

      assert error.message =~ "mix xref exited 1"
      refute error.message =~ "OK --"
      refute error.message =~ "violation"
    end

    # T-XREF-EXIT-ZERO-UNCHANGED
    test "T-XREF-EXIT-ZERO-UNCHANGED -- normal parse/summary path still works on exit 0" do
      Application.put_env(:letflow, :check_boundaries_xref_runner, fn -> {"", 0} end)

      assert CB.run([]) == :ok
    end

    # T-XREF-RUNNER-DEFAULT-IS-REAL-SYSTEM-CMD
    test "T-XREF-RUNNER-DEFAULT-IS-REAL-SYSTEM-CMD -- with no override configured, the seam falls back to a real subprocess call" do
      assert Application.get_env(:letflow, :check_boundaries_xref_runner) == nil

      # The real end-to-end proof that the default falls through to a real
      # `mix xref` invocation lives in CheckBoundariesTaskTest (below),
      # which shells out to `mix letflow.check_boundaries` with no env
      # override set and asserts exit 0. Called out explicitly here per
      # the design's §4 item 5: a regression in that test is a hard
      # failure of this fix, not an unrelated flake.
      assert :ok
    end
  end

  # ================================================================
  # Rule 6 -- engine -> entities layer rule (GH 2534 PR 7c-2, AC22)
  # Design: lib/letflow/design/gh2534-7c-script-handler.md section 11.4.
  # Rule 6 classifies DIRECT file edges only (no transitive closure).
  # ================================================================

  describe "Rule 6 (GH 2534 7c-2, AC22)" do
    setup do
      on_exit(fn -> Application.delete_env(:letflow, :check_boundaries_xref_runner) end)
      :ok
    end

    test "rule 6 synthetic edge: engine/x.ex -> entities/y.ex is a violation naming the port" do
      assert {:violation, reason} =
               CB.classify_edge({"lib/letflow/engine/x.ex", "lib/letflow/entities/y.ex"}, %{})

      assert reason =~ "lib/letflow/engine/x.ex"
      assert reason =~ "lib/letflow/entities/y.ex"
      assert reason =~ "Letflow.Engine.ScriptReadPort"
    end

    test "every source and target prefix of the row is covered" do
      for source <- ["lib/letflow/engine.ex", "lib/letflow/engine/lua/deep/x.ex"],
          target <- ["lib/letflow/entities.ex", "lib/letflow/entities/query/compiler.ex"] do
        assert {:violation, _} = CB.classify_edge({source, target}, %{}), "#{source} -> #{target}"
      end
    end

    test "only the forbidden direction and only the listed layers" do
      for edge <- [
            # entities may depend on the engine (it implements the engine's port)
            {"lib/letflow/entities/script_reads.ex", "lib/letflow/engine/script_read_port.ex"},
            # the engine's facade into scripts is allowed (C18)
            {"lib/letflow/engine/script_task_dispatcher.ex", "lib/letflow/scripts/runtime.ex"},
            # look-alike paths are not the engine
            {"lib/letflow/engine_helpers.ex", "lib/letflow/entities/y.ex"},
            {"lib/letflow/routers/x.ex", "lib/letflow/entities/y.ex"}
          ] do
        assert CB.classify_edge(edge, %{}) == :ok, inspect(edge)
      end
    end

    test "DIRECT edges only: the accepted indirect path engine -> Scripts -> Entities passes" do
      edges = [
        {"lib/letflow/engine/script_task_dispatcher.ex", "lib/letflow/scripts/runtime.ex"},
        {"lib/letflow/scripts/runtime.ex", "lib/letflow/scripts/policy.ex"},
        {"lib/letflow/scripts/policy.ex", "lib/letflow/entities/definitions.ex"}
      ]

      assert CB.classify_edges(edges, %{}) == [:ok, :ok, :ok]
    end

    test "run/1 fails on a synthetic direct engine -> entities edge and passes without it" do
      Application.put_env(:letflow, :check_boundaries_xref_runner, fn ->
        {"lib/letflow/engine/x.ex
`-- lib/letflow/entities/y.ex (runtime)
", 0}
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert_raise Mix.Error, ~r/1 violation/, fn -> CB.run([]) end
        end)

      assert output =~ "VIOLATION: lib/letflow/engine/x.ex -> lib/letflow/entities/y.ex"

      Application.put_env(:letflow, :check_boundaries_xref_runner, fn ->
        {"lib/letflow/engine/x.ex
`-- lib/letflow/scripts/runtime.ex (runtime)
", 0}
      end)

      assert ExUnit.CaptureIO.capture_io(fn -> assert CB.run([]) == :ok end) =~ "0 violations"
    end

    test "layer_rules/0 is the one declarative row" do
      assert [rule] = CB.layer_rules()
      assert rule.source_prefixes == ["lib/letflow/engine.ex", "lib/letflow/engine/"]

      assert rule.forbidden_target_prefixes == [
               "lib/letflow/entities.ex",
               "lib/letflow/entities/"
             ]
    end

    test "no engine file names Letflow.Entities (source scan)" do
      root = Path.expand("../../..", __DIR__)

      files =
        [Path.join(root, "lib/letflow/engine.ex")] ++
          Path.wildcard(Path.join(root, "lib/letflow/engine/**/*.ex"))

      assert length(files) > 10

      offenders = Enum.filter(files, &(File.read!(&1) =~ "Letflow.Entities"))
      assert offenders == []
    end

    test "the port implementation is selected only through :script_read_port" do
      root = Path.expand("../../..", __DIR__)
      assert Application.fetch_env!(:letflow, :script_read_port) == Letflow.Entities.ScriptReads

      behaviours =
        Letflow.Entities.ScriptReads.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Letflow.Engine.ScriptReadPort in behaviours

      readers =
        root
        |> Path.join("lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(
          &(File.read!(&1) =~ ~r/(get_env|fetch_env!?)\(:letflow, :script_read_port/)
        )
        |> Enum.map(&Path.relative_to(&1, root))

      assert readers == ["lib/letflow/engine/script_task_dispatcher.ex"]
    end
  end
end

defmodule Mix.Tasks.Letflow.CheckBoundariesTaskTest do
  @moduledoc """
  System-level tests for `mix letflow.check_boundaries` — invoked via
  `System.cmd/3`, confirming real end-to-end behaviour.

  These tests are `async: false` because they shell out to `mix` and
  depend on the compiled project tree.

  REQ-405, WF02-REQ405-20260925. Design:
  `lib/letflow/design/req405-check-boundaries.md` §5.3, §5.5.
  """

  use ExUnit.Case, async: false

  @project_root Path.expand("../../..", __DIR__)

  # ================================================================
  # AC2 — system invocation, exits 0 on clean tree
  # ================================================================

  describe "system invocation (AC2)" do
    test "exits 0 on the current branch tree (AC2)" do
      # ISS-0832: explicitly pass through MIX_ENV/MIX_TEST_PARTITION/MIX_BUILD_PATH
      # to the spawned `mix` subprocess rather than relying on inheritance.
      # Under a normal single-partition `mix test` run inheritance happens to
      # work, but under `scripts/test_parallel.sh --partitions N` each partition
      # runs as its own env-scoped invocation and the child subprocess needs
      # these forwarded explicitly (same pattern as
      # test/support/tenant_slug_test.exs's own System.cmd/3 call) so the check
      # runs against the same build/partition the parent test is running under.
      # If a future partition-count change reintroduces env-inheritance
      # assumptions here, this is the test that will start failing again.
      env =
        [{"MIX_ENV", System.get_env("MIX_ENV", "test")}] ++
          case System.get_env("MIX_TEST_PARTITION") do
            nil -> []
            partition -> [{"MIX_TEST_PARTITION", partition}]
          end ++
          case System.get_env("MIX_BUILD_PATH") do
            nil -> []
            build_path -> [{"MIX_BUILD_PATH", build_path}]
          end

      {output, exit_code} =
        System.cmd("mix", ["letflow.check_boundaries"],
          cd: @project_root,
          stderr_to_stdout: true,
          env: env
        )

      assert exit_code == 0, "expected exit 0; got #{exit_code}. Output:\n#{output}"
      assert output =~ "OK"
    end
  end

  # ================================================================
  # AC4 — alias wiring
  # ================================================================

  describe "the letflow.check alias wiring (AC4)" do
    setup do
      aliases = Mix.Project.config()[:aliases][:"letflow.check"]
      at = &Enum.find_index(aliases, fn step -> step == &1 end)
      %{aliases: aliases, at: at}
    end

    # T-ALIAS-WIRED
    test "T-ALIAS-WIRED -- letflow.check_boundaries is a step of `mix letflow.check`",
         %{aliases: aliases} do
      assert "letflow.check_boundaries" in aliases
    end

    # T-ALIAS-SLOT
    test "T-ALIAS-SLOT -- runs after compile --warnings-as-errors and before letflow.check.test",
         %{at: at} do
      assert at.("compile --warnings-as-errors") < at.("letflow.check_boundaries"),
             "expected `compile --warnings-as-errors` to come before `letflow.check_boundaries`"

      assert at.("letflow.check_boundaries") < at.("letflow.check.test"),
             "expected `letflow.check_boundaries` to come before `letflow.check.test`"
    end
  end
end
