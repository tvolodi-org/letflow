defmodule Mix.Tasks.Letflow.WorkBoardGatesTest do
  @moduledoc """
  ISS-1073 / GH #2430: the three static gate checks accept a GitHub issue
  number (`gh:` on a requirement, `GH-<n>` on an issue record) as well as the
  legacy queue ids, and `docs/status/work_board_cutover.yaml` is the single
  switch between the transition and the post-cutover rules.

  Hermetic fixtures only (plus one live-file presence test): the existing
  per-check suites keep covering the legacy `impl_order` / `queue_ref` forms.
  Every fixture here carries a GitHub number and NO queue id, which is the
  shape every new record has once the queue is stopped.
  """

  use ExUnit.Case, async: true

  alias Mix.Letflow.WorkBoardCutover
  alias Mix.Tasks.Letflow.CheckDeferralStaleness, as: Staleness
  alias Mix.Tasks.Letflow.CheckIssueRefs, as: IssueRefs
  alias Mix.Tasks.Letflow.CheckRequirementsRegistration, as: Registration

  @stages_section Enum.join(
                    ["stages:", "  - id: S4", "    name: API surface", ""],
                    "\n"
                  )

  defp doc(body), do: @stages_section <> "requirements:\n" <> body

  defp req(id, fields) do
    Enum.join(["  - id: " <> id | Enum.map(fields, &("    " <> &1))], "\n") <> "\n"
  end

  defp scan(body, cutover), do: Registration.scan(doc(body), cutover: cutover)

  defp rules(report), do: report.violations |> Enum.map(& &1.rule) |> Enum.sort()

  describe "WorkBoardCutover.parse/1" do
    test "reads the switch and the legacy ISS ceiling, ignoring comments and CRLF" do
      assert {:ok, %{cutover: false, last_legacy_iss: 1109}} =
               WorkBoardCutover.parse(
                 "# header\r\ncutover: false   # flip on cutover day\r\nlast_legacy_iss: 1109\r\n"
               )

      assert {:ok, %{cutover: false, last_legacy_iss: nil}} =
               WorkBoardCutover.parse("cutover: false\n")

      assert {:ok, %{cutover: true, last_legacy_iss: 1119}} =
               WorkBoardCutover.parse("cutover: true\nlast_legacy_iss: 1119\n")
    end

    test "cutover: true without last_legacy_iss is an error (fail closed)" do
      assert {:error, msg} = WorkBoardCutover.parse("cutover: true\n")
      assert msg =~ "requires `last_legacy_iss:`"
    end

    test "a duplicated key is an error, not last-one-wins" do
      assert {:error, msg} =
               WorkBoardCutover.parse("cutover: true\nlast_legacy_iss: 1\ncutover: false\n")

      assert msg =~ "`cutover:` appears more than once"

      assert {:error, msg} =
               WorkBoardCutover.parse("cutover: false\nlast_legacy_iss: 1\nlast_legacy_iss: 2\n")

      assert msg =~ "`last_legacy_iss:` appears more than once"
    end

    test "refuses a missing or non-boolean switch rather than defaulting" do
      assert {:error, "no `cutover:` field"} = WorkBoardCutover.parse("last_legacy_iss: 1\n")
      assert {:error, msg} = WorkBoardCutover.parse("cutover: yes\n")
      assert msg =~ "neither true nor false"
      assert {:error, msg} = WorkBoardCutover.parse("cutover: true\nlast_legacy_iss: abc\n")
      assert msg =~ "not a non-negative integer"
    end

    test "the live switch file exists and parses" do
      root = Path.expand("../../..", __DIR__)
      path = Path.join(root, WorkBoardCutover.path())
      assert File.exists?(path), "#{path} is the single cutover switch and must be committed"
      assert {:ok, %{cutover: cutover}} = path |> File.read!() |> WorkBoardCutover.parse()
      assert is_boolean(cutover)
    end
  end

  describe "check_requirements_registration: gh: registration" do
    test "a requirement carrying only `gh:` is registered, before and after cutover" do
      body = req("REQ-900", ["stage: S4", "status: pending", "gh: 2430"])

      for cutover <- [false, true] do
        report = scan(body, cutover)
        assert [entry] = report.entries
        assert entry.state == :registered
        assert entry.gh == 2430
        assert entry.impl_order == nil
        assert report.violations == []
        assert report.counts.registered == 1
      end
    end

    test "CRLF line endings (docs/requirements.yaml is CRLF in a Windows checkout)" do
      body = req("REQ-900", ["stage: S4", "status: pending", "gh: 2430"])
      crlf = String.replace(doc(body), "\n", "\r\n")

      report = Registration.scan(crlf, cutover: true)
      assert [%{state: :registered, gh: 2430}] = report.entries
      assert report.violations == []
    end

    test "a gh line whose comment mentions impl_order is still only a gh line" do
      body =
        req("REQ-900", [
          "stage: S4",
          "status: pending",
          "impl_order: 12",
          "gh: 2430  # REQ-900 board issue; impl_order above is history"
        ])

      for cutover <- [false, true] do
        report = scan(body, cutover)
        assert [%{state: :registered, gh: 2430, impl_order: 12}] = report.entries
        assert report.violations == []
      end
    end

    test "a trailing comment on the gh line is allowed" do
      report = scan(req("REQ-900", ["stage: S4", "gh: 77  # REQ-900 board issue"]), true)
      assert [%{state: :registered, gh: 77}] = report.entries
      assert report.violations == []
    end

    test "gh beside a legacy impl_order keeps both (history is not erased)" do
      body = req("REQ-900", ["stage: S4", "status: pending", "impl_order: 1022", "gh: 2337"])

      for cutover <- [false, true] do
        report = scan(body, cutover)
        assert [%{state: :registered, gh: 2337, impl_order: 1022}] = report.entries
        assert report.violations == []
      end
    end

    test "malformed, zero and hash-prefixed numbers are unclassified (R2)" do
      for bad <- ["gh: abc", "gh: 0", "gh: #2430", "gh:", "gh: 12ab", "gh: -5"] do
        report = scan(req("REQ-900", ["stage: S4", bad]), false)
        assert [%{state: :unclassified, gh: nil}] = report.entries, "#{bad} must not register"
        assert rules(report) == ["R2"], "#{bad}"
      end
    end

    test "two gh lines are ambiguous (R2)" do
      report = scan(req("REQ-900", ["stage: S4", "gh: 1", "gh: 2"]), false)
      assert [%{state: :unclassified}] = report.entries
      assert rules(report) == ["R2"]
      assert hd(report.violations).message =~ "2 attributed gh lines"
    end

    test "gh next to the deferral marker is a contradiction (R2)" do
      body =
        req("REQ-900", ["stage: S4", "gh: 5", "# impl_order: UNREGISTERED -- waits on REQ-1"])

      report = scan(body, false)
      assert [%{state: :unclassified}] = report.entries
      assert rules(report) == ["R2"]
      assert hd(report.violations).message =~ "deferral marker"
    end

    test "a `gh:` line deeper than field level (prose in a block) is not a registration" do
      body =
        req("REQ-900", [
          "stage: S4",
          "impl_order: 9",
          "description: >",
          "  gh: 999 appears in prose here"
        ])

      report = scan(body, false)
      assert [%{state: :registered, gh: nil, impl_order: 9}] = report.entries
      assert report.violations == []
    end

    test "an entry with neither form is still R1, and the message names both forms" do
      report = scan(req("REQ-900", ["stage: S4", "status: pending"]), false)
      assert rules(report) == ["R1"]
      assert hd(report.violations).message =~ "no `gh:` issue"
    end
  end

  describe "check_requirements_registration: R7 (cutover only)" do
    defp legacy_only(status),
      do: req("REQ-901", ["stage: S4", "status: #{status}", "impl_order: 12"])

    test "a live requirement with only impl_order passes before cutover" do
      for status <- ["pending", "in_progress", "blocked"] do
        assert scan(legacy_only(status), false).violations == []
      end
    end

    test "after cutover it must carry gh:" do
      for status <- ["pending", "in_progress", "blocked"] do
        report = scan(legacy_only(status), true)
        assert rules(report) == ["R7"], status
        assert hd(report.violations).id == "REQ-901"
      end
    end

    test "terminal requirements keep their legacy impl_order as history after cutover" do
      for status <- ["done", "cancelled"] do
        assert scan(legacy_only(status), true).violations == []
      end
    end

    test "adding gh: clears R7" do
      body = req("REQ-901", ["stage: S4", "status: pending", "impl_order: 12", "gh: 2450"])
      assert scan(body, true).violations == []
    end
  end

  describe "check_deferral_staleness: gh-registered entries" do
    defp gh_done(id), do: req(id, ["stage: S4", "status: done", "gh: 2400"])

    defp deferred(id, rationale),
      do: req(id, ["stage: S4", "status: pending", "# impl_order: UNREGISTERED #{rationale}"])

    test "a gh-only done entry activates its stage exactly like an impl_order one" do
      for cutover <- [false, true] do
        result =
          Staleness.audit(doc(gh_done("REQ-910") <> deferred("REQ-911", "-- waits")),
            cutover: cutover
          )

        assert [%{id: "REQ-911", verdict: :stale}] = result.deferrals
        assert [violation] = Enum.filter(result.violations, &(&1.rule == "S1"))
        assert violation.message =~ "WORK_BOARD.md"
        assert result.statuses["REQ-910"] == :done
      end
    end

    test "a blocked-by hatch naming a gh-registered live sibling stays legitimate" do
      body =
        req("REQ-920", ["stage: S4", "status: in_progress", "gh: 2401"]) <>
          deferred("REQ-921", "-- blocked-by: REQ-920 -- waits for the sibling")

      for cutover <- [false, true] do
        result = Staleness.audit(doc(body), cutover: cutover)
        assert [%{id: "REQ-921", verdict: :legitimate}] = result.deferrals
        assert result.violations == []
      end
    end

    test "a corpus of gh-only requirements passes with no deferrals" do
      body = gh_done("REQ-930") <> req("REQ-931", ["stage: S4", "status: pending", "gh: 2402"])

      for cutover <- [false, true] do
        result = Staleness.audit(doc(body), cutover: cutover)
        assert result.violations == []
        assert result.deferral_count == 0
      end
    end
  end

  describe "check_issue_refs: records named by GH number" do
    defp audit(content, name, opts \\ []),
      do: IssueRefs.audit(content, "docs/issues/#{name}.yaml", opts)

    defp gh_record(n), do: "id: GH-#{n}\ntitle: board issue\nstatus: open\ngithub_ref: GH-#{n}\n"

    test "a record with only a GH number (no queue_ref) passes before and after cutover" do
      for cutover <- [false, true] do
        assert audit(gh_record(2430), "GH-2430", cutover: cutover, last_legacy_iss: 1109) == []
      end
    end

    test "R5: the id must match the filename" do
      assert [v] = audit(gh_record(2430), "GH-2431", cutover: false)
      assert v.rule == :R5
      assert v.message =~ "does not match filename"
    end

    test "R5: a malformed GH id is a placeholder" do
      for bad <- ["GH-0", "GH-abc", "GH-"] do
        assert [v] = audit("id: #{bad}\ngithub_ref: GH-1\n", bad, cutover: false)
        assert v.rule == :R5
      end
    end

    test "R6: github_ref must repeat the id's number" do
      assert [v] = audit("id: GH-5\ngithub_ref: GH-6\n", "GH-5")
      assert v.rule == :R6

      assert [v] = audit("id: GH-5\ntitle: x\n", "GH-5")
      assert v.rule == :R6
      assert v.message =~ "no github_ref"

      assert [v] = audit("id: GH-5\ngithub_ref: null  # nope\n", "GH-5")
      assert v.rule == :R6
    end

    test "R1/R3 still apply to a GH-named record's fields" do
      assert [v] = audit("id: GH-5\ngithub_ref: GH-5\nqueue_ref: 76\n", "GH-5")
      assert v.rule == :R1
    end

    test "R7: an ISS-NNNN above last_legacy_iss is refused only after cutover" do
      content = "id: ISS-1110\ngithub_ref: GH-2500\nqueue_ref: null  # not queued\n"

      assert audit(content, "ISS-1110", cutover: false, last_legacy_iss: 1109) == []
      assert [v] = audit(content, "ISS-1110", cutover: true, last_legacy_iss: 1109)
      assert v.rule == :R7
      assert v.message =~ "GH-<n>.yaml"
    end

    test "R7: the legacy ceiling itself and anything below it stay valid after cutover" do
      for n <- ["ISS-1109", "ISS-0042"] do
        content = "id: #{n}\ngithub_ref: GH-89\nqueue_ref: Q-76\n"
        assert audit(content, n, cutover: true, last_legacy_iss: 1109) == []
      end
    end
  end

  describe "readers are hermetic and survive the flip (main went red on 2026-10-14)" do
    # A scan/audit with no :cutover option must give the pre-cutover answer whatever the
    # repo's own docs/status/work_board_cutover.yaml says, so a flip can never change the
    # verdict of a fixture test (the five registration tests that read the real file).
    test "scan/2 without options does not read the real switch file" do
      legacy_only = req("REQ-001", ["status: pending", "impl_order: 42", "stage: S4"])

      assert Registration.scan(doc(legacy_only)).violations == []
      assert rules(scan(legacy_only, true)) == ["R7"]
    end

    test "issue_refs audit/3 without options does not apply the post-cutover ceiling" do
      content = "id: ISS-9999
queue_ref: Q-9999
github_ref: GH-1
status: open
"
      assert IssueRefs.audit(content, "ISS-9999") == []
    end

    # The flip itself must be safe: the real tree under cutover: true passes all three checks.
    test "the real requirements file passes the registration check with cutover: true" do
      report = Registration.scan(File.read!("docs/requirements.yaml"), cutover: true)
      assert report.violations == []
    end

    test "the real requirements file passes the staleness audit with cutover: true" do
      result = Staleness.audit(File.read!("docs/requirements.yaml"), cutover: true)
      assert result.violations == []
    end

    test "every real issue record passes issue_refs with cutover: true and the file's ceiling" do
      last = WorkBoardCutover.load!().last_legacy_iss

      violations =
        "docs/issues/*.yaml"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          IssueRefs.audit(File.read!(path), Path.basename(path, ".yaml"),
            cutover: true,
            last_legacy_iss: last
          )
        end)

      assert violations == []
    end
  end
end
