defmodule Mix.Tasks.Letflow.AuditIssueClosuresTest do
  @moduledoc """
  Regression coverage for ISS-0279 -- `mix letflow.audit_issue_closures`
  (`lib/mix/tasks/letflow.audit_issue_closures.ex`).

  Spec: `test/specs/ISS-0279.md`. Design:
  `lib/letflow/design/iss0279-issue-closure-audit.md`.
  Run: `WF03-ISS0279-20260822`, WF-03 Step 4.

  ## Why this is the MUTATION-required case, not the ordinary fail-then-pass case

  This is a wholly NET-NEW module -- `classify/1`, `tracked_issues/1`,
  `grandfathered?/1` did not exist pre-fix at all. A pre-fix run of this suite
  fails with `UndefinedFunctionError`/`Mix.NoTaskError` for every test in the
  file, which proves the module is new and nothing whatever about whether these
  tests discriminate a correct implementation from a wrong one (a suite can fail
  against a missing module and still be vacuous against a broken one). Per
  `docs/agents/workflows/WF-03_issue_resolving.md`'s "When the pre-fix failure is
  'the code under test does not exist'" section, the fail-first requirement here
  is satisfied ONLY by mutating the shipped logic and recording which tests fail
  per mutant -- see this run's `handoffs/WF03-ISS0279-20260822/step-04-test-designer.json`
  `result.summary` for the two mutants applied to `classify/1`, their per-test
  pass/fail counts, and the verified revert.

  ## No live `gh` / network call anywhere in this file

  * `tracked_issues/1` is exercised against fabricated `docs/issues/*.yaml`-shaped
    fixture files written to a tmp dir per test -- never the real `docs/issues/`
    corpus's live GitHub state (the real corpus IS read by
    `F-TRACKED-REAL-CORPUS-NO-CRASH` below, but only to prove parsing doesn't
    crash on real file content -- it asserts shape invariants only, never a `gh`
    fact).
  * `classify/1` is exercised directly with fabricated gh-JSON-shaped maps --
    the exact shapes documented in the module's own `@moduledoc` (`comments` as
    a bare array vs. a `%{"totalCount" => n}` object, matching the two live `gh`
    response shapes the module's Discovery notes describes).
  * `grandfathered?/1` is private with no exported test seam (confirmed: only
    `tracked_issues/1`, `fetch_issue/1`, and `classify/1` carry `@spec`/are
    `def`, not `defp`, in the shipped module) and `run/1` hardcodes
    `@issues_dir` internally, so it cannot be pointed at a fixture dir.
    `describe "grandfathered?/1 membership -- integration via run/1 with a
    faked gh"` below exercises it end-to-end against the REAL `docs/issues/`
    corpus (never mutated, never touched) by monkey-patching this OS process's
    `PATH` so `System.cmd("gh", ...)` inside `fetch_issue/1` resolves to a
    fixture script this test controls, restored via `on_exit`. Two REAL,
    already-tracked GitHub issue numbers are targeted: `68` (already a real
    `@grandfathered` entry, traced to `docs/issues/ISS-0012.yaml`) and `15`
    (a real tracked number, `docs/issues/ISS-0009.yaml`, NOT in
    `@grandfathered`). Every other real tracked number gets a fixture `OPEN`
    response so it never becomes a violation and never pollutes the assertion.
    This is real integration coverage of `grandfathered?/1`'s actual behavior on
    two real, named numbers -- not a mock replacing the function under test.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  # ISS-0297: extended from default 60s because Audit.run([]) processes the real docs/issues/ corpus (200+ YAML files) with System.cmd per closed issue -- hits ExUnit default under 16-way CPU load.
  @moduletag timeout: 120_000

  import ExUnit.CaptureIO

  alias Mix.Tasks.Letflow.AuditIssueClosures, as: Audit

  # ==================================================================
  # tracked_issues/1 -- discovery + github_issue field-shape parsing
  # ==================================================================
  #
  # Covers every real surface shape confirmed present in the live
  # docs/issues/*.yaml corpus per the module's own "Discovery notes" section:
  # bare integer, bare (unquoted) URL, quoted URL, and null/absent.

  describe "tracked_issues/1 -- github_issue field-shape parsing" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "letflow-audit-issue-closures-#{System.unique_integer([:positive])}"
        )
        |> Path.expand()

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "F-PREFIXED -- github_ref: GH-<n> is parsed", %{dir: dir} do
      write_issue(dir, "ISS-9001.yaml", "id: ISS-9001\ngithub_ref: GH-205\n")

      assert [%{ref: "ISS-9001", number: 205, path: path}] = Audit.tracked_issues(dir)
      assert path == Path.join(dir, "ISS-9001.yaml")
    end

    # UPDATED 2026-09-09 (ISSUE_QUEUE.md "Numbering schema"). F-BARE-INT,
    # F-BARE-URL and F-QUOTED-URL used to assert that `github_issue:` parsed as a
    # bare integer, an unquoted URL and a quoted URL -- the three shapes the real
    # corpus carried. All 305 files were normalised to a single
    # `github_ref: GH-<n>`, and `mix letflow.check_issue_refs` rejects every
    # other shape.
    #
    # Inverted rather than deleted: the legacy shapes must NOT be parsed. A
    # reader that still accepted them would make the normalisation
    # unenforceable -- a file violating the schema would stay invisible to this
    # audit instead of surfacing, which is the failure the gate exists to stop.
    test "F-LEGACY-FIELD-IGNORED -- the superseded `github_issue:` field is not parsed",
         %{dir: dir} do
      write_issue(dir, "ISS-9002.yaml", "id: ISS-9002\ngithub_issue: 205\n")

      assert Audit.tracked_issues(dir) == []
    end

    test "F-LEGACY-URL-IGNORED -- a full GitHub URL is not a ref", %{dir: dir} do
      write_issue(
        dir,
        "ISS-9003.yaml",
        "id: ISS-9003\ngithub_ref: https://github.com/tvolodi/letflow/issues/206\n"
      )

      assert Audit.tracked_issues(dir) == []
    end

    test "F-NULL-ABSENT -- github_ref: null is skipped entirely (not tracked)", %{dir: dir} do
      write_issue(dir, "ISS-9004.yaml", "id: ISS-9004\ngithub_ref: null\n")

      assert Audit.tracked_issues(dir) == []
    end

    test "F-FIELD-ABSENT -- a file with no github_issue field at all is skipped", %{dir: dir} do
      write_issue(dir, "ISS-9005.yaml", "id: ISS-9005\nstatus: open\n")

      assert Audit.tracked_issues(dir) == []
    end

    test "F-ID-FALLBACK -- when id: is missing, ref falls back to the filename stem", %{
      dir: dir
    } do
      write_issue(dir, "ISS-9006.yaml", "github_ref: GH-42\n")

      assert [%{ref: "ISS-9006", number: 42}] = Audit.tracked_issues(dir)
    end

    test "F-MULTIPLE-SORTED -- multiple tracked files are returned sorted by path", %{dir: dir} do
      write_issue(dir, "ISS-9020.yaml", "id: ISS-9020\ngithub_ref: GH-20\n")
      write_issue(dir, "ISS-9010.yaml", "id: ISS-9010\ngithub_ref: GH-10\n")

      assert [%{ref: "ISS-9010"}, %{ref: "ISS-9020"}] = Audit.tracked_issues(dir)
    end

    test "F-TRACKED-REAL-CORPUS-NO-CRASH -- parsing the real docs/issues corpus never crashes and every entry has a positive integer number" do
      # No gh call here at all -- purely local file parsing against the real
      # committed corpus, proving the regex handles every real shape in the
      # repo today (this is the same guarantee the module's own "Discovery
      # notes" section documents finding necessary).
      tracked = Audit.tracked_issues("docs/issues")

      assert tracked != []
      assert Enum.all?(tracked, fn %{number: n} -> is_integer(n) and n > 0 end)
      assert Enum.all?(tracked, fn %{ref: ref} -> is_binary(ref) and ref != "" end)
    end

    defp write_issue(dir, filename, content) do
      File.write!(Path.join(dir, filename), content)
    end
  end

  # ==================================================================
  # classify/1 -- ZERO_EVIDENCE vs OK vs not_closed, direct fixture maps
  # ==================================================================

  describe "classify/1 -- ZERO_EVIDENCE vs OK decision" do
    test "T-VIOLATION-ARRAY -- CLOSED, comments as an empty array, no PR refs -> :violation" do
      data = %{
        "state" => "CLOSED",
        "comments" => [],
        "closedByPullRequestsReferences" => []
      }

      assert Audit.classify(data) == :violation
    end

    test "T-VIOLATION-TOTALCOUNT -- CLOSED, comments as %{totalCount: 0}, no PR refs -> :violation" do
      data = %{
        "state" => "CLOSED",
        "comments" => %{"totalCount" => 0},
        "closedByPullRequestsReferences" => []
      }

      assert Audit.classify(data) == :violation
    end

    test "T-OK-HAS-COMMENT-ARRAY -- CLOSED with a non-empty comments array -> :ok (I1)" do
      data = %{
        "state" => "CLOSED",
        "comments" => [%{"body" => "closed, see PR #1"}],
        "closedByPullRequestsReferences" => []
      }

      assert Audit.classify(data) == :ok
    end

    test "T-OK-HAS-COMMENT-TOTALCOUNT -- CLOSED with comments totalCount > 0 -> :ok (I1)" do
      data = %{
        "state" => "CLOSED",
        "comments" => %{"totalCount" => 3},
        "closedByPullRequestsReferences" => []
      }

      assert Audit.classify(data) == :ok
    end

    test "T-OK-HAS-PR-REF -- CLOSED with zero comments but a linked PR ref -> :ok (I2)" do
      data = %{
        "state" => "CLOSED",
        "comments" => [],
        "closedByPullRequestsReferences" => [%{"number" => 501}]
      }

      assert Audit.classify(data) == :ok
    end

    test "T-OK-BOTH-PRESENT -- CLOSED with both a comment and a PR ref -> :ok" do
      data = %{
        "state" => "CLOSED",
        "comments" => %{"totalCount" => 1},
        "closedByPullRequestsReferences" => [%{"number" => 501}]
      }

      assert Audit.classify(data) == :ok
    end

    test "T-NOT-CLOSED-OPEN -- state OPEN is never classified, regardless of comments/refs" do
      data = %{
        "state" => "OPEN",
        "comments" => [],
        "closedByPullRequestsReferences" => []
      }

      assert Audit.classify(data) == :not_closed
    end

    test "T-MISSING-REFS-KEY -- refs key entirely absent defaults to empty (still a violation with 0 comments)" do
      data = %{"state" => "CLOSED", "comments" => []}

      assert Audit.classify(data) == :violation
    end

    test "T-MISSING-COMMENTS-KEY -- comments key entirely absent is treated as non-empty (not a violation)" do
      # comments_empty?/1's catch-all clause returns false for any shape that
      # is neither a list nor a %{"totalCount" => _} map -- including `nil`
      # (the Map.get/2 default when the key is absent). This pins that exact
      # documented behavior so a future change to the catch-all clause is
      # caught here rather than silently flipping which closures count as
      # ZERO_EVIDENCE.
      data = %{"state" => "CLOSED", "closedByPullRequestsReferences" => []}

      assert Audit.classify(data) == :ok
    end
  end

  # ==================================================================
  # grandfathered?/1 membership -- integration via run/1 with a faked `gh`
  # ==================================================================

  describe "grandfathered?/1 membership -- integration via run/1 with a faked gh" do
    setup do
      original_path = System.get_env("PATH")

      fixture_dir =
        Path.join(System.tmp_dir!(), "letflow-fake-gh-#{System.unique_integer([:positive])}")

      File.mkdir_p!(fixture_dir)

      # REQ-136 (2026-08-23): this fixture was Windows-only -- a `gh.bat` batch
      # script (`%3`, `@echo off`, `exit /b 0`) plus a `;`-joined PATH, which is
      # the Windows path-list separator. On a real GitHub Actions Linux runner
      # both assumptions are wrong: `;` inside PATH is not a separator (it
      # malforms the whole variable into one nonexistent directory entry), and
      # even if it were, `gh.bat` is not an executable format `System.cmd/3`
      # will invoke on Linux -- so `fetch_issue/1` silently fails to find any
      # `gh` at all, producing a fetch error per issue rather than the intended
      # fixture response. Write the OS-appropriate script and join PATH with the
      # OS-appropriate separator instead of hardcoding either.
      windows? = match?({:win32, _}, :os.type())

      # For real tracked issue #68 (already a real @grandfathered entry,
      # docs/issues/ISS-0012.yaml) and #15 (a real tracked, un-grandfathered
      # number, docs/issues/ISS-0009.yaml), respond CLOSED with zero
      # evidence -- a genuine ZERO_EVIDENCE violation. Every other real
      # tracked number gets an OPEN response so it is never a violation and
      # never pollutes this assertion.
      if windows? do
        gh_script = Path.join(fixture_dir, "gh.bat")

        File.write!(gh_script, """
        @echo off
        if "%3"=="68" (
          echo {"number":68,"state":"CLOSED","comments":[],"closedByPullRequestsReferences":[]}
          exit /b 0
        )
        if "%3"=="15" (
          echo {"number":15,"state":"CLOSED","comments":[],"closedByPullRequestsReferences":[]}
          exit /b 0
        )
        echo {"number":%3,"state":"OPEN","comments":[],"closedByPullRequestsReferences":[]}
        exit /b 0
        """)
      else
        gh_script = Path.join(fixture_dir, "gh")

        File.write!(gh_script, """
        #!/bin/sh
        case "$3" in
          68)
            echo '{"number":68,"state":"CLOSED","comments":[],"closedByPullRequestsReferences":[]}'
            exit 0
            ;;
          15)
            echo '{"number":15,"state":"CLOSED","comments":[],"closedByPullRequestsReferences":[]}'
            exit 0
            ;;
          *)
            echo "{\\"number\\":$3,\\"state\\":\\"OPEN\\",\\"comments\\":[],\\"closedByPullRequestsReferences\\":[]}"
            exit 0
            ;;
        esac
        """)

        File.chmod!(gh_script, 0o755)
      end

      path_separator = if windows?, do: ";", else: ":"
      System.put_env("PATH", fixture_dir <> path_separator <> (original_path || ""))

      on_exit(fn ->
        if original_path, do: System.put_env("PATH", original_path)
        File.rm_rf!(fixture_dir)
      end)

      :ok
    end

    test "T-GRANDFATHERED-VS-NEW -- real GH#68 (grandfathered) is reported separately from real GH#15 (new)" do
      output =
        capture_io(fn ->
          assert_raise Mix.Error, ~r/1 new violation/, fn ->
            Audit.run([])
          end
        end)

      assert output =~ "NEW HARD VIOLATIONS"

      assert output =~
               "  [ZERO_EVIDENCE] GH#15 (docs/issues/ISS-0009.yaml): closed with 0 comments"

      refute output =~
               "  [ZERO_EVIDENCE] GH#68 (docs/issues/ISS-0012.yaml): closed with 0 comments"

      assert output =~ "GRANDFATHERED"
      assert output =~ "  [ZERO_EVIDENCE] GH#68 (docs/issues/ISS-0012.yaml, grandfathered"
      refute output =~ "GH#15 (docs/issues/ISS-0009.yaml, grandfathered"
    end
  end
end
