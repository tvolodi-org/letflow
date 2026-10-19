defmodule Mix.Tasks.Letflow.LintHandoffsTest do
  @moduledoc """
  Regression coverage for ISS-0262 -- `mix letflow.lint_handoffs` discovers
  non-JSON handoff-shaped files (H6) (`lib/mix/tasks/letflow.lint_handoffs.ex`).

  Spec: `test/specs/ISS-0262.md`. Design:
  `lib/letflow/design/iss0262-lint-handoffs-non-json-discovery.md` section 6.
  Run: `WF03-ISS0262-20260822`, WF-03 Step 4.

  ## Why this is the ordinary fail-then-pass case, not the mutant clause

  `handoff_files/0` and `lint_file/2` both existed pre-fix -- this is a change
  to EXISTING functions (`handoff_files/0` becomes `handoff_files/1` with a
  default arg; `lint_file/2` gains a new first branch), not a wholly new
  module. WF-03's "code under test does not exist" clause (mutation required)
  therefore does NOT apply here; the ordinary checkout-pre-fix-commit,
  confirm-red, confirm-green procedure is the right one, per this run's Step-4
  dispatch. See this test-designer's handoff
  (`handoffs/WF03-ISS0262-20260822/step-04-test-designer.json`) `result.summary`
  for the actual quoted fail/pass output from a throwaway `git worktree`.

  ## Fixture

  `test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md` -- a permanent,
  committed, non-JSON, `step`-prefixed file living OUTSIDE `handoffs/`, so it
  is never discovered by production `mix letflow.lint_handoffs` (which only
  ever calls `handoff_files/1` with its default `handoffs/` argument) and
  never needs a `@grandfathered` entry of its own (design section 6.1).

  ## H6 rework (ISS-0262 Step 8 change-approach, rework_count 2)

  H6 no longer uses per-file `@grandfathered` entries at all -- it is now
  governed by the commit-boundary rule in
  `lib/letflow/design/iss0262-h6-floor-commit-addendum.md`
  (`pre_floor_file?/2`, `h6_floor_commit/0`). The tests below that used to
  assert "these exact 12 paths are grandfathered by list membership" are
  rewritten to assert the equivalent property against real git history
  instead: a file whose content predates a given floor commit is
  `hard_grandfathered`; a file introduced after it is `hard_new`. See design
  addendum §6 for the fixture guidance this section follows.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Letflow.LintHandoffs

  @fixture_dir "test/fixtures/lint_handoffs/h6"
  @fixture_file "test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md"

  # H4's schema is irrelevant to every assertion in this file: none of the
  # fixtures here carry a `not_agent_attested` key, so `check_h4_not_agent_attested/3`
  # short-circuits on its `nil`/absent clause before ever consulting this
  # value. A stub, not the real HANDOFF_PROTOCOL.md-derived schema, keeps
  # these tests independent of that file's prose.
  @empty_schema %{required: [], optional: [], spent_exception_file: nil}

  # These 10 real WF03-ISS0258-20260822 files are no longer list-grandfathered
  # (the 12 `{"H6", path}` `@grandfathered` entries were removed by the
  # ISS-0262 H6 floor-commit addendum) -- they are used here purely as real,
  # pre-existing fixtures to prove the commit-boundary rule reproduces the
  # same "grandfathered, not new" outcome the deleted list used to provide.
  # See design addendum §6 item 4.
  @grandfathered_md_files [
    "handoffs/WF03-ISS0258-20260822/step-01-issue-fixer.md",
    "handoffs/WF03-ISS0258-20260822/step-02-code-designer.md",
    "handoffs/WF03-ISS0258-20260822/step-02b-code-design-validator.md",
    "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev-MISSING-RETRACTED.md",
    "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev.md",
    "handoffs/WF03-ISS0258-20260822/step-03b-security-scope-test.md",
    "handoffs/WF03-ISS0258-20260822/step-03c-reviewer.md",
    "handoffs/WF03-ISS0258-20260822/step-04-test-designer.md",
    "handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md",
    "handoffs/WF03-ISS0258-20260822/step-04c-test-design-validator-regate.md"
  ]

  # ==================================================================
  # H6 -- discovery finds the new fixture (the regression itself)
  # ==================================================================

  describe "handoff_files/1 -- discovers non-JSON handoff-shaped files (H6)" do
    test "F-H6-DISCOVERED -- the .md fixture is found under an isolated fixture root" do
      files = LintHandoffs.handoff_files(@fixture_dir)

      assert @fixture_file in files,
             "expected #{@fixture_file} to be discovered under #{@fixture_dir}, got: #{inspect(files)}"
    end

    test "F-H6-KIND -- handoff_kind/1 classifies the fixture as :non_json" do
      assert LintHandoffs.handoff_kind(@fixture_file) == :non_json
    end

    test "F-H6-DEFAULT-EXCLUDES-FIXTURE -- the real (default) discovery never sees the fixture" do
      # Per design section 6.1: the fixture lives outside handoffs/ precisely
      # so production discovery -- handoff_files/1 called with its default arg,
      # exactly as run/1 calls it -- never touches it and it never needs its
      # own @grandfathered entry.
      refute @fixture_file in LintHandoffs.handoff_files()
    end
  end

  # ==================================================================
  # H6 -- lint_file/2 classifies the fixture as a NEW, gating violation
  # ==================================================================

  describe "lint_file/2 -- H6 fires on the non-JSON fixture (un-grandfathered)" do
    test "F-H6-FIRES-NEW -- an un-grandfathered non-JSON file is a hard_new H6 violation" do
      result = LintHandoffs.lint_file(@fixture_file, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "H6"
      assert violation.path == @fixture_file
      assert violation.grandfathered == false
      assert violation.message =~ ".md"
      assert violation.message =~ "expected .json"

      assert result.hard_grandfathered == []

      assert result.advisory == %{
               path: @fixture_file,
               warnings: [],
               size_info: %{desc_len: 0, summary_len: 0}
             }

      assert result.parse_error == nil
    end

    test "F-H6-CONTENT-NEVER-READ -- classification is extension-only, not content-based" do
      # The fixture's prose is not JSON at all -- if lint_file/2 ever tried to
      # Jason.decode it, this would blow up with a decode error instead of
      # cleanly producing an H6 violation. Asserting rule: "H6" (not "PARSE")
      # is the discriminator between the two outcomes design section 4.2
      # states must never be merged.
      result = LintHandoffs.lint_file(@fixture_file, @empty_schema)
      assert [%{rule: "H6"}] = result.hard_new
    end
  end

  # ==================================================================
  # Existing .json handoff behavior (H1-H5) is unaffected by this fix
  # ==================================================================

  describe "existing .json handoff behavior (H1-H5) is unaffected" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "letflow-lint-handoffs-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "F-JSON-KIND -- handoff_kind/1 classifies a .json path as :json" do
      assert LintHandoffs.handoff_kind("handoffs/some-run/step-01-agent.json") == :json
    end

    test "F-JSON-CLEAN-PASSES -- a well-formed .json handoff produces zero hard violations",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")

      File.write!(path, ~s({
        "status": "COMPLETED",
        "started_at": "2026-08-22T07:00:00Z",
        "completed_at": "2026-08-22T07:05:00Z",
        "context": {},
        "task": {},
        "result": {}
      }))

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert result.hard_new == []
      assert result.hard_grandfathered == []
      assert result.parse_error == nil
    end

    test "F-JSON-H1-STILL-FIRES -- an illegal status on a .json file still gates (unchanged)",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, ~s({"status": "BOGUS"}))

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "H1"
    end

    test "F-JSON-PARSE-STILL-FIRES -- broken JSON still reports PARSE, never H6",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, "{not valid json")

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "PARSE"
    end

    test "F-PARSE-ADVISORY-SHAPE (ISS-0347 regression) -- parse-error advisory is the same map shape every other branch uses, so print_advisory/1's dot-access never raises BadMapError",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, "{not valid json")

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert result.parse_error != nil
      assert [violation] = result.hard_new
      assert violation.rule == "PARSE"

      # This reproduces exactly the access pattern print_advisory/1 performs
      # on every result (`r.advisory.warnings`, then
      # `size_info.desc_len`/`summary_len` when building the H-SIZE-3 report).
      # Pre-fix, lint_file/2's {:error, reason} branch set `advisory: []` --
      # a bare list -- so this same dot-access raised `%BadMapError{term: []}`
      # and crashed the whole `mix letflow.lint_handoffs` run on the first
      # handoff-shaped file with invalid JSON. Post-fix it is the same
      # %{path:, warnings:, size_info:} map every other branch produces.
      # Fail-then-pass evidence: test/specs/ISS-0347.md.
      assert result.advisory.warnings == []
      assert result.advisory.size_info.desc_len == 0
      assert result.advisory.size_info.summary_len == 0
    end

    test "F-BOM-PARSE-ADVISORY-SHAPE (ISS-0347 regression) -- a leading UTF-8 BOM also hits the parse-error branch without crashing",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      # ﻿ (UTF-8 BOM) prepended to otherwise-valid JSON -- Jason.decode/1
      # rejects the BOM byte sequence, landing lint_file/2 in the same
      # {:error, reason} branch as plain invalid JSON.
      File.write!(path, "﻿" <> ~s({"status": "COMPLETED"}))

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert result.parse_error != nil
      assert [violation] = result.hard_new
      assert violation.rule == "PARSE"

      assert result.advisory.warnings == []
      assert result.advisory.size_info.desc_len == 0
      assert result.advisory.size_info.summary_len == 0
    end

    test "F-JSON-REAL-GRANDFATHERED-UNCHANGED -- a real pre-existing grandfathered .json entry still classifies as grandfathered, not new" do
      # handoffs/WF02-REQ023-20260816/step-06-doc-updater.json is one of the 6
      # pre-ISS-0190 H3 entries already in @grandfathered, untouched by this
      # fix per design section 5's backward-compatibility table.
      path = "handoffs/WF02-REQ023-20260816/step-06-doc-updater.json"
      result = LintHandoffs.lint_file(path, @empty_schema)

      assert Enum.any?(result.hard_grandfathered, &(&1.rule == "H3"))
      refute Enum.any?(result.hard_new, &(&1.rule == "H3"))
    end

    test "F-DEFAULT-DISCOVERY-STILL-FINDS-REAL-JSON -- the real handoffs/ corpus is still discovered" do
      # Both pre-fix naming styles (design section 0.1/1.1) must still be
      # found by the broadened glob -- this is the exact regression risk the
      # design flags: a naive `step-*.*` pattern would have dropped the
      # non-hyphenated style.
      files = LintHandoffs.handoff_files()

      assert "handoffs/WF02-REQ019-20260816/step00-git-setup.json" in files
      assert "handoffs/WF02-REQ023-20260816/step-06-doc-updater.json" in files
    end
  end

  # ==================================================================
  # The 10 real WF03-ISS0258-20260822 .md files -- now grandfathered by the
  # commit-boundary rule instead of a per-file list (ISS-0262 H6 floor-commit
  # addendum). `lint_file/2` is called exactly as production calls it (no
  # explicit `floor` argument), so this exercises the real
  # `h6_floor_commit/0` -> `pre_floor_file?/2` production path end to end.
  # ==================================================================

  describe "the 10 real WF03-ISS0258-20260822 .md files -- grandfathered by commit boundary" do
    test "F-GRANDFATHERED-COUNT -- exactly 10 real .md files exist at these exact paths" do
      assert length(@grandfathered_md_files) == 10
      assert Enum.all?(@grandfathered_md_files, &File.regular?/1)
    end

    test "F-GRANDFATHERED-DISCOVERED -- default discovery finds all 10" do
      files = LintHandoffs.handoff_files()

      for path <- @grandfathered_md_files do
        assert path in files, "expected #{path} to be discovered by handoff_files/1"
      end
    end

    test "F-GRANDFATHERED-NOT-NEW -- each classifies as hard_grandfathered H6, never hard_new" do
      for path <- @grandfathered_md_files do
        result = LintHandoffs.lint_file(path, @empty_schema)

        assert [violation] = result.hard_grandfathered,
               "#{path}: expected exactly one grandfathered violation, got #{inspect(result.hard_grandfathered)}"

        assert violation.rule == "H6"
        assert violation.grandfathered == true

        assert result.hard_new == [],
               "#{path}: a grandfathered H6 file must never contribute to hard_new (it must not fail the build)"
      end
    end
  end

  # ==================================================================
  # pre_floor_file?/2 and h6_floor_commit/0 -- the commit-boundary mechanism
  # itself (ISS-0262 H6 floor-commit addendum §6), tested directly against
  # real, already-resolvable commits in this repository's own history.
  # ==================================================================

  describe "pre_floor_file?/2 -- commit-boundary ancestry, real repo history" do
    test "T-PRE-FLOOR-TRUE -- a long-stable file predates a recent floor (HEAD)" do
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      floor = String.trim(head)

      assert LintHandoffs.pre_floor_file?("mix.exs", floor) == true
    end

    test "T-PRE-FLOOR-FALSE -- a file added on this branch postdates the repo's root commit" do
      {root, 0} = System.cmd("git", ["rev-list", "--max-parents=0", "HEAD"])
      old_floor = root |> String.trim() |> String.split("\n", trim: true) |> List.first()

      refute LintHandoffs.pre_floor_file?(@fixture_file, old_floor)
    end

    test "T-PRE-FLOOR-NIL-FLOOR-FAILS-SAFE -- a nil floor (git resolution failure) returns false" do
      refute LintHandoffs.pre_floor_file?("mix.exs", nil)
    end

    test "T-PRE-FLOOR-UNTRACKED-PATH-FALSE -- a path with no git history at all is not pre-floor" do
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      floor = String.trim(head)

      refute LintHandoffs.pre_floor_file?(
               "test/fixtures/lint_handoffs/h6/does-not-exist-#{System.unique_integer([:positive])}.md",
               floor
             )
    end

    test "T-NEW-AFTER-FLOOR-HARD-FAILS -- fixture postdating an old floor still hard-fails via lint_file/2" do
      # Design addendum §2.4/§6 item 3: proves the "added after floor always
      # hard-fails" acceptance criterion using lint_file/2's real production
      # call path (which uses the real h6_floor_commit/0, not an explicit
      # floor param) against a fixture that genuinely postdates any
      # reasonable floor.
      result = LintHandoffs.lint_file(@fixture_file, @empty_schema)

      assert [violation] = result.hard_new
      assert violation.rule == "H6"
      assert violation.grandfathered == false
      assert result.hard_grandfathered == []
    end
  end

  # ==================================================================
  # run/1 -- H6 specifically stays green on the real corpus post-fix
  # ==================================================================
  #
  # NOTE (ISS-0262 H6 floor-commit addendum, rework_count 2): the original
  # design's T-TASK-GREEN asserted the whole task (`run/1`) exits `:ok`.
  # That assertion no longer holds independent of this fix: another,
  # already-merged run (WF03-ISS0260-20260822) has since landed a real H1 and
  # a real H3 violation on `main`
  # (`handoffs/WF03-ISS0260-20260822/step-04d-test-design-validator-recheck.json`)
  # that are unrelated to H6 and explicitly out of this fix's scope per
  # design addendum §3.1's last paragraph ("not in this fix's scope to
  # grandfather ... route to ISSUE-FIXER ... separately from this H6
  # rework"). Asserting full `run/1` greenness here would make this suite
  # flaky against `main`'s H1/H3 state exactly the way the deleted H6
  # per-file list was flaky against `main`'s H6 state -- the failure mode
  # this whole rework exists to eliminate, just for a different rule. This
  # test is therefore scoped to what this fix actually owns: zero *new* H6
  # violations anywhere in the real `handoffs/` tree.

  describe "H6 -- zero new violations on the real corpus post-fix" do
    test "T-H6-ZERO-NEW -- every non-JSON file in the real handoffs/ tree is grandfathered-or-absent, never new" do
      files = LintHandoffs.handoff_files()
      schema = %{required: [], optional: [], spent_exception_file: nil}

      results = Enum.map(files, &LintHandoffs.lint_file(&1, schema))
      new_h6 = results |> Enum.flat_map(& &1.hard_new) |> Enum.filter(&(&1.rule == "H6"))

      assert new_h6 == [],
             "expected zero new H6 violations against the real handoffs/ tree, got: #{inspect(new_h6)}"
    end
  end

  # ==================================================================
  # ISS-0440 -- --dir and restricted --autofix (regression, WF03-ISS0440-20260903)
  #
  # Spec: test/specs/ISS-0440.md. Design:
  # lib/letflow/design/iss440-handoff-status-enforcement.md sections 2, 2.1a.
  # Run: WF03-ISS0440-20260903, WF-03 Step 4.
  #
  # `resolve_dir/1`, `find_dir_flag/1`, `guard_empty_scope/2`, `run_autofix/1`,
  # `autofix_file/1`, and `write_json!/2` are ALL NEW functions this fix adds
  # -- there is no pre-fix version of any of them to check out and prove red
  # against ("UndefinedFunctionError" would be trivially true of every test
  # here and prove nothing about whether the tests discriminate correct from
  # wrong). Per WF-03's "When the pre-fix failure is 'the code under test does
  # not exist'" clause, fail-first is satisfied here instead by MUTATING the
  # shipped logic and recording which named tests below fail for each mutant
  # -- see this test-designer's handoff result.summary for the full mutant
  # table (M1/M2/M3), each applied in a throwaway git worktree, none left in
  # this tree.
  #
  # Every fixture here lives under System.tmp_dir!/0 in a unique subdirectory,
  # cleaned up via on_exit -- never inside handoffs/, and --autofix is never
  # run against the real handoffs/ corpus by any test in this file.
  # ==================================================================

  describe "ISS-0440 -- resolve_dir/1 and find_dir_flag (CLI flag parsing)" do
    test "F-DIR-DEFAULT -- resolve_dir/1 with no --dir returns @handoffs_dir unchanged" do
      # This is the property CI's own no-flag invocation depends on: run([])
      # must resolve identically to today's hardcoded default.
      assert LintHandoffs.resolve_dir([]) == "handoffs"
    end

    test "F-DIR-EXPLICIT -- resolve_dir/1 with --dir <path> returns that path verbatim" do
      assert LintHandoffs.resolve_dir(["--dir", "some/fixture/dir"]) == "some/fixture/dir"
    end

    test "F-DIR-ORDER-INDEPENDENT -- --dir is found regardless of position among other args" do
      assert LintHandoffs.resolve_dir(["--autofix", "--dir", "x/y"]) == "x/y"
      assert LintHandoffs.resolve_dir(["--dir", "x/y", "--autofix"]) == "x/y"
    end

    test "F-DIR-MISSING-VALUE -- --dir with no following value Mix.raise-s" do
      assert_raise Mix.Error, ~r/--dir given with no path argument/, fn ->
        LintHandoffs.resolve_dir(["--dir"])
      end
    end
  end

  # ==================================================================
  # ISS-0443 -- unrecognized flags now raise instead of being silently
  # discarded (regression, WF03-ISS0443-20260907)
  #
  # Spec: test/specs/ISS-0443.md. Design:
  # lib/letflow/design/iss0443-lint-handoffs-strict-flag-parsing.md.
  # Run: WF03-ISS0443-20260907, WF-03 Step 4.
  #
  # `resolve_dir/1`'s hand-walked `find_dir_flag/1` catch-all silently
  # dropped any token it didn't recognize -- an EXISTING function whose
  # unknown-flag behavior changed, not a from-scratch module. Per WF-03's
  # ordinary rule (not the "code under test does not exist" clause),
  # fail-first evidence is the pre-fix commit (c357f97a~1) checked out in a
  # disposable worktree, not a mutant. See this test-designer's handoff
  # result.summary for the quoted FAIL (at c357f97a~1) and PASS (this
  # branch, at/after c357f97a) output.
  # ==================================================================

  describe "ISS-0443 -- resolve_dir/1 rejects an unrecognized flag (unit level)" do
    test "F-UNKNOWN-FLAG-RAISES -- an unrecognized flag names itself and raises Mix.Error" do
      assert_raise Mix.Error, ~r/unrecognized flag "--bogus-flag-xyz"/, fn ->
        LintHandoffs.resolve_dir(["--bogus-flag-xyz"])
      end
    end

    test "F-UNKNOWN-FLAG-AUTOFX-TYPO -- the issue's own motivating typo, --autofx, is rejected" do
      assert_raise Mix.Error, ~r/unrecognized flag "--autofx"/, fn ->
        LintHandoffs.resolve_dir(["--autofx"])
      end
    end

    test "F-UNKNOWN-FLAG-DR-TYPO -- the issue's own motivating typo, --dr, is rejected" do
      assert_raise Mix.Error, ~r/unrecognized flag "--dr"/, fn ->
        LintHandoffs.resolve_dir(["--dr", "x"])
      end
    end

    test "F-AUTOFIX-INVALID-VALUE -- --autofix=notabool (malformed value for a recognized flag) raises" do
      assert_raise Mix.Error, ~r/invalid value "notabool" for flag "--autofix"/, fn ->
        LintHandoffs.resolve_dir(["--autofix=notabool"])
      end
    end

    test "F-BARE-POSITIONAL-REJECTED -- a bare positional argument (no leading --) raises" do
      assert_raise Mix.Error, ~r/unexpected argument\(s\) \["foo"\]/, fn ->
        LintHandoffs.resolve_dir(["foo"])
      end
    end
  end

  describe "ISS-0443 -- run/1 end-to-end: an unrecognized flag never produces a confident OK" do
    test "T-UNKNOWN-FLAG-RUN-RAISES -- run/1 with an unrecognized flag raises" do
      assert_raise Mix.Error, ~r/unrecognized flag "--bogus-flag-xyz"/, fn ->
        capture_io(fn -> LintHandoffs.run(["--bogus-flag-xyz"]) end)
      end
    end

    test "T-UNKNOWN-FLAG-RUN-NO-OK-BANNER -- confirms no OK/healthy banner is ever printed for a rejected flag" do
      io =
        capture_io(fn ->
          try do
            LintHandoffs.run(["--bogus-flag-xyz"])
          rescue
            Mix.Error -> :ok
          end
        end)

      refute io =~ "OK --"
      refute io =~ "new violations"
    end

    test "T-AUTOFIX-INVALID-VALUE-RUN-RAISES -- run/1 with --autofix=notabool raises, never runs the linter" do
      assert_raise Mix.Error, ~r/invalid value "notabool" for flag "--autofix"/, fn ->
        capture_io(fn -> LintHandoffs.run(["--autofix=notabool"]) end)
      end
    end

    test "T-BARE-POSITIONAL-RUN-RAISES -- run/1 with a bare positional argument raises" do
      assert_raise Mix.Error, ~r/unexpected argument\(s\) \["foo"\]/, fn ->
        capture_io(fn -> LintHandoffs.run(["foo"]) end)
      end
    end
  end

  describe "ISS-0440 -- guard_empty_scope/2 (empty --dir scope is a hard usage error)" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0440-empty-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "F-EMPTY-DIR-RAISES -- an explicitly-supplied --dir with zero handoff files Mix.raise-s",
         %{dir: dir} do
      files = LintHandoffs.handoff_files(dir)
      assert files == []

      assert_raise Mix.Error, ~r/discovered 0 files -- refusing to report success/, fn ->
        LintHandoffs.guard_empty_scope(dir, files)
      end
    end

    test "F-NONEXISTENT-DIR-RAISES -- a --dir pointing at a path that doesn't exist also raises, " <>
           "naming the actual failure mode (ISS-0819)" do
      missing_dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0440-missing-#{System.unique_integer([:positive])}")
        |> Path.expand()

      refute File.exists?(missing_dir)
      files = LintHandoffs.handoff_files(missing_dir)
      assert files == []

      # ISS-0819 -- guard_empty_scope/2's reason-phrase precedence puts "does
      # not exist" ahead of the generic "discovered 0 files" wording for any
      # scan target (file or directory) that isn't on disk at all.
      assert_raise Mix.Error, ~r/does not exist/, fn ->
        LintHandoffs.guard_empty_scope(missing_dir, files)
      end
    end

    test "F-DEFAULT-EMPTY-DOES-NOT-RAISE -- the DEFAULT @handoffs_dir carve-out is not the --dir misuse case" do
      # guard_empty_scope/2's carve-out: files == [] is only a hard error when
      # dir != @handoffs_dir (i.e. --dir was explicitly given). A real empty
      # handoffs/ is a separate, pre-existing edge case, out of scope here --
      # this test proves the guard does not fire for the default dir even
      # with an (impossible-in-practice, but exercised directly) empty list.
      assert LintHandoffs.guard_empty_scope("handoffs", []) == :ok
    end

    test "F-NONEMPTY-DIR-OK -- a --dir scope with at least one file does not raise", %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, ~s({"status": "COMPLETED"}))

      files = LintHandoffs.handoff_files(dir)
      assert files != []
      assert LintHandoffs.guard_empty_scope(dir, files) == :ok
    end
  end

  describe "ISS-0440 -- run/1 end-to-end via --dir, isolated tmp fixtures" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0440-run-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp write_handoff!(path, status, extra \\ %{}) do
      body =
        Map.merge(
          %{
            "status" => status,
            "context" => %{},
            "task" => %{},
            "result" => %{}
          },
          extra
        )

      File.write!(path, Jason.encode!(body, pretty: true) <> "\n")
    end

    test "T-DIR-SCOPED-SCAN -- --dir <fixture> scans ONLY the fixture, and the banner names it",
         %{dir: dir} do
      write_handoff!(Path.join(dir, "step-01-agent.json"), "COMPLETED")

      io =
        capture_io(fn ->
          assert LintHandoffs.run(["--dir", dir]) == :ok
        end)

      assert io =~ inspect(dir)
      assert io =~ "across 1 handoff files"
      refute io =~ "handoffs/WF"
    end

    test "T-DIR-MISSING-VALUE-RAISES -- `mix letflow.lint_handoffs --dir` with no value Mix.raise-s" do
      assert_raise Mix.Error, ~r/--dir given with no path argument/, fn ->
        capture_io(fn -> LintHandoffs.run(["--dir"]) end)
      end
    end

    test "T-DIR-EMPTY-SCOPE-RAISES -- --dir at a directory with zero handoff files Mix.raise-s, not a clean OK",
         %{dir: dir} do
      empty_subdir = Path.join(dir, "empty")
      File.mkdir_p!(empty_subdir)

      assert_raise Mix.Error, ~r/discovered 0 files -- refusing to report success/, fn ->
        capture_io(fn -> LintHandoffs.run(["--dir", empty_subdir]) end)
      end
    end

    test "T-AUTOFIX-PASS -- --autofix rewrites top-level status PASS -> COMPLETED", %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      write_handoff!(path, "PASS")

      io =
        capture_io(fn ->
          assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok
        end)

      assert io =~ "AUTOFIX -- FIXED"
      assert io =~ ~s("PASS" -> "COMPLETED")

      rewritten = path |> File.read!() |> Jason.decode!()
      assert rewritten["status"] == "COMPLETED"
    end

    test "T-AUTOFIX-COMPLETE -- --autofix rewrites top-level status COMPLETE -> COMPLETED",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      write_handoff!(path, "COMPLETE")

      capture_io(fn -> assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok end)

      assert (path |> File.read!() |> Jason.decode!())["status"] == "COMPLETED"
    end

    test "T-AUTOFIX-DONE -- --autofix rewrites top-level status DONE -> COMPLETED", %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      write_handoff!(path, "DONE")

      capture_io(fn -> assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok end)

      assert (path |> File.read!() |> Jason.decode!())["status"] == "COMPLETED"
    end

    test "T-AUTOFIX-REFUSES-FAIL -- --autofix REFUSES FAIL: file is BYTE-IDENTICAL, refusal printed",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      write_handoff!(path, "FAIL")

      before = File.read!(path)

      io =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found 1 new violation/, fn ->
            LintHandoffs.run(["--dir", dir, "--autofix"])
          end
        end)

      after_content = File.read!(path)

      # Byte-identity, not merely "status is still FAIL" -- read the file
      # before and after and compare the raw bytes directly.
      assert after_content == before,
             "expected the refused file to be BYTE-IDENTICAL, but it changed"

      assert io =~ "AUTOFIX -- REFUSED"
      assert io =~ ~s(found "FAIL")
      assert io =~ "ambiguous between a lifecycle FAILED handoff"
    end

    test "T-AUTOFIX-REFUSES-OUTSIDE-MAP -- an arbitrary string outside the closed map is untouched and refused",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      write_handoff!(path, "BOGUS_VALUE")

      before = File.read!(path)

      io =
        capture_io(fn ->
          assert_raise Mix.Error, fn -> LintHandoffs.run(["--dir", dir, "--autofix"]) end
        end)

      assert File.read!(path) == before
      assert io =~ "AUTOFIX -- REFUSED"
      assert io =~ ~s(found "BOGUS_VALUE")
    end

    test "T-AUTOFIX-REFUSES-LEGAL-BUT-WRONG-ENUM -- a legal enum member outside the autofix map is untouched and refused",
         %{dir: dir} do
      # "PENDING" is a legal top-level status (per @legal_statuses) but is not
      # a key in the closed autofix map -- it must not be silently rewritten,
      # and must not be silently accepted either (it is not itself an H1
      # violation, so --autofix has nothing to "fix"; verify it is left
      # alone and the run still succeeds since PENDING is not a hard
      # violation on its own).
      path = Path.join(dir, "step-01-agent.json")
      write_handoff!(path, "PENDING")

      before = File.read!(path)

      io =
        capture_io(fn ->
          assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok
        end)

      assert File.read!(path) == before
      refute io =~ "AUTOFIX -- FIXED"
      refute io =~ "AUTOFIX -- REFUSED"
    end

    test "T-AUTOFIX-DOES-NOT-TOUCH-NESTED-RESULT-STATUS -- top-level COMPLETED with nested result.status PASS is untouched",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")

      write_handoff!(path, "COMPLETED", %{
        "result" => %{"status" => "PASS", "summary" => "looks good"}
      })

      before = File.read!(path)

      capture_io(fn ->
        assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok
      end)

      assert File.read!(path) == before,
             "expected a byte-identical file: --autofix must never touch nested result.status"
    end

    test "T-AUTOFIX-EVERY-FIX-AND-REFUSAL-ON-STDOUT -- both a fix and a refusal are reported on stdout",
         %{dir: dir} do
      write_handoff!(Path.join(dir, "step-01-fixable.json"), "PASS")
      write_handoff!(Path.join(dir, "step-02-refused.json"), "FAIL")

      io =
        capture_io(fn ->
          assert_raise Mix.Error, fn -> LintHandoffs.run(["--dir", dir, "--autofix"]) end
        end)

      assert io =~ "AUTOFIX -- FIXED"
      assert io =~ "step-01-fixable.json"
      assert io =~ "AUTOFIX -- REFUSED"
      assert io =~ "step-02-refused.json"
    end

    test "T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS -- default no-flag invocation still resolves to @handoffs_dir" do
      # ISS-0523: this used to invoke `LintHandoffs.run([])` against the REAL
      # handoffs/ directory and assert :ok, transitively claiming the whole
      # repository's handoff corpus is clean -- see ISS-0445 for the incident
      # this caused (a sibling session's handoff turned this test red on an
      # unrelated branch). The property this test actually owns is narrower:
      # that run/1's zero-flag path still resolves to @handoffs_dir after the
      # --dir branch was added (ISS-0440). That is exactly what resolve_dir/1's
      # own unit test, F-DIR-DEFAULT (line ~419), already asserts -- so this
      # test now asserts the same thing directly, without a corpus scan. The
      # banner-threads-resolve_dir's-output claim is covered end-to-end,
      # corpus-scan-free, by T-DIR-SCOPED-SCAN (line ~521) via a tmp fixture.
      assert LintHandoffs.resolve_dir([]) == "handoffs"
    end
  end

  # ==================================================================
  # ISS-0819 -- --dir accepts a single regular file (single-file mode)
  # (regression, WF03-ISS0819-20260924, GH-1809)
  #
  # Spec: test/specs/ISS-0819.md.
  # Test under: `lib/mix/tasks/letflow.lint_handoffs.ex` -- `handoff_files/1`
  # (existing function, gains a `File.regular?` branch ahead of its existing
  # `File.dir?` branch), `guard_empty_scope/2` (existing function, its raised
  # message now delegates to the new `empty_scope_reason/1` instead of one
  # hardcoded phrase), `check_registry_coverage/2` (existing PRIVATE
  # function, gains a `File.regular?` short-circuit ahead of its existing
  # corpus-scan body -- see the note on its coverage below), and `run/1`'s OK
  # banner (existing `mode_phrase` construction). All FOUR are changes to
  # EXISTING functions, not a wholly new module -- so per WF-03's ordinary
  # rule (not the "code under test does not exist" clause), fail-first
  # evidence is the pre-fix commit itself (`27644677`, the parent of this
  # fix's first implementation commit `01c33f17`), checked out in a
  # disposable `git worktree`, not a mutant. See this test-designer's
  # handoff `result.summary` for the quoted FAIL (at `27644677`) and PASS
  # (this branch) output.
  #
  # `check_registry_coverage/2` is `defp` (private) -- unlike every other
  # function this suite calls directly (`handoff_files/1`, `lint_file/2`,
  # `guard_empty_scope/2`, `run_autofix/1`, etc., which are all public
  # `def`s), it has no public entry point to call directly, matching this
  # file's existing convention of only unit-testing public functions.
  # Its single-file short-circuit is instead proved at the `run/1` level by
  # two complementary tests below: T-FILE-OK shows the returned pair is
  # forced-empty (`[]`/`[]`) even though the real `handoffs/registry.json`
  # has 334 `runs[]` entries -- if `do_check_registry_coverage/2` had
  # actually run against a lone tmp fixture, `missing_on_disk` could not
  # possibly be empty -- while T-DIR-MODE-H5-RUNS-AND-READS-REGISTRY shows
  # the SAME registry file genuinely consulted (and a real mismatch
  # reported) the moment the scan target is a directory instead of a file.
  # Together they discriminate the short-circuit exactly as directly as a
  # unit test on the private function would.
  # ==================================================================

  describe "ISS-0819 -- handoff_files/1 and guard_empty_scope/2 for a single-file scan target" do
    test "F-FILE-DISCOVERED -- handoff_files/1 given a real regular file returns exactly that file, unfiltered" do
      # handoffs/registry.json is a real, permanent, non-"step*"-named file
      # that a DIRECTORY scan would normally exclude via registry_file/1's
      # own rejection. Naming it directly must still return it -- proving
      # single-file mode is genuinely unfiltered against both the step*.*
      # glob and the registry.json exclusion (design's "open design point").
      path = "handoffs/registry.json"
      assert LintHandoffs.handoff_files(path) == [path]
    end

    test "F-FILE-MISSING-RAISES-DOES-NOT-EXIST -- a nonexistent single-file-shaped path raises 'does not exist' (ISS-0819)" do
      missing_file =
        System.tmp_dir!()
        |> Path.join("letflow-iss0819-missing-#{System.unique_integer([:positive])}.json")
        |> Path.expand()

      refute File.exists?(missing_file)
      files = LintHandoffs.handoff_files(missing_file)
      assert files == []

      # Same precedence rule F-NONEXISTENT-DIR-RAISES already proves for a
      # nonexistent DIRECTORY-shaped path (empty_scope_reason/1's
      # `File.exists?` check fires ahead of both the file/directory-kind
      # check and the generic "discovered 0 files" fallback) -- this test
      # proves the same precedence for a nonexistent FILE-shaped path,
      # confirming the rule applies uniformly regardless of the target's
      # (nonexistent) shape.
      assert_raise Mix.Error, ~r/does not exist/, fn ->
        LintHandoffs.guard_empty_scope(missing_file, files)
      end
    end
  end

  describe "ISS-0819 -- run/1 single-file mode, isolated tmp fixture" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0819-run-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "T-FILE-OK -- a valid single handoff file: OK banner names single-file mode, H5 shows the skip-note, registry pair is forced-empty",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")

      File.write!(path, ~s({
        "status": "COMPLETED",
        "started_at": "2026-09-24T07:00:00Z",
        "completed_at": "2026-09-24T07:05:00Z",
        "context": {},
        "task": {},
        "result": {}
      }))

      io =
        capture_io(fn ->
          assert LintHandoffs.run(["--dir", path]) == :ok
        end)

      # OK banner names single-file mode explicitly -- "the single handoff
      # file", never "N handoff files" -- the exact wording run/1's
      # mode_phrase produces only when File.regular?(dir) is true, so a
      # single-file run's output is never confused with a --dir <directory>
      # run that happened to contain exactly one file.
      assert io =~ "OK -- 0 new violations across the single handoff file"
      refute io =~ "1 handoff files"
      assert io =~ inspect(path)

      # H5 explicitly names itself skipped, rather than silently reporting
      # an empty-but-genuinely-scanned corpus.
      assert io =~ "skipped: H5 is a corpus-level check, not applicable to a single-file scan"

      # See the describe-block header comment above for why an empty pair
      # here is positive evidence registry.json was never read, not just
      # that this fixture happens to match the real corpus.
      assert io =~ "run_id on disk but missing from registry.json: []"
      assert io =~ "run_id in registry.json but missing on disk: []"
    end

    test "T-FILE-MISSING-RUN-RAISES-DOES-NOT-EXIST -- run/1 with a nonexistent single-file-shaped --dir raises 'does not exist', not a clean OK" do
      missing_file =
        System.tmp_dir!()
        |> Path.join("letflow-iss0819-run-missing-#{System.unique_integer([:positive])}.json")
        |> Path.expand()

      refute File.exists?(missing_file)

      io =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/does not exist/, fn ->
            LintHandoffs.run(["--dir", missing_file])
          end
        end)

      refute io =~ "OK --"
    end

    test "T-FILE-VIOLATIONS-LINTED-DIRECTLY -- a single-file target with real hard violations is linted, not silently filtered to an empty scope" do
      # handoffs/registry.json is a real file that is NOT step*-shaped and
      # would normally be excluded by a DIRECTORY scan's own
      # registry_file/1 rejection. Naming it directly as --dir's target
      # must not be silently filtered to an empty scope (which
      # guard_empty_scope/2 would otherwise reject with a DIFFERENT
      # message, "discovered 0 files" or "does not exist") -- it must be
      # linted as the named target and its real top-level-schema violations
      # reported: no top-level "status" key (H1), and its two top-level
      # keys ("_comment", "runs") are not in @schema_top_keys (H3).
      path = "handoffs/registry.json"

      io =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/found \d+ new violation/, fn ->
            LintHandoffs.run(["--dir", path])
          end
        end)

      assert io =~ "NEW HARD VIOLATIONS"
      assert io =~ "[H1] #{path}"
      assert io =~ "[H3] #{path}"
      refute io =~ "does not exist"
      refute io =~ "discovered 0 files"
    end
  end

  describe "ISS-0819 -- directory mode is unchanged: H5 still runs fully, registry.json IS read" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0819-dirmode-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "T-DIR-MODE-H5-RUNS-AND-READS-REGISTRY -- a directory scan's H5 section is never the single-file skip-note, and it names a real registry mismatch",
         %{dir: dir} do
      # A flat file directly inside `dir` (no run_id subdirectory) makes
      # do_check_registry_coverage/2 derive its own basename as the
      # "run_id" (Path.relative_to(dir) |> Path.split() |> hd()) -- a value
      # guaranteed absent from the real handoffs/registry.json's 334
      # runs[] entries. Its appearance in "missing from registry.json" is
      # therefore direct, positive evidence the real registry.json WAS read
      # in directory mode -- contrast with T-FILE-OK's forced-empty pair.
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, ~s({"status": "COMPLETED", "context": {}, "task": {}, "result": {}}))

      io =
        capture_io(fn ->
          assert LintHandoffs.run(["--dir", dir]) == :ok
        end)

      assert io =~ "across 1 handoff files"
      refute io =~ "the single handoff file"
      refute io =~ "skipped: H5 is a corpus-level check"

      assert io =~ "run_id on disk but missing from registry.json: [\"step-01-agent.json\"]"
    end
  end

  # ==================================================================
  # ISS-0442 -- minimal-diff `--autofix` rewrite (regression, WF03-ISS0442-20260904)
  #
  # Spec: test/specs/ISS-0442.md. Design:
  # lib/letflow/design/iss0442-lint-handoffs-minimal-diff-autofix.md section 2.
  # Run: WF03-ISS0442-20260904, WF-03 Step 4.
  #
  # `rewrite_top_level_status!/3` and `splice_top_level_status/2` are ALL-NEW
  # functions (they replace `write_json!/2`, which no call site invokes any
  # more) -- there is no pre-fix version of either to check out and prove red
  # against, so per WF-03's "code under test does not exist" clause, fail-first
  # is satisfied by MUTATING the shipped logic instead. REVIEWER's Step 3
  # handoff (handoffs/WF03-ISS0442-20260904/step-03-reviewer.json) already
  # independently reproduced one such mutant -- removing the `depth == 1`
  # guard from `handle_string_token/5` -- and found it survives all 43
  # pre-existing tests while silently corrupting the WRONG field (leaves
  # top-level status unfixed, overwrites nested `result.status` instead).
  # T-AUTOFIX-NESTED-STATUS-COLLISION-PASS-PASS below is written specifically
  # to kill that mutant; see this test-designer's handoff result.summary for
  # the measured before/after test-run numbers proving it does.
  #
  # A document with a DUPLICATE top-level "status" key was investigated
  # while designing this suite and found to expose a real discrepancy
  # between this design's §2.2 step 2 claim ("mirroring Jason.decode/1's
  # own last-key-wins semantics") and Jason.decode!/1's ACTUAL observed
  # behavior (first-key-wins, not last) -- filed and fixed as ISS-0457. Now
  # covered by T-AUTOFIX-DUP-TOP-LEVEL-STATUS-FIRST-WINS below (describe
  # block "ISS-0457 -- duplicate top-level status key, first-match-wins");
  # see test/specs/ISS-0457.md and
  # lib/letflow/design/iss0457-splice-first-wins.md for the full analysis
  # and fail-then-pass evidence. This comment previously described the case
  # as "deliberately left uncovered" -- it is fixed and covered now, so that
  # description no longer applies.
  # ==================================================================

  describe "ISS-0442 -- minimal-diff splice" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0442-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "T-AUTOFIX-NESTED-STATUS-COLLISION-PASS-PASS -- top-level PASS corrected, nested result.status PASS untouched (kills depth==1-guard mutant)",
         %{dir: dir} do
      # Deliberately mirrors ISSUE-FIXER's originally demonstrated collision
      # shape exactly: a FIXABLE top-level status (PASS, which reaches the
      # splice branch, not an already-legal status that hits :skip) sitting
      # alongside a nested result.status carrying the SAME value. The nested
      # "status" key physically appears AFTER the top-level one in the raw
      # text, which is exactly the layout under which the depth==1-guard
      # mutant picks the WRONG (later-scanned, higher-depth) candidate as
      # `best` -- see the describe block's header comment.
      path = Path.join(dir, "step-01-agent.json")

      raw =
        "{\n" <>
          "  \"status\": \"PASS\",\n" <>
          "  \"context\": {},\n" <>
          "  \"task\": {},\n" <>
          "  \"result\": {\n" <>
          "    \"status\": \"PASS\",\n" <>
          "    \"summary\": \"ok\"\n" <>
          "  }\n" <>
          "}\n"

      expected =
        "{\n" <>
          "  \"status\": \"COMPLETED\",\n" <>
          "  \"context\": {},\n" <>
          "  \"task\": {},\n" <>
          "  \"result\": {\n" <>
          "    \"status\": \"PASS\",\n" <>
          "    \"summary\": \"ok\"\n" <>
          "  }\n" <>
          "}\n"

      File.write!(path, raw)

      capture_io(fn ->
        assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok
      end)

      rewritten = File.read!(path)

      # (a) top-level status corrected to the mapped value.
      assert Jason.decode!(rewritten)["status"] == "COMPLETED"
      # (b) nested result.status is byte-identical to its pre-fix value.
      assert Jason.decode!(rewritten)["result"]["status"] == "PASS"

      # Stronger than the two decode-based assertions above: the WHOLE file
      # is byte-identical to the hand-computed expectation, i.e. the ONLY
      # changed span anywhere in the file is the top-level value token. This
      # is what the depth==1-guard mutant fails: under that mutant, `best`
      # ends up bound to the LATER-scanned nested candidate instead (since
      # `best` is unconditionally overwritten by every depth-1-or-not match
      # found, and the nested "status" key is scanned after the top-level
      # one here), so the produced text has the top-level "PASS" UNCHANGED
      # and the nested "PASS" rewritten to "COMPLETED" -- the exact reverse
      # of `expected`, which fails this exact equality assertion.
      assert rewritten == expected
    end

    test "T-SPLICE-PRESERVES-ESCAPES-BRACES-ARRAY-NO-NEWLINE -- escapes, embedded brace, inline array, nested status untouched; no newline added",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")

      # "note"/"arr" are nested INSIDE "context" (an @schema_top_keys member),
      # not top-level, so this fixture exercises the escape/brace/array/nested
      # -status preservation properties without also tripping the unrelated
      # H3 "non-schema top-level key" check.
      raw =
        ~s({"status": "PASS", "context": {"note": "a \\"quoted\\" word and a { brace } here", ) <>
          ~s("arr": ["a", "b"]}, "result": {"status": "PASS"}})

      expected =
        ~s({"status": "COMPLETED", "context": {"note": "a \\"quoted\\" word and a { brace } here", ) <>
          ~s("arr": ["a", "b"]}, "result": {"status": "PASS"}})

      File.write!(path, raw)

      capture_io(fn ->
        assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok
      end)

      rewritten = File.read!(path)

      assert rewritten == expected

      refute String.ends_with?(rewritten, "\n"),
             "expected no trailing newline to be force-appended (the original had none)"
    end

    test "T-AUTOFIX-REFUSES-MISSING-STATUS -- a file with no top-level status key is byte-identical and reported refused",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, ~s({"context": {}, "task": {}, "result": {}}))
      before = File.read!(path)

      io =
        capture_io(fn ->
          assert_raise Mix.Error, fn -> LintHandoffs.run(["--dir", dir, "--autofix"]) end
        end)

      assert File.read!(path) == before
      assert io =~ "AUTOFIX -- REFUSED"
      assert io =~ "missing/non-string"
    end

    test "T-AUTOFIX-REFUSES-NULL-STATUS -- a null top-level status is byte-identical and reported refused",
         %{dir: dir} do
      path = Path.join(dir, "step-01-agent.json")
      File.write!(path, ~s({"status": null, "context": {}, "task": {}, "result": {}}))
      before = File.read!(path)

      io =
        capture_io(fn ->
          assert_raise Mix.Error, fn -> LintHandoffs.run(["--dir", dir, "--autofix"]) end
        end)

      assert File.read!(path) == before
      assert io =~ "AUTOFIX -- REFUSED"
      assert io =~ "missing/non-string"
    end
  end

  # ==================================================================
  # ISS-0457 -- duplicate top-level status key, first-match-wins
  # (regression, WF03-ISS0457-20260904)
  #
  # Spec: test/specs/ISS-0457.md. Design:
  # lib/letflow/design/iss0457-splice-first-wins.md section 2.
  # Run: WF03-ISS0457-20260904, WF-03 Step 4.
  #
  # `scan_for_status/4` already existed pre-fix (last-match-wins, shipped
  # with ISS-0442, commit 373f5363) -- this is a change to EXISTING
  # behavior, not a from-scratch module, so per WF-03's ordinary rule
  # (not the "code under test does not exist" clause) fail-first evidence
  # is the pre-fix commit itself, checked out in a disposable worktree, not
  # a mutant. See this test-designer's handoff result.summary for the
  # quoted FAIL (at 373f5363) and PASS (this branch) output.
  # ==================================================================

  describe "ISS-0457 -- duplicate top-level status key, first-match-wins" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0457-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "T-AUTOFIX-DUP-TOP-LEVEL-STATUS-FIRST-WINS -- FIRST depth-1 status occurrence corrected, LATER occurrence(s) byte-identical",
         %{dir: dir} do
      # Same shape as ISSUE-FIXER's originally-demonstrated fixture
      # (handoffs/WF03-ISS0457-20260904/diagnosis/dup-status-fixture.json),
      # adapted to use only @schema_top_keys members (context/task/result)
      # so this fixture doesn't also trip the unrelated H3 "non-schema
      # top-level key" check: two depth-1 "status" keys, mapping to
      # DIFFERENT @autofix_map source values ("DONE" first, "COMPLETE"
      # second) so the divergence is visible in WHICH SPAN gets edited, not
      # just in the resulting value. A nested result.status carrying yet
      # another legal value confirms the depth==1 guard from ISS-0442 still
      # applies unmodified. Under the pre-fix last-match-wins scanner, the
      # SECOND ("COMPLETE") occurrence gets rewritten and the FIRST
      # ("DONE") is left as an illegal, non-@legal_statuses value while the
      # tool still reports {:fixed, "DONE", "COMPLETED"} -- the exact
      # divergence this test exists to close.
      path = Path.join(dir, "step-01-agent.json")

      raw =
        "{\n" <>
          "  \"status\": \"DONE\",\n" <>
          "  \"context\": {},\n" <>
          "  \"task\": {},\n" <>
          "  \"result\": {\n" <>
          "    \"status\": \"PASS\"\n" <>
          "  },\n" <>
          "  \"status\": \"COMPLETE\"\n" <>
          "}\n"

      expected =
        "{\n" <>
          "  \"status\": \"COMPLETED\",\n" <>
          "  \"context\": {},\n" <>
          "  \"task\": {},\n" <>
          "  \"result\": {\n" <>
          "    \"status\": \"PASS\"\n" <>
          "  },\n" <>
          "  \"status\": \"COMPLETE\"\n" <>
          "}\n"

      File.write!(path, raw)

      capture_io(fn ->
        assert LintHandoffs.run(["--dir", dir, "--autofix"]) == :ok
      end)

      rewritten = File.read!(path)

      # (1) Decode-based check: only ever sees the FIRST occurrence after a
      # rewrite (Jason.decode/1 is itself first-key-wins) -- necessary but
      # not sufficient on its own to discriminate first-wins from
      # last-wins, since both selection rules leave the file decoding to
      # SOME single "status" value. Checks (2)-(4) below inspect the raw
      # bytes at both occurrence sites, which is what actually
      # distinguishes the two behaviors.
      assert Jason.decode!(rewritten)["status"] == "COMPLETED"

      # (2) The FIRST occurrence's raw span was rewritten to the mapped
      # value.
      assert rewritten =~ "\"status\": \"COMPLETED\",\n  \"context\""

      # (3) The SECOND occurrence's raw span is untouched -- still reads
      # "COMPLETE", not "COMPLETED" and not silently dropped.
      assert rewritten =~ "\n  \"status\": \"COMPLETE\"\n}\n"

      # (4) Strongest check: the whole file is byte-identical to the
      # hand-computed expectation, proving the ONLY changed span anywhere
      # in the file is the FIRST occurrence's value token. This is what
      # the pre-fix last-match-wins scanner fails: under that code, `best`
      # ends up bound to the SECOND-scanned candidate (unconditionally
      # overwritten on every depth-1 match), so the produced text has the
      # first "DONE" UNCHANGED and the second "COMPLETE" rewritten to
      # "COMPLETED" instead -- the exact reverse of `expected`.
      assert rewritten == expected
    end
  end

  describe "ISS-0440 -- run_autofix/1 (structured return shape, direct unit test)" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss0440-runautofix-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "F-RUN-AUTOFIX-SHAPE -- returns %{fixed: [...], refused: [...]} with the documented entry shape",
         %{dir: dir} do
      pass_path = Path.join(dir, "step-01-pass.json")
      fail_path = Path.join(dir, "step-02-fail.json")
      ok_path = Path.join(dir, "step-03-ok.json")

      File.write!(pass_path, ~s({"status": "PASS"}))
      File.write!(fail_path, ~s({"status": "FAIL"}))
      File.write!(ok_path, ~s({"status": "COMPLETED"}))

      files = LintHandoffs.handoff_files(dir)
      %{fixed: fixed, refused: refused} = LintHandoffs.run_autofix(files)

      assert [%{path: ^pass_path, from: "PASS", to: "COMPLETED"}] = fixed
      assert [%{path: ^fail_path, found: "FAIL", reason: reason}] = refused
      assert reason =~ "ambiguous"
    end
  end

  # ==================================================================
  # ISS-1037 / Q-1020 -- malformed handoff shapes are reported (H7),
  # never crash the whole corpus scan
  # ==================================================================

  defp write_raw!(dir, name, json) do
    path = Path.join(dir, name)
    File.write!(path, json)
    path
  end

  defp h7(result), do: Enum.filter(result.hard_new, &(&1.rule == "H7"))

  describe "ISS-1037 -- malformed handoff shapes produce an H7 violation instead of crashing" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("letflow-iss1037-shape-#{System.unique_integer([:positive])}")
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "T-SHAPE-TASK-STRING -- a string `task` is an H7 naming the file and the field", %{
      dir: dir
    } do
      path =
        write_raw!(
          dir,
          "step-01-agent.json",
          ~s({"status": "PENDING", "context": {}, "task": "do the thing", "result": null})
        )

      result = LintHandoffs.lint_file(path, @empty_schema)

      assert [%{path: ^path, message: msg, grandfathered: false}] = h7(result)
      assert msg =~ "task"
      assert result.parse_error == nil
    end

    test "T-SHAPE-TASK-OTHER-TYPES -- number, list and null `task` are each an H7", %{dir: dir} do
      for {label, value} <- [number: "42", list: ~s(["a"]), null: "null"] do
        path =
          write_raw!(
            dir,
            "step-#{label}.json",
            ~s({"status": "PENDING", "context": {}, "task": #{value}})
          )

        result = LintHandoffs.lint_file(path, @empty_schema)
        assert [%{message: msg}] = h7(result), "task=#{value} should be one H7"
        assert msg =~ "task"
      end
    end

    test "T-SHAPE-CONTEXT-NON-OBJECT -- a non-object `context` is an H7 naming `context`", %{
      dir: dir
    } do
      for value <- [~s("ctx"), "7", "[]", "null"] do
        path =
          write_raw!(
            dir,
            "step-ctx.json",
            ~s({"status": "PENDING", "context": #{value}, "task": {}})
          )

        result = LintHandoffs.lint_file(path, @empty_schema)
        assert [%{message: msg}] = h7(result), "context=#{value} should be one H7"
        assert msg =~ "context"
      end
    end

    test "T-SHAPE-RESULT-NULL-NOT-CRASH -- `result: null` (legitimate pre-completion state) does not crash and is not a violation",
         %{dir: dir} do
      path =
        write_raw!(
          dir,
          "step-01-agent.json",
          ~s({"status": "PENDING", "context": {}, "task": {}, "result": null})
        )

      result = LintHandoffs.lint_file(path, @empty_schema)
      assert result.hard_new == []
      assert result.hard_grandfathered == []
    end

    test "T-SHAPE-RESULT-STRING-WARNS -- a non-null, non-object `result` is a WARN, not a hard failure",
         %{dir: dir} do
      path =
        write_raw!(
          dir,
          "step-01-agent.json",
          ~s({"status": "COMPLETED", "context": {}, "task": {}, "result": "PASS"})
        )

      result = LintHandoffs.lint_file(path, @empty_schema)
      assert result.hard_new == []
      assert Enum.any?(result.advisory.warnings, &match?({:warn, "H7-RESULT", _}, &1))
    end

    test "T-SHAPE-NESTED-FIELDS -- wrongly typed nested fields are H7s naming the field, no crash",
         %{dir: dir} do
      cases = [
        {~s({"status": "PENDING", "task": {"description": 5}}), "task.description"},
        {~s({"status": "PENDING", "context": {"artifacts_in": "a.md"}}), "context.artifacts_in"},
        {~s({"status": "PENDING", "context": {"artifacts_in": [1]}}), "context.artifacts_in"},
        {~s({"status": "COMPLETED", "result": {"artifacts_out": {"a": 1}}}),
         "result.artifacts_out"},
        {~s({"status": "COMPLETED", "result": {"artifacts_out": [null]}}),
         "result.artifacts_out"},
        {~s({"status": "PENDING", "created_at": 12}), "created_at"}
      ]

      for {{json, field}, i} <- Enum.with_index(cases) do
        path = write_raw!(dir, "step-nested-#{i}.json", json)
        result = LintHandoffs.lint_file(path, @empty_schema)
        assert [%{message: msg}] = h7(result), "#{json} should be one H7"
        assert msg =~ field
      end
    end

    test "T-SHAPE-TOP-LEVEL-NON-OBJECT -- a top-level array/string/number/null is an H7, no crash",
         %{dir: dir} do
      for {value, i} <- Enum.with_index(["[]", ~s(["a"]), ~s("s"), "3", "null"]) do
        path = write_raw!(dir, "step-top-#{i}.json", value)
        result = LintHandoffs.lint_file(path, @empty_schema)
        assert [%{path: ^path, message: msg}] = result.hard_new, "top-level #{value}"
        assert msg =~ "top-level"
        assert Enum.all?(result.hard_new, &(&1.rule == "H7"))
        assert result.advisory.warnings == []
      end
    end

    test "T-SHAPE-RUN-REPORTS-NOT-CRASHES -- run/1 raises Mix.Error naming the file for a string task, not FunctionClauseError",
         %{dir: dir} do
      path =
        write_raw!(
          dir,
          "step-01-agent.json",
          ~s({"status": "PENDING", "context": {}, "task": "oops"})
        )

      io =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/new violation/, fn -> LintHandoffs.run(["--dir", dir]) end
        end)

      assert io =~ "[H7]"
      assert io =~ path
    end

    test "T-SHAPE-RUN-CONTINUES -- a malformed file does not stop later files being linted", %{
      dir: dir
    } do
      write_raw!(dir, "step-01-bad.json", ~s({"status": "PENDING", "task": "oops"}))
      write_raw!(dir, "step-02-bad-status.json", ~s({"status": "NOPE"}))

      io =
        capture_io(fn ->
          assert_raise Mix.Error, fn -> LintHandoffs.run(["--dir", dir]) end
        end)

      assert io =~ "[H7]"
      assert io =~ "[H1]"
    end

    test "T-SHAPE-AUTOFIX-NON-OBJECT -- run_autofix/1 skips a top-level non-object file instead of crashing",
         %{dir: dir} do
      write_raw!(dir, "step-01-list.json", "[1, 2]")
      files = LintHandoffs.handoff_files(dir)
      assert %{fixed: [], refused: []} = LintHandoffs.run_autofix(files)
    end

    test "T-SHAPE-AC-NESTED-ELEMENT -- a non-scalar acceptance_criteria element does not crash the advisory pass",
         %{dir: dir} do
      path =
        write_raw!(
          dir,
          "step-01-agent.json",
          ~s({"status": "PENDING", "context": {}, "task": {"description": "d", "acceptance_criteria": [{"a": 1}, ["x"]]}})
        )

      result = LintHandoffs.lint_file(path, @empty_schema)
      assert result.parse_error == nil
      assert result.hard_new == []
    end

    test "T-SHAPE-VALID-UNCHANGED -- a valid, fully populated handoff still lints clean", %{
      dir: dir
    } do
      path =
        write_raw!(dir, "step-01-agent.json", ~s({
          "status": "COMPLETED",
          "created_at": "2026-08-22T07:00:00Z",
          "context": {"artifacts_in": ["a/b.md"]},
          "task": {"description": "d", "acceptance_criteria": ["x"]},
          "result": {"summary": "s", "artifacts_out": ["c/d.md"]}
        }))

      result = LintHandoffs.lint_file(path, @empty_schema)
      assert result.hard_new == []
      assert result.hard_grandfathered == []
      refute Enum.any?(result.advisory.warnings, &match?({:warn, "H7" <> _, _}, &1))
    end
  end

  describe "REQ-524 -- optional top-level `tier` field" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lint_tier_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "T-TIER-SHORT -- a handoff with tier: SHORT lints clean", %{dir: dir} do
      path = write_raw!(dir, "step-01-agent.json", ~s({"status": "COMPLETED", "tier": "SHORT"}))
      result = LintHandoffs.lint_file(path, @empty_schema)
      assert result.hard_new == []
      assert result.hard_grandfathered == []
    end

    test "T-TIER-FULL -- a handoff with tier: FULL lints clean", %{dir: dir} do
      path = write_raw!(dir, "step-01-agent.json", ~s({"status": "COMPLETED", "tier": "FULL"}))
      assert LintHandoffs.lint_file(path, @empty_schema).hard_new == []
    end

    test "T-TIER-BOGUS -- tier: BOGUS is refused", %{dir: dir} do
      path = write_raw!(dir, "step-01-agent.json", ~s({"status": "COMPLETED", "tier": "BOGUS"}))
      result = LintHandoffs.lint_file(path, @empty_schema)
      assert [violation] = result.hard_new
      assert violation.rule == "H3"
      assert violation.message =~ "tier"
      assert violation.message =~ "not one of"
    end
  end
end
