defmodule Mix.Tasks.Letflow.CheckDeferralStalenessTest do
  @moduledoc """
  Regression coverage for ISS-0258 -- `mix letflow.check_deferral_staleness`
  (`lib/mix/tasks/letflow.check_deferral_staleness.ex`).

  Spec: `test/specs/ISS-0258.md`. Design:
  `lib/letflow/design/iss0258-deferral-staleness-detection.md`, built to its
  section 7.4 as amended by section 11 (the Step-2b gate record, which added
  rule S6, mutants MS14/MS15/MS16 and the fixture `F-HISTORICAL-S4-STALE`).
  Run: `WF03-ISS0258-20260822`, WF-03 Step 4.

  ## Why this suite is almost entirely hermetic

  The fix ADDS a module, so the pre-fix failure of every test here is
  `UndefinedFunctionError` -- which proves the module is new and nothing
  else. WF-03's "when the pre-fix failure is 'the code under test does not
  exist'" clause governs: discrimination is demonstrated by mutating the
  shipped logic and recording which tests go red, and the tests have to be
  shaped so the mutants actually bite.

  Design section 7.2 is the load-bearing constraint here, and it was
  re-measured on this branch: the live `docs/requirements.yaml` holds

      0 deferred of 115 entries; 0 stale

  With **zero** deferred entries, every live-corpus assertion about S1, S2,
  S3 and S6 passes *vacuously* and would keep passing under almost every
  mutation of the staleness rules. This is not hypothetical -- ISS-0231 hit
  exactly this when PR #495 emptied the deferred set mid-run and made its
  headline M1 mutant invisible to every live test.

  So, stated plainly: **the hermetic fixture group is the whole test.** The
  `T-LIVE-*` tests below are over-firing guards plus genuine signal for the
  status-parsing (MS4, MS5) and stage-activity (MS1, MS2, MS3) halves only.
  No mutant is cited as detected by a live test alone.

  ## Fixture shape

  Fixtures are built by string concatenation, never by heredoc: indentation
  is load-bearing for the parser this module reuses
  (`CheckRequirementsRegistration.scan/1` and its >= 4-space attribution
  rule), so it is spelled out rather than left to heredoc stripping. Every
  fixture is wrapped in a realistic two-key file with a `stages:` section
  ahead of `requirements:`, so the section guard stays exercised.

  ## Note for a future reader of T-LIVE-ACTIVITY (design OQ-5)

  `T-LIVE-ACTIVITY` pins the derived *set* of active stages, not any count.
  It will change legitimately when S5/S6/S7 are expanded into requirements,
  or when the first S8 requirement is started. A failure there reads
  "expected update", not "regression" -- check whether a stage genuinely
  started before touching the rule.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Mix.Tasks.Letflow.CheckDeferralStaleness, as: Check
  alias Mix.Tasks.Letflow.CheckRequirementsRegistration, as: Registration

  @project_root Path.expand("../../..", __DIR__)
  @live_corpus Path.join(@project_root, "docs/requirements.yaml")

  # ------------------------------------------------------------------
  # Fixture construction
  # ------------------------------------------------------------------

  @stages_section [
                    "stages:",
                    "  - id: S1",
                    "    name: Runtime skeleton",
                    "  - id: S4",
                    "    name: API surface",
                    "  - id: S7",
                    "    name: Not yet expanded",
                    "  - id: S8",
                    "    name: Multi-tenant hardening",
                    "  - id: S9",
                    "    name: Mobile",
                    "  - id: S10",
                    "    name: A stage whose id has S1 as a prefix",
                    ""
                  ]
                  |> Enum.join("\n")

  defp doc(body), do: @stages_section <> "requirements:\n" <> body

  defp req(id, fields) do
    Enum.join(["  - id: " <> id | Enum.map(fields, &("    " <> &1))], "\n") <> "\n"
  end

  # A normally registered requirement: carries an `impl_order` field, so the
  # registration module classifies it :registered and it is never a deferral.
  defp registered(id, stage, status) do
    req(id, ["stage: #{stage}", "status: #{status}", "impl_order: 7"])
  end

  # A deferred requirement: the marker form. `rationale` is the text that
  # follows `UNREGISTERED` and is what parse_scope/1 reads.
  defp deferred(id, stage, status, rationale) do
    req(id, [
      "stage: #{stage}",
      "status: #{status}",
      "# impl_order: UNREGISTERED #{rationale}"
    ])
  end

  defp audit(body), do: Check.audit(doc(body))

  defp deferral(result, id), do: Enum.find(result.deferrals, &(&1.id == id))
  defp stage_facts(result, stage), do: Enum.find(result.stages, &(&1.stage == stage))
  defp rules(result), do: result.violations |> Enum.map(& &1.rule) |> Enum.sort()
  defp for_rule(result, rule), do: Enum.filter(result.violations, &(&1.rule == rule))
  defp rendered(result), do: result |> Check.render() |> IO.iodata_to_binary()

  defp verdicts(result) do
    Map.new(result.deferrals, fn d -> {d.id, d.verdict} end)
  end

  # ==================================================================
  # normalise_status/1 -- the totality function (S4, I7)
  # ==================================================================

  describe "normalise_status/1" do
    test "F-STATUS-TOKEN -- every declared status maps to its atom" do
      assert Check.normalise_status("pending") == :pending
      assert Check.normalise_status("in_progress") == :in_progress
      assert Check.normalise_status("done") == :done
      assert Check.normalise_status("blocked") == :blocked
      assert Check.normalise_status("cancelled") == :cancelled
      assert Check.normalise_status("  done  ") == :done
    end

    test "F-STATUS-TRAILING-COMMENT -- first token only, not rest-of-line (MS4)" do
      # Copied verbatim from the real corpus, where 8 of 115 status lines
      # carry a trailing comment. A rest-of-line extractor turns all 8 into
      # :unknown and reds this gate on day one for a non-reason.
      assert Check.normalise_status("cancelled  # MVP-1 milestone dropped, see REQ-101's note") ==
               :cancelled

      assert Check.normalise_status("done  # landed in PR #446") == :done
    end

    test "F-STATUS-UNKNOWN-TOTAL -- anything else is :unknown, never a default (I7)" do
      assert Check.normalise_status(nil) == :unknown
      assert Check.normalise_status("") == :unknown
      assert Check.normalise_status("donee") == :unknown
      assert Check.normalise_status("DONE") == :unknown
      assert Check.normalise_status("in-progress") == :unknown
    end
  end

  # ==================================================================
  # stage_activity/1 -- the section 3.3 ruling, pinned value by value
  # ==================================================================

  describe "stage_activity/1 -- the activity ruling" do
    defp activity_of(status) do
      result = audit(registered("REQ-900", "S4", status))
      stage_facts(result, "S4")
    end

    test "F-DONE-IS-ACTIVE -- :done confers activity (MS3, the mandatory mutant)" do
      facts = activity_of("done")

      assert facts.activity == :active
      assert facts.witnesses == ["REQ-900"]
    end

    test "F-IN-PROGRESS-IS-ACTIVE -- :in_progress confers activity" do
      assert activity_of("in_progress").activity == :active
    end

    test "F-BLOCKED-IS-ACTIVE -- :blocked confers activity (design OQ-1)" do
      # OQ-1 ruled `blocked` IN, against the Step-1 recommendation, on the
      # asymmetric-cost argument. Reversing that ruling is one token in
      # @active_statuses and flipping this test -- deliberately loud.
      assert activity_of("blocked").activity == :active
    end

    test "F-PENDING-NOT-ACTIVE -- :pending does not confer activity (MS2)" do
      facts = activity_of("pending")

      assert facts.activity == :inactive
      assert facts.witnesses == []
    end

    test "F-CANCELLED-NOT-ACTIVE -- abandonment is not activity (MS1)" do
      facts = activity_of("cancelled")

      assert facts.activity == :inactive
      assert facts.witnesses == []
    end

    test "F-UNKNOWN-NOT-ACTIVE -- an unrecognised status confers nothing" do
      assert activity_of("donee").activity == :inactive
    end

    test "F-EMPTY-STAGE-INACTIVE -- a stage with no requirements is absent, by rule" do
      # S7 is declared in the stages section and holds no requirement. It is
      # :inactive by the same rule as everything else -- the empty set holds
      # no active status -- and produces no violation of any kind.
      result = audit(registered("REQ-900", "S4", "done"))

      assert stage_facts(result, "S7") == nil
      assert Enum.map(result.stages, & &1.stage) == ["S4"]
      assert result.violations == []
    end

    test "F-STAGE-EXACT-MATCH -- S10 work must not activate S1 (MS13)" do
      body =
        registered("REQ-900", "S10", "done") <>
          deferred("REQ-901", "S1", "pending", "-- waits on the S1 kernel")

      result = audit(body)

      assert stage_facts(result, "S10").activity == :active
      assert stage_facts(result, "S1").activity == :inactive
      assert deferral(result, "REQ-901").verdict == :legitimate
      assert result.violations == []
    end

    test "F-STAGE-EXACT-MATCH-REVERSE -- S1 work must not activate S10 (MS13)" do
      body =
        registered("REQ-900", "S1", "done") <>
          deferred("REQ-901", "S10", "pending", "-- waits on the S10 kernel")

      result = audit(body)

      assert stage_facts(result, "S1").activity == :active
      assert stage_facts(result, "S10").activity == :inactive
      assert deferral(result, "REQ-901").verdict == :legitimate
      assert result.violations == []
    end
  end

  # ==================================================================
  # S1 / S2 -- the staleness verdict itself
  # ==================================================================

  describe "staleness verdicts (S1, S2)" do
    test "F-STALE-BASIC -- deferred in a stage with a done sibling is STALE" do
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on the S8 note above")

      result = audit(body)
      d = deferral(result, "REQ-901")

      assert d.verdict == :stale
      assert d.scope == :stage_scoped
      assert result.stale_count == 1
      assert result.deferral_count == 1

      assert [v] = for_rule(result, "S1")
      assert v.id == "REQ-901"
      assert v.line == d.line
      assert v.message =~ "STALE deferral"
      assert v.message =~ "stage S4 is ACTIVE"
      assert v.message =~ "REQ-900 (done)"
    end

    test "F-LEGIT-BASIC -- deferred in an all-pending stage is LEGITIMATE" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- waits on the S8 kernel")

      result = audit(body)

      assert deferral(result, "REQ-901").verdict == :legitimate
      assert result.stale_count == 0
      assert result.deferral_count == 1
      assert result.violations == []
    end

    test "F-STALE-EXITS -- a stale deferral is a violation, not just a roster line (MS11)" do
      # Design MS11: demoting S1 to a printed advisory makes the whole gate a
      # report nobody's exit code depends on -- ISS-0258's own root cause one
      # level up. The violation list is the exit-code-bearing surface.
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      refute result.violations == [],
             "a stale deferral must produce a violation, not merely a printed verdict"

      assert rules(result) == ["S1"]
    end

    test "F-LEGIT-NEVER-GATES -- a legitimate deferral never gates, at any count (I4)" do
      body =
        Enum.map_join(1..5, "", &deferred("REQ-90#{&1}", "S8", "pending", "-- waits on S8"))

      result = audit(body)

      assert result.deferral_count == 5
      assert result.stale_count == 0
      assert result.violations == []
    end

    test "F-DEFERRED-NO-STAGE -- no `stage:` is undecidable and gates (S2, MS12)" do
      body =
        registered("REQ-900", "S4", "done") <>
          req("REQ-901", ["status: pending", "# impl_order: UNREGISTERED -- no stage at all"])

      result = audit(body)
      d = deferral(result, "REQ-901")

      assert d.stage == nil
      assert d.verdict == :undecidable
      refute d.verdict == :legitimate

      assert [v] = for_rule(result, "S2")
      assert v.id == "REQ-901"
      assert v.message =~ "no `stage:`"
      assert v.message =~ "undecidable"
    end

    test "F-SELF-EXCLUSION -- a deferral does not activate its own stage (MS10)" do
      # The only non-pending requirement in S4 is the deferred entry itself.
      # Without self-exclusion it activates its own stage and flags itself --
      # an unfixable red.
      body = deferred("REQ-900", "S4", "done", "-- deferred but itself done")

      result = audit(body)
      d = deferral(result, "REQ-900")

      assert d.verdict == :legitimate
      assert result.violations == []

      # Section 3.5's residual: the anomaly is annotated rather than judged.
      assert rendered(result) =~ "(NOTE: deferred entry is itself done)"
    end

    test "F-SELF-EXCLUSION-NOT-GAMEABLE -- two deferrals do not excuse each other" do
      body =
        deferred("REQ-900", "S4", "done", "-- deferred but itself done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      assert deferral(result, "REQ-900").verdict == :legitimate
      assert deferral(result, "REQ-901").verdict == :stale
      assert [v] = for_rule(result, "S1")
      assert v.id == "REQ-901"
      assert v.message =~ "REQ-900 (done)"
    end
  end

  # ==================================================================
  # The historical corpus -- the one real-world signal this gate has
  # ==================================================================

  describe "the historical corpus at 75f553d" do
    # Re-derived from `git show 75f553d:docs/requirements.yaml` rather than
    # inherited: the 21 pre-PR#495 deferrals were 9 x S8 + 4 x S9 + 8 x S4,
    # and the stage/status cross-tab at that commit was
    #   S4  10 done, 21 pending, 2 cancelled
    #   S8  9 pending, 1 cancelled
    #   S9  4 pending
    # So 13 were legitimate and 8 (the S4 ones, whose rationale pointed at
    # the wrong stage) were genuinely stale weeks before anyone noticed and
    # registered them by hand. Asserted as ONE group on purpose: a rule that
    # gets one half right and the other wrong is invisible to either half
    # alone.
    @historical_rationale "-- see the S8 note above"

    defp historical_corpus do
      s8_deferred =
        Enum.map_join(
          115..123,
          "",
          &deferred("REQ-#{&1}", "S8", "pending", @historical_rationale)
        )

      s8_cancelled = registered("REQ-114", "S8", "cancelled")

      s9_deferred =
        Enum.map_join(
          124..127,
          "",
          &deferred("REQ-#{&1}", "S9", "pending", @historical_rationale)
        )

      s4_deferred =
        Enum.map_join(
          128..135,
          "",
          &deferred("REQ-#{&1}", "S4", "pending", @historical_rationale)
        )

      s4_done = Enum.map_join(201..210, "", &registered("REQ-#{&1}", "S4", "done"))
      s4_pending = Enum.map_join(301..313, "", &registered("REQ-#{&1}", "S4", "pending"))
      s4_cancelled = Enum.map_join(401..402, "", &registered("REQ-#{&1}", "S4", "cancelled"))

      s8_cancelled <>
        s8_deferred <> s9_deferred <> s4_done <> s4_pending <> s4_cancelled <> s4_deferred
    end

    test "F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE -- the 13/8 split (MS1, MS2, MS3)" do
      result = audit(historical_corpus())
      by_id = verdicts(result)

      legitimate = for id <- 115..127, do: "REQ-#{id}"
      stale = for id <- 128..135, do: "REQ-#{id}"

      assert result.deferral_count == 21

      for id <- legitimate do
        assert by_id[id] == :legitimate, "#{id} (S8/S9, inactive stage) must be legitimate"
      end

      for id <- stale do
        assert by_id[id] == :stale, "#{id} (S4, 10 done siblings) must be stale"
      end

      assert result.stale_count == 8

      assert stage_facts(result, "S8").activity == :inactive
      assert stage_facts(result, "S9").activity == :inactive
      assert stage_facts(result, "S4").activity == :active

      assert rules(result) == List.duplicate("S1", 8)
      assert Enum.map(for_rule(result, "S1"), & &1.id) |> Enum.sort() == stale
    end
  end

  # ==================================================================
  # S4 -- status parsing and the totality defence
  # ==================================================================

  describe "status parsing (S4)" do
    test "F-STATUS-TRAILING-COMMENT -- a commented `done` still activates (MS4)" do
      # Two-way discriminator. Under a rest-of-line extractor REQ-900 becomes
      # :unknown, which BOTH fires a spurious S4 AND un-activates S4, so the
      # real stale deferral reads legitimate.
      body =
        req("REQ-900", ["stage: S4", "status: done  # landed in PR #446", "impl_order: 7"]) <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      assert result.statuses["REQ-900"] == :done
      assert for_rule(result, "S4") == []
      assert stage_facts(result, "S4").activity == :active
      assert deferral(result, "REQ-901").verdict == :stale
    end

    test "F-STATUS-RAW-TOKEN -- the parser stores the first token, not rest-of-line (MS4)" do
      # Closes a coverage hole found by measurement at Step 4. The trailing-
      # comment trap is defended TWICE -- `@status_re` in the parser and the
      # token split in `normalise_status/1` -- so mutating `@status_re` alone
      # is absorbed by the second layer and no behavioural test can see it.
      # The raw stored token is the only observable that distinguishes them,
      # and design D4 states explicitly that this field is stored raw.
      body =
        req("REQ-900", [
          "stage: S4",
          "status: cancelled  # MVP-1 milestone dropped, see REQ-101's note",
          "impl_order: 7"
        ])

      assert [entry] = Registration.scan(doc(body)).entries
      assert entry.status == "cancelled"
      assert Check.normalise_status(entry.status) == :cancelled
    end

    test "F-STATUS-BLOCK-NOTE -- an unattributed `status:` is not swept in (MS5)" do
      # A 2-space `status:` line between entries stands for any block-level or
      # mis-indented key. The >= 4-space attribution rule is what keeps it out
      # of REQ-900's entry. Two-way discriminator: dropping that rule both
      # silences the real S4 violation and activates S4, flipping REQ-901.
      body =
        req("REQ-900", ["stage: S4", "impl_order: 7"]) <>
          "  status: done\n" <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      assert result.statuses["REQ-900"] == :unknown
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert stage_facts(result, "S4").activity == :inactive
      assert deferral(result, "REQ-901").verdict == :legitimate
    end

    test "F-UNKNOWN-STATUS-FAILS -- `status: donee` is :unknown and gates (MS6)" do
      result = audit(registered("REQ-900", "S4", "donee"))

      assert result.statuses["REQ-900"] == :unknown
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert v.message =~ "unrecognised status"
      assert v.message =~ "donee"
      assert v.message =~ "failing bucket"
    end

    test "F-TYPO-DOES-NOT-DEACTIVATE -- a typo'd sibling reds the run (MS6)" do
      # The silent-absorption failure: if `donee` were absorbed into :pending,
      # S4 would go quiet AND inactive, and REQ-901 would read legitimate on a
      # green run. The run must be red instead.
      body =
        registered("REQ-900", "S4", "donee") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      result = audit(body)

      refute result.violations == [], "a typo'd status must never produce a quiet green run"
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert deferral(result, "REQ-901").verdict == :legitimate
      assert deferral(result, "REQ-901").reason =~ "inactive"
    end

    test "F-NO-STATUS-LINE -- an entry with no `status:` at all is :unknown (S4)" do
      result = audit(req("REQ-900", ["stage: S4", "impl_order: 7"]))

      assert result.statuses["REQ-900"] == :unknown
      assert [v] = for_rule(result, "S4")
      assert v.id == "REQ-900"
      assert v.message =~ "nil"
    end

    test "F-S4-ALL-ENTRIES -- S4 applies to non-deferred entries too (design OQ-2)" do
      body =
        registered("REQ-900", "S8", "donee") <>
          deferred("REQ-901", "S8", "pending", "-- waits on S8")

      result = audit(body)

      assert deferral(result, "REQ-901").verdict == :legitimate
      assert Enum.map(for_rule(result, "S4"), & &1.id) == ["REQ-900"]
    end
  end

  # ==================================================================
  # S3 / D6 -- the blocked-by escape hatch
  # ==================================================================

  describe "parse_scope/1 -- the hatch grammar" do
    test "F-HATCH-GRAMMAR -- anchored, well-formed, with free text" do
      assert Check.parse_scope("-- blocked-by: REQ-042 -- waiting on the token kernel") ==
               {:blocked_by, "REQ-042"}

      assert Check.parse_scope("blocked-by: REQ-042 -- waiting on the token kernel") ==
               {:blocked_by, "REQ-042"}
    end

    test "F-HATCH-ANCHOR -- a mid-rationale mention is not a hatch (MS7)" do
      # ISS-0231's M8 absorption bug wearing this issue's clothes: prose that
      # merely mentions the form must not suppress a real staleness.
      assert Check.parse_scope("-- unlike the blocked-by: REQ-042 cases, this waits on S8") ==
               :stage_scoped
    end

    test "F-HATCH-MALFORMED -- near-misses never become a silent hatch" do
      assert Check.parse_scope("-- blocked-by: REQ_042 -- malformed id") == :stage_scoped
      assert Check.parse_scope("-- blocked-by: -- no id at all") == :stage_scoped
      assert Check.parse_scope("-- blockedby: REQ-042 -- no hyphen") == :stage_scoped
      assert Check.parse_scope(nil) == :stage_scoped
      assert Check.parse_scope("-- see the S8 note above") == :stage_scoped
    end

    test "F-HATCH-NO-RATIONALE -- a bare id is rejected as a hatch (MS16)" do
      # D6's fourth property: free text is still required, so R3's spirit --
      # a human-readable reason -- survives the hatch instead of being
      # replaced by it.
      assert Check.parse_scope("-- blocked-by: REQ-042") == :stage_scoped
      assert Check.parse_scope("-- blocked-by: REQ-042 --") == :stage_scoped
      assert Check.parse_scope("blocked-by: REQ-042") == :stage_scoped
    end
  end

  describe "the blocked-by hatch (S3)" do
    defp hatch_corpus(blocker_status, rationale) do
      registered("REQ-900", "S4", "done") <>
        registered("REQ-042", "S4", blocker_status) <>
        deferred("REQ-901", "S4", "pending", rationale)
    end

    test "F-HATCH-BASIC -- a live hatch survives an active stage" do
      result = audit(hatch_corpus("pending", "-- blocked-by: REQ-042 -- waits on the kernel"))
      d = deferral(result, "REQ-901")

      assert d.scope == {:blocked_by, "REQ-042"}
      assert d.verdict == :legitimate
      assert d.reason =~ "still open"
      assert stage_facts(result, "S4").activity == :active
      assert result.violations == []
    end

    test "F-HATCH-BLOCKER-DONE -- the hatch expires when the blocker is done (MS9)" do
      # The second mandatory mutant. The hatch is not an exemption; it is a
      # machine-checkable assertion that goes stale on its own.
      result = audit(hatch_corpus("done", "-- blocked-by: REQ-042 -- waits on the kernel"))
      d = deferral(result, "REQ-901")

      assert d.verdict == :stale
      assert d.reason =~ "EXPIRED"

      assert rules(result) == ["S1", "S3"]
      assert [v] = for_rule(result, "S3")
      assert v.id == "REQ-901"
      assert v.message =~ "REQ-042"
      assert v.message =~ "EXPIRED"
      assert v.message =~ "done"
    end

    test "F-HATCH-BLOCKER-CANCELLED -- a cancelled blocker expires it too (MS9)" do
      result = audit(hatch_corpus("cancelled", "-- blocked-by: REQ-042 -- waits on the kernel"))
      d = deferral(result, "REQ-901")

      assert d.verdict == :stale
      assert [v] = for_rule(result, "S3")
      assert v.message =~ "cancelled"
    end

    test "F-HATCH-DANGLING -- an absent blocker is rejected, not honoured (MS8)" do
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- blocked-by: REQ-999 -- waits on a ghost")

      result = audit(body)

      assert [v] = for_rule(result, "S3")
      assert v.id == "REQ-901"
      assert v.message =~ "REQ-999"
      assert v.message =~ "not present in the corpus"

      # The unusable hatch does not suppress the stage-activity judgement:
      # the entry is judged on stage activity alone, and the run is red.
      refute result.violations == []
      assert deferral(result, "REQ-901").verdict == :stale
      assert rules(result) == ["S1", "S3"]
    end

    test "F-HATCH-SELF -- naming your own id is an unfalsifiable self-license" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-901 -- waits on itself")

      result = audit(body)

      assert [v] = for_rule(result, "S3")
      assert v.id == "REQ-901"
      assert v.message =~ "own id"
      refute result.violations == []
    end

    test "F-HATCH-INVALID-STILL-JUDGED -- an unusable hatch falls back to stage activity" do
      # Characterises REVIEWER MINOR-1: with an inactive stage the roster's
      # one-word verdict column reads LEGITIMATE while S3 independently gates.
      # There is no gate hole -- the run is red -- but the column and the
      # outcome disagree. Pinned so a later relabelling is a deliberate change.
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-999 -- waits on a ghost")

      result = audit(body)

      assert deferral(result, "REQ-901").verdict == :legitimate
      assert deferral(result, "REQ-901").reason =~ "unusable"
      assert rules(result) == ["S3"]
      refute result.violations == [], "S3 gates even when the roster column reads LEGITIMATE"
    end
  end

  # ==================================================================
  # S6 -- the hatch graph is acyclic
  # ==================================================================

  describe "hatch cycles (S6)" do
    test "F-HATCH-CYCLE-2 -- two deferrals may not license each other (MS14)" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-902 -- waits on B") <>
          deferred("REQ-902", "S8", "pending", "-- blocked-by: REQ-901 -- waits on A")

      result = audit(body)

      assert [v] = for_rule(result, "S6")
      assert v.message =~ "cycle"
      assert v.message =~ "REQ-901"
      assert v.message =~ "REQ-902"
      assert v.message =~ "never expires"

      # Both members read :legitimate individually -- that is exactly why the
      # cycle needs its own file-level rule (design section 6.2).
      assert verdicts(result) == %{"REQ-901" => :legitimate, "REQ-902" => :legitimate}
      refute result.violations == []
    end

    test "F-HATCH-CYCLE-3 -- a three-node chain, so pairs cannot be special-cased" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-902 -- waits on B") <>
          deferred("REQ-902", "S8", "pending", "-- blocked-by: REQ-903 -- waits on C") <>
          deferred("REQ-903", "S8", "pending", "-- blocked-by: REQ-901 -- waits on A")

      result = audit(body)

      assert [v] = for_rule(result, "S6")
      assert v.message =~ "REQ-901 -> REQ-902 -> REQ-903 -> REQ-901"
    end

    test "F-HATCH-CHAIN-NO-CYCLE -- an acyclic chain is not a cycle" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- blocked-by: REQ-902 -- waits on B") <>
          deferred("REQ-902", "S8", "pending", "-- blocked-by: REQ-900 -- waits on the root")

      result = audit(body)

      assert for_rule(result, "S6") == []
      assert result.violations == []
    end
  end

  # ==================================================================
  # S5 -- the corpus is non-empty and shaped
  # ==================================================================

  describe "corpus shape (S5)" do
    test "F-NO-REQUIREMENTS-KEY -- no `requirements:` key is never a green pass (MS15)" do
      result = Check.audit("nothing: here\nother: stuff\n")

      assert result.deferral_count == 0
      refute result.violations == [], "a scan that finds nothing must never pass silently"

      assert [v] = for_rule(result, "S5")
      assert v.id == nil
      assert v.message =~ "zero entries"
    end

    test "F-EMPTY-SECTION -- `requirements:` with zero entries is an S5 violation (MS15)" do
      result = Check.audit(@stages_section <> "requirements:\n")

      assert result.deferral_count == 0
      assert [v] = for_rule(result, "S5")
      assert v.message =~ "zero entries"
    end

    test "F-SHAPELESS-CORPUS -- entries but no recognised status anywhere is S5" do
      body =
        req("REQ-900", ["stage: S4", "impl_order: 7"]) <>
          req("REQ-901", ["stage: S4", "impl_order: 8"])

      result = audit(body)

      assert Enum.any?(for_rule(result, "S5"), &(&1.message =~ "no entry in the corpus"))
    end

    test "F-DUPLICATE-ID-DENOMINATOR -- characterises REVIEWER MINOR-2" do
      # Duplicate ids collapse in the `statuses` map, so the totality line's
      # denominator under-reports. Gated upstream by the registration check's
      # R4, which runs first in the `letflow.check` alias. Pinned as a known
      # characteristic rather than claimed as correct.
      body = registered("REQ-900", "S4", "done") <> registered("REQ-900", "S4", "pending")

      result = audit(body)

      assert map_size(result.statuses) == 1
      assert Registration.scan(doc(body)).entry_count == 2

      assert Enum.any?(Registration.scan(doc(body)).violations, &(&1.rule == "R4")),
             "the registration check is what gates duplicate ids"
    end
  end

  # ==================================================================
  # render/1 -- the always-printed blocks
  # ==================================================================

  describe "render/1" do
    test "F-ROSTER-EXPLAINS -- a stale roster names id, stage and a witness" do
      body =
        registered("REQ-900", "S4", "done") <>
          deferred("REQ-901", "S4", "pending", "-- waits on something")

      out = body |> audit() |> rendered()

      assert out =~ "STAGE ACTIVITY (derived, always reported, never gates):"
      assert out =~ "S4  ACTIVE"
      assert out =~ "DEFERRALS (legitimate ones are reported and never gate):"
      assert out =~ "REQ-901"
      assert out =~ "STALE"
      assert out =~ "REQ-900 (done)"
      assert out =~ "VIOLATIONS (each one fails the run):"
      assert out =~ "[S1] REQ-901"
      assert out =~ "1 deferred of 2 entries; 1 stale"
    end

    test "F-ROSTER-GREEN -- a legitimate roster explains itself and shows no violations" do
      body =
        registered("REQ-900", "S8", "pending") <>
          deferred("REQ-901", "S8", "pending", "-- waits on the S8 kernel")

      out = body |> audit() |> rendered()

      assert out =~ "S8  INACTIVE"
      assert out =~ "REQ-901"
      assert out =~ "LEGITIMATE"
      assert out =~ "stage S8 is inactive"
      assert out =~ "1 deferred of 2 entries; 0 stale"
      refute out =~ "VIOLATIONS"
    end

    test "F-ROSTER-EMPTY -- an empty roster still prints both blocks" do
      out = registered("REQ-900", "S4", "done") |> audit() |> rendered()

      assert out =~ "DEFERRALS (legitimate ones are reported and never gate): none"
      assert out =~ "0 deferred of 1 entries; 0 stale"
      refute out =~ "VIOLATIONS"
    end
  end

  # ==================================================================
  # T-LIVE-* : the real docs/requirements.yaml.
  # Read-only, unpinned to counts. Per design section 7.2 these are
  # over-firing guards; genuine signal only for MS1-MS5.
  # ==================================================================

  describe "T-LIVE-* -- the real docs/requirements.yaml" do
    setup do
      %{result: @live_corpus |> File.read!() |> Check.audit()}
    end

    test "T-LIVE-GREEN -- the real corpus produces zero violations", %{result: result} do
      assert result.violations == [],
             "live corpus violations: " <>
               Enum.map_join(result.violations, "\n", &"[#{&1.rule}] #{&1.id}: #{&1.message}")
    end

    test "T-LIVE-STATUS-TOTAL -- no entry resolves to :unknown (MS4, MS5)", %{result: result} do
      unknown = for {id, :unknown} <- result.statuses, do: id

      assert unknown == [], "entries with an unrecognised status: #{inspect(unknown)}"
      assert map_size(result.statuses) > 0
    end

    test "T-LIVE-ACTIVITY -- S0..S4, S8, S9 active (MS1, MS2, MS3)", %{result: result} do
      # Design OQ-5: this pins the SET, not the counts, which move with every
      # merge. It will change legitimately when S5/S6/S7 are expanded or when
      # S8 starts -- a failure here means "expected update", not "regression".
      #
      # UPDATE (WF03-ISS0264-20260822, 2026-08-22): OQ-5's predicted event
      # happened -- S8 and S9 both went active tonight (real in_progress/done
      # requirements registered under REQ-115..139, per
      # docs/migration/decisions/0011-frontend-ownership.md and
      # 0012-mobile-tier-stack.md). New true values, re-derived directly from
      # Mix.Tasks.Letflow.CheckDeferralStaleness.audit/1 against the live
      # docs/requirements.yaml, confirmed independently by CODE-DESIGNER and
      # ISSUE-FIXER: active == every stage S0..S4, S8, S9; inactive == [].
      # This is a test-data-only update -- the detector logic in
      # lib/mix/tasks/letflow.check_deferral_staleness.ex is unchanged and
      # correct; it is doing exactly its job by catching this drift. The next
      # time this assertion fails, treat it the same way: re-derive the true
      # values with audit/1 against the live corpus, don't guess, and extend
      # this comment rather than replacing it.
      #
      # UPDATE (S5 expansion, 2026-08-23): OQ-5's *other* predicted event
      # happened -- "it will change legitimately when S5/S6/S7 are expanded."
      # S5 was expanded into REQ-148..REQ-175 (28 requirements, all `pending`)
      # against docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md.
      # Because every one of them is `pending`, and `pending` does not confer
      # activity (F-PENDING-NOT-ACTIVE above), S5 is now a *present but
      # inactive* stage -- the first stage in this corpus to occupy that state.
      # Note the distinction from F-EMPTY-STAGE-INACTIVE: a stage with no
      # requirements is absent from result.stages entirely, whereas S5 is
      # present and :inactive. `active` is therefore unchanged; only `inactive`
      # moves, from [] to ["S5"].
      #
      # Re-derived, not guessed: `mix run -e` calling
      # Mix.Tasks.Letflow.CheckDeferralStaleness.audit/1 against the live
      # docs/requirements.yaml returned active == ["S0","S1","S2","S3","S4",
      # "S8","S9"], inactive == ["S5"], violations == 0. Test-data-only
      # update; the detector in lib/mix/tasks/letflow.check_deferral_staleness.ex
      # is unchanged and was doing exactly its job. S5 joins `active` the
      # moment any of REQ-148..175 goes in_progress/done/blocked.
      # UPDATE (REQ-148 done, 2026-08-24): S5 is now active -- REQ-148 (stage S5,
      # status done) went in on WF02-REQ148-20260824. Per the detector rule,
      # a stage is active once any requirement assigned to it has status
      # done/in_progress/blocked. S5 moves from inactive to active.
      # Re-derived: active == ["S0","S1","S2","S3","S4","S5","S8","S9"],
      # inactive == []. Test-data-only update; detector logic unchanged.
      #
      # UPDATE (S6 expansion, 2026-08-29): OQ-5's predicted event happened a
      # third time -- S6 was expanded via WF-01 into REQ-176..178, REQ-181..184
      # (7 requirements, all `pending`) against
      # docs/migration/stage-6-operational-cross-cutting.md. Same rule as S5's
      # own expansion: `pending` does not confer activity (F-PENDING-NOT-ACTIVE),
      # so S6 is present but :inactive, same state S5 passed through before
      # REQ-148 went done. `active` is unchanged; `inactive` moves from [] to
      # ["S6"]. Re-derived, not guessed: confirmed live via
      # `mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs`
      # itself surfacing `left: ["S6"], right: []` on this exact assertion.
      # S6 joins `active` the moment any of REQ-176/177/178/181/182/183/184
      # goes in_progress/done/blocked.
      #
      # UPDATE (REQ-176 done, 2026-08-29): the predicted event happened
      # immediately -- REQ-176 (stage S6, status done) landed in this same
      # WF02-REQ176-20260829 run. Per the detector rule, S6 moves from
      # inactive to active, same transition S5 made for REQ-148. Re-derived,
      # not guessed: confirmed live via CI surfacing
      # `left: [...,"S6",...], right: [...]` (S6 missing from `active`) on
      # this exact assertion. `active` gains "S6"; `inactive` returns to [].
      #
      # UPDATE (S7 expansion, 2026-08-31): OQ-5's predicted event happened a
      # fourth time -- S7 (simulation-and-uat-parity) was expanded via WF-01
      # into REQ-205..REQ-210 (all `pending`) per this stage's own scenario
      # corpus. Same rule as S5's and S6's own expansions: `pending` does not
      # confer activity (F-PENDING-NOT-ACTIVE), so S7 is present but
      # :inactive, the same state S5/S6 passed through before their first
      # requirement went done. `active` is unchanged; `inactive` moves from
      # [] to ["S7"]. Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run -e` calling
      # Mix.Tasks.Letflow.CheckDeferralStaleness.audit/1 (passed
      # File.read!("docs/requirements.yaml") -- audit/1 takes file content,
      # not a path) against the live corpus, returning
      # active == ["S0","S1","S2","S3","S4","S5","S6","S8","S9"],
      # inactive == ["S7"], violations == 0. Test-data-only update; the
      # detector in lib/mix/tasks/letflow.check_deferral_staleness.ex is
      # unchanged and correct -- it caught this drift exactly as designed.
      # S7 joins `active` the moment any of REQ-205..210 goes
      # in_progress/done/blocked.
      #
      # UPDATE (REQ-205 done, 2026-08-31): the predicted event happened --
      # REQ-205 (stage S7, status done) landed in WF02-REQ205-20260831. Per
      # the detector rule, S7 moves from inactive to active, same transition
      # S5/S6 made for their own first done requirement. Re-derived, not
      # guessed: confirmed live via `MIX_ENV=test mix run -e` calling
      # Mix.Tasks.Letflow.CheckDeferralStaleness.audit/1 against the live
      # docs/requirements.yaml, returning
      # active == ["S0","S1","S2","S3","S4","S5","S6","S7","S8","S9"],
      # inactive == [], violations == 0. Test-data-only update; the detector
      # is unchanged and correct.
      # UPDATE (S10 expansion, 2026-09-09): OQ-5's predicted event happened a
      # fifth time -- S10 (bilimbaga-vertical) was expanded via WF-01 into
      # REQ-295..REQ-302 (8 requirements, all `pending`), the entity-storage
      # batch for docs/migration/decisions/0023-entity-storage-hybrid.md.
      # Same rule as the S5/S6/S7 expansions: `pending` does not confer
      # activity (F-PENDING-NOT-ACTIVE), so S10 is present but :inactive --
      # the same state S5, S6 and S7 each passed through before their first
      # requirement landed. `active` is unchanged; `inactive` moves from []
      # to ["S10"]. Re-derived, not guessed: `MIX_ENV=test mix run -e`
      # calling Mix.Tasks.Letflow.CheckDeferralStaleness.audit/1 (passed
      # File.read!("docs/requirements.yaml") -- audit/1 takes file content,
      # not a path) against the live corpus returned
      # active == ["S0","S1","S2","S3","S4","S5","S6","S7","S8","S9"],
      # inactive == ["S10"], violations == 0. Test-data-only update; the
      # detector in lib/mix/tasks/letflow.check_deferral_staleness.ex is
      # unchanged and correct -- it caught this drift exactly as designed.
      # S10 joins `active` the moment any of REQ-295..302 goes
      # in_progress/done/blocked, which for this batch means the moment
      # REQ-295 or REQ-302 (its two design roots) is picked up.
      #
      # UPDATE (WF02-REQ295-20260909): S10 moved from inactive to active
      # within the same merge window -- REQ-295 (stage S10, status done) is
      # the first S10 requirement to reach in_progress/done/blocked, same
      # transition every other stage made on its own first non-pending
      # requirement. `active` gains "S10"; `inactive` returns to [].
      # Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> Mix.Tasks.Letflow.CheckDeferralStaleness.audit()
      # against the live corpus, returning
      # active == ["S0","S1","S10","S2","S3","S4","S5","S6","S7","S8","S9"]
      # (String.< ordering puts "S10" before "S2"), inactive == [],
      # violations == 0. Test-data-only update; the detector in
      # lib/mix/tasks/letflow.check_deferral_staleness.ex is unchanged and
      # correct -- it caught this drift exactly as designed.
      #
      # UPDATE (S11 expansion, 2026-09-24): OQ-5's predicted event happened a
      # sixth time -- S11 (modular-platform architecture) was expanded via
      # WF-01 into REQ-400..REQ-416 (all `pending`) against
      # docs/migration/decisions/0039-platform-module-solution-layering.md.
      # Same rule as every prior stage's own expansion: `pending` does not
      # confer activity (F-PENDING-NOT-ACTIVE), so S11 is present but
      # :inactive, the same state every other stage passed through before its
      # first non-pending requirement. `active` is unchanged; `inactive`
      # moves from [] to ["S11"]. Re-derived, not guessed: `MIX_ENV=test mix
      # run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> Mix.Tasks.Letflow.CheckDeferralStaleness.audit()
      # against the live corpus, returning
      # active == ["S0","S1","S10","S2","S3","S4","S5","S6","S7","S8","S9"],
      # inactive == ["S11"], violations == []. Test-data-only update; the
      # detector in lib/mix/tasks/letflow.check_deferral_staleness.ex is
      # unchanged and correct -- it caught this drift exactly as designed.
      # S11 joins `active` the moment any of REQ-400..416 goes
      # in_progress/done/blocked (expected to be REQ-400 itself, shortly).
      #
      # UPDATE (2026-09-24, REQ-400 done): that predicted transition just
      # happened -- REQ-400 (S11's first requirement) flipped to `done` in
      # this same PR (#1805). Same rule as S10's own S10-joins-active update
      # above: `active` gains "S11", `inactive` returns to []. Re-derived
      # live in CI (not guessed): the assertion failure this produced
      # quoted active == [..., "S10", "S11", "S2", ...] (String.< ordering
      # puts "S11" between "S10" and "S2"), confirming S11 is now correctly
      # :active per the detector -- which is unchanged and correct, exactly
      # per this file's own established pattern.
      active = for s <- result.stages, s.activity == :active, do: s.stage
      inactive = for s <- result.stages, s.activity == :inactive, do: s.stage

      assert active == [
               "S0",
               "S1",
               "S10",
               "S11",
               "S2",
               "S3",
               "S4",
               "S5",
               "S6",
               "S7",
               "S8",
               "S9"
             ]

      assert inactive == []
    end

    test "T-LIVE-DEFERRED-COUNT -- the staleness rule is now load-bearing, not vacuous",
         %{result: result} do
      # NOT a permanent invariant -- the count is expected to move as the
      # corpus changes; what is asserted permanently is `stale_count == 0`.
      #
      # HISTORY. This test was named T-LIVE-DEFERRED-COUNT-IS-ZERO and
      # asserted `deferral_count == 0`, recording that S1/S2/S3/S6 were
      # VACUOUSLY green: the rule held only because no entry had ever
      # exercised it. Its own comment named the successor condition -- "a
      # future reader who adds a real deferral and sees this test change
      # knows the staleness rule has just become load-bearing, rather than
      # reading it as a regression." That is exactly what happened here, so
      # the test is renamed and re-pointed rather than deleted or relaxed.
      #
      # UPDATE (decision 0017, 2026-09-03): REQ-223 and REQ-224 are the
      # first real deferrals in the corpus. Both are `blocked-by:`-scoped to
      # REQ-222 (letflow-queue's read-only GET /tasks endpoint), which is
      # `pending`, so both are LEGITIMATE and neither is stale -- the rule
      # is now doing real work and returning green on its merits, not
      # vacuously. Re-derived, not guessed: confirmed live via
      # `LETFLOW_SECRETS_MASTER_KEY=... MIX_ENV=test mix run --no-start -e`
      # calling Mix.Tasks.Letflow.CheckDeferralStaleness.audit/1 against the
      # live docs/requirements.yaml, returning deferral_count == 2,
      # stale_count == 0, both deferrals verdict: :legitimate with
      # scope: {:blocked_by, "REQ-222"}. The detector is unchanged.
      #
      # UPDATE (decision 0020, 2026-09-09): the count moved from 2 to 10, which
      # is this test doing its job rather than a regression -- its own note
      # above says the count "is expected to move as the corpus changes; what
      # is asserted permanently is `stale_count == 0`". Record 0020's
      # requirement expansion (REQ-272..294) added 8 `blocked-by:`-scoped
      # deferrals: REQ-279 (-> REQ-276), REQ-283 (-> REQ-279), REQ-284
      # (-> REQ-286), REQ-290 (-> REQ-292), REQ-291 (-> REQ-284), REQ-292
      # (-> REQ-286), REQ-293 (-> REQ-284), REQ-294 (-> REQ-290), joining the
      # pre-existing REQ-223/224 (-> REQ-222). All 10 are verdict
      # :legitimate. Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 10, stale_count == 0. The detector is unchanged.
      #
      # This count drops as each blocker merges and the blocked entry is
      # registered; it rises again with any new deferral. `stale_count`,
      # however, must stay 0 -- that one IS the invariant.
      #
      # UPDATE (WF02-REQ286-20260909): the count dropped from 10 to 9,
      # exactly the mechanism this test's own comment above predicts.
      # Flipping REQ-286 to done expired both REQ-284's and REQ-292's
      # `blocked-by: REQ-286` deferrals. REQ-284 turned out to have no
      # live blocker left at all (its other dependency, REQ-273, was
      # already done) -- registered it properly in the queue (task 560,
      # GH#1145) rather than inventing a re-scope target, which is what
      # removed it from the deferred set entirely. REQ-292 still has two
      # live dependencies (REQ-290, REQ-291) and was re-scoped to
      # blocked-by: REQ-291 (not REQ-290, to avoid a blocked-by cycle
      # with REQ-290's own pre-existing REQ-292-scoped deferral) -- it
      # remains in the deferred set, still legitimate. Net: 10 - 1 = 9.
      # Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 9, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (WF02-REQ284-20260909): the count dropped from 9 to 8 by
      # the same mechanism again. Flipping REQ-284 to done expired both
      # REQ-291's and REQ-293's `blocked-by: REQ-284` deferrals. REQ-291
      # turned out to have no live blocker left at all (its other
      # dependency, REQ-288, was already done) -- registered it properly
      # in the queue (task 561, GH#1147) rather than inventing a re-scope
      # target, which is what removed it from the deferred set entirely.
      # REQ-293 still has two live dependencies (REQ-290, REQ-292) and
      # was re-scoped to blocked-by: REQ-290 (its first still-pending
      # dependency; no cycle risk since REQ-290 -> REQ-292 -> REQ-291,
      # and REQ-291 is now registered/non-deferred rather than looping
      # back). Net: 9 - 1 = 8. Re-derived, not guessed: confirmed live
      # via `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 8, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (WF02-REQ291-20260909): flipping REQ-291 to done expired
      # REQ-292's `blocked-by: REQ-291` deferral. REQ-292's remaining live
      # dependency is REQ-290, but REQ-292 -> REQ-290 could not point there
      # directly yet: REQ-290's own deferral was scoped to REQ-292 as a
      # workaround for its true dependency, REQ-289, being entirely absent
      # from this file (a genuine registration gap, not a design choice --
      # REQ-289 is queue task 544/GH#1100, with real implementation work
      # sitting unmerged on origin/feature/WF02-REQ289-20260909). Registered
      # REQ-289 as a `pending` entry (matching reality -- unmerged, not
      # done) to give REQ-290 a real blocker to point at directly, which
      # freed REQ-292 to point at REQ-290 without forming a cycle. New
      # chain: REQ-292 -> REQ-290 -> REQ-289 (linear, acyclic). REQ-291
      # itself dropped out of the deferred set (no longer deferred, it is
      # done), and REQ-289 entering the set as a fresh deferred-nothing
      # NON-deferred registered pending entry does not add to the deferred
      # count either (it carries no `blocked-by:` hatch of its own). Net:
      # one id (REQ-291) replaced by nothing in the set composition, count
      # unchanged at 8. Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 8, stale_count == 0, ids unchanged except
      # REQ-292's scope target (REQ-291 -> REQ-290) and REQ-290's scope
      # target (REQ-292 -> REQ-289) internally -- the id SET itself
      # (which entries are deferred) is unchanged, only their scope
      # targets moved. The detector is unchanged.
      #
      # UPDATE (WF02-REQ277-20260909): the count dropped from 8 to 7. REQ-279
      # carried its own `# impl_order: UNREGISTERED -- no live blocker
      # remains ...` comment with no `blocked-by:` clause, so it parsed as
      # scope: :stage_scoped (parse_scope/1's default for an UNREGISTERED
      # entry with no anchored blocked-by text) and counted as one of the 8 --
      # not because anything pointed AT it, but because IT was itself
      # deferred, unregistered. Once REQ-277 (the last of its three
      # dependencies REQ-276/277/278) landed, REQ-279 had no live blocker
      # left, and ORCH called register_task once $QUEUE_AUTH_TOKEN became
      # available this session, replacing the UNREGISTERED comment with a
      # real impl_order (562, GH#1151). That removes REQ-279 from the
      # deferred set entirely -- REQ-283's own `blocked-by: REQ-279`
      # deferral is untouched (REQ-279 is still `pending`, so REQ-283's
      # scope has not expired). Net: 8 - 1 = 7. Re-derived, not guessed:
      # confirmed live via `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 7, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (WF02-REQ279-20260909): the count dropped from 7 to 6.
      # Flipping REQ-279 to done (this requirement -- REQ-276/277/278's
      # completion test, deleting the literal-colour guard's web/src/pages/
      # exemption; npm run guards re-verified clean, no violation was
      # masked) expired REQ-283's `blocked-by: REQ-279` deferral. REQ-283's
      # other dependency, REQ-281, was already done -- no live blocker left
      # at all, so ORCH registered it properly (queue task 563, GH#1154)
      # rather than inventing a re-scope target, the same pattern used for
      # REQ-284 and REQ-291 earlier this session. That removes REQ-283 from
      # the deferred set entirely. Net: 7 - 1 = 6. Re-derived, not guessed:
      # confirmed live via `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 6, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (WF02-REQ289-20260909): the count dropped from 6 to 5.
      # REQ-290's own `# impl_order: UNREGISTERED -- blocked-by: REQ-289 --
      # ...` comment carried a real, live `blocked-by:` scope, so it counted
      # among the 6 as a `{:blocked_by, "REQ-289"}`-scoped deferral, not a
      # bare-UNREGISTERED one. Flipping REQ-289 to done (recovered a
      # genuinely prior, real implementation that had died before any
      # bookkeeping -- a 40-entry language-neutral conformance corpus for
      # Letflow.Engine.Expr, closing one found gap in null-literal coverage
      # via the full CODE-DESIGNER->...->RELEASE-VALIDATOR chain) expired
      # REQ-290's deferral. REQ-289 was REQ-290's only dependency -- no live
      # blocker left at all, so ORCH registered it properly (queue task
      # 572, GH#1168) rather than inventing a re-scope target, the same
      # pattern used repeatedly this session (REQ-279, REQ-283, REQ-284,
      # REQ-291). That removes REQ-290 from the deferred set entirely --
      # REQ-292/293/294's own `blocked-by: REQ-290` deferrals are untouched
      # (REQ-290 is still `pending`, so their scopes have not expired). Net:
      # 6 - 1 = 5. Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 5, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (WF02-REQ290-20260910): the count dropped from 5 to 4.
      # REQ-290's own completion expired REQ-292/293/294's `blocked-by:
      # REQ-290` deferrals -- all three went STALE the moment REQ-290
      # landed done, caught live by this run's own `mix
      # letflow.check_deferral_staleness` run (S1/S3 violations on all
      # three, real output quoted in the run history). REQ-292's other
      # two dependencies (REQ-286, REQ-291) were already done, so it had
      # no live blocker left at all -- registered it properly (queue task
      # 579, GH#1187) rather than inventing a re-scope target, the same
      # pattern used repeatedly this session (REQ-279, REQ-283, REQ-284,
      # REQ-289, REQ-291). That removes REQ-292 from the deferred set
      # entirely. REQ-293 and REQ-294 both still depend on REQ-292
      # (pending) -- re-scoped both to blocked-by: REQ-292. Net: 5 - 1 =
      # 4. Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 4, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (WF02-REQ292-20260910): the count dropped from 4 to 3.
      # REQ-292's own completion (queue task 579, GH#1187) made REQ-293's
      # stage-scoped deferral comment stale (S8 active) and expired
      # REQ-294's blocked-by: REQ-292 scope. REQ-293's other two
      # dependencies (REQ-284, REQ-290) were already done, so it had no
      # live blocker left at all -- registered it properly (queue task
      # 584, GH#1202) rather than inventing a re-scope target, the same
      # pattern REQ-292 itself used one step earlier. That removes REQ-293
      # from the deferred set entirely. REQ-294 still depends on REQ-293
      # (pending) -- re-scoped it to blocked-by: REQ-293. Net: 4 - 1 = 3.
      # Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 3, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (WF02-REQ293-20260910, Step Final): the count dropped from
      # 3 to 2. REQ-294's own `blocked-by: REQ-293` deferral hatch expired
      # when REQ-293 landed done, with no live REQ-NNN left to re-scope
      # to (S9 was independently active via REQ-124..127, all done) --
      # unlike a normal expiry, REQ-294 could not simply be registered as
      # "now unblocked and eligible" the way REQ-292/REQ-293 themselves
      # were, because owner: MOBILE-DEV stays dormant per CLAUDE.md's own
      # roster and apps/mobile/ does not exist. Registered it anyway
      # (queue task 585, GH#1205) purely to satisfy this checker's
      # mechanical requirement (its only two outs are register_task or a
      # live blocked-by; "owner is dormant" has no escape it recognizes),
      # then immediately locked and released the queue task with
      # status: "blocked" so it stays permanently excluded from
      # get_next_task's own eligibility filter despite being registered.
      # That removes REQ-294 from the deferred set entirely (a registered
      # entry is not a deferral, regardless of its queue task's status).
      # Net: 3 - 1 = 2. Re-derived, not guessed: confirmed live via
      # `MIX_ENV=test mix run --no-start -e` calling
      # File.read!("docs/requirements.yaml") |> audit(), returning
      # deferral_count == 2, stale_count == 0. The detector is unchanged.
      #
      # UPDATE (ISS-0870, 2026-09-27): the count dropped from 2 to 0 by the
      # same registered-it-properly mechanism as the REQ-284/REQ-291
      # precedent above. REQ-222 (letflow-queue's GET /tasks endpoint) was
      # confirmed live to already be implemented and shipped in the target
      # repo -- its yaml was simply never backfilled to `done` here -- which
      # expired both REQ-223's and REQ-224's `blocked-by: REQ-222`
      # deferrals. Neither had any other live blocker, so both were
      # registered for real (queue tasks 871, 872; GH#1907/#1908) rather
      # than re-scoped, removing both from the deferred set entirely. Net:
      # 2 - 2 = 0. Re-derived, not guessed: confirmed live via
      # `mix letflow.check_deferral_staleness`, returning
      # "0 deferred of 397 entries; 0 stale". The detector is unchanged.
      assert result.deferral_count == 0
      assert result.stale_count == 0

      # The substance, not just the count: every deferral present is
      # legitimate on its own terms. This is what makes the green
      # non-vacuous, and would catch a deferral that merely stopped being
      # counted.
      assert Enum.all?(result.deferrals, &(&1.verdict == :legitimate))

      assert Enum.sort(Enum.map(result.deferrals, & &1.id)) == []
    end

    test "T-REG-STILL-GREEN -- the bounded `status` addition kept ISS-0231 green" do
      report = @live_corpus |> File.read!() |> Registration.scan()

      assert report.violations == []
      assert report.entry_count > 0
      assert report.counts.registered + report.counts.deferred == report.entry_count

      # The one addition of design D4: a raw, uninterpreted token.
      assert Enum.all?(report.entries, &Map.has_key?(&1, :status))
      assert Enum.all?(report.entries, &(is_binary(&1.status) or is_nil(&1.status)))
    end
  end

  # ==================================================================
  # T-ALIAS-* : ISS-0258 AC2 -- "wired into an actual gate, not built and
  # left unwired". `mix letflow.check` is the ONLY gate surface this repo
  # has (design section 1.1: no .github, no .gitlab-ci.yml, no .circleci),
  # so alias membership IS the wiring. Without this test the line can be
  # deleted from mix.exs and the whole suite stays green -- measured.
  # Precedent for reading mix.exs from a test:
  # test/letflow/engine/lua_script_audit_test.exs, "mix.exs and moduledoc
  # guardrails".
  # ==================================================================

  describe "the letflow.check alias wiring (AC2)" do
    setup do
      %{aliases: Mix.Project.config()[:aliases][:"letflow.check"]}
    end

    test "T-ALIAS-WIRED -- the detector is a step of `mix letflow.check`", %{aliases: aliases} do
      assert "letflow.check_deferral_staleness" in aliases,
             "the detector is unwired -- `mix letflow.check` steps are: #{inspect(aliases)}"
    end

    test "T-ALIAS-SLOT -- it runs after registration and before the slow steps (D5)", %{
      aliases: aliases
    } do
      # Design D5 rules slot 3: immediately after the check it shares a parse
      # with, and BEFORE `format --check-formatted` / `compile
      # --warnings-as-errors` / the test run, so a stale deferral is reported
      # in a second rather than after a full compile+test cycle. Asserted as
      # relative order, not a hard index, per OQ-4.
      at = &Enum.find_index(aliases, fn step -> step == &1 end)

      assert at.("letflow.check_requirements_registration") <
               at.("letflow.check_deferral_staleness")

      assert at.("letflow.check_deferral_staleness") < at.("format --check-formatted")
    end
  end
end

defmodule Mix.Tasks.Letflow.CheckDeferralStalenessTaskTest do
  @moduledoc """
  Task-level coverage for `mix letflow.check_deferral_staleness` -- the thin
  `run/1` shell around the pure core exercised above.

  `run/1` reads a hard-coded relative path (`docs/requirements.yaml`) and has
  no path argument; adding one would be a design change and is not this
  file's to make. So these tests `File.cd!/2` into a temp directory holding a
  fixture corpus, which changes the working directory for the whole VM --
  hence `async: false`. The cd window is kept to the single `run/1` call.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 1]

  alias Mix.Tasks.Letflow.CheckDeferralStaleness, as: Check

  @green """
  stages:
    - id: S8
      name: Multi-tenant hardening
  requirements:
    - id: REQ-900
      stage: S8
      status: pending
      impl_order: 7
    - id: REQ-901
      stage: S8
      status: pending
      # impl_order: UNREGISTERED -- waits on the S8 kernel
  """

  @red """
  stages:
    - id: S4
      name: API surface
  requirements:
    - id: REQ-900
      stage: S4
      status: done
      impl_order: 7
    - id: REQ-901
      stage: S4
      status: pending
      # impl_order: UNREGISTERED -- waits on something
  """

  defp in_corpus(content, fun) do
    dir = Path.join(System.tmp_dir!(), "letflow-cds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/requirements.yaml"), content)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.cd!(dir, fun)
  end

  test "T-TASK-PRINTS-ON-GREEN -- both blocks print unconditionally" do
    {result, out} = in_corpus(@green, fn -> with_io(fn -> Check.run([]) end) end)

    assert result == :ok
    assert out =~ "STAGE ACTIVITY (derived, always reported, never gates):"
    assert out =~ "S8  INACTIVE"
    assert out =~ "DEFERRALS (legitimate ones are reported and never gate):"
    assert out =~ "REQ-901"
    assert out =~ "LEGITIMATE"
    assert out =~ "1 deferred of 2 entries; 0 stale"
    refute out =~ "VIOLATIONS"
  end

  test "T-TASK-RAISES -- a stale deferral raises Mix.Error" do
    {error, out} =
      in_corpus(@red, fn ->
        with_io(fn -> assert_raise Mix.Error, fn -> Check.run([]) end end)
      end)

    # The report is written before the raise -- the table and the roster are
    # visible on a red run too, not swallowed by the exception.
    assert out =~ "S4  ACTIVE"
    assert out =~ "1 deferred of 2 entries; 1 stale"
    assert out =~ "VIOLATIONS (each one fails the run):"

    message = Exception.message(error)
    assert message =~ "[S1]"
    assert message =~ "REQ-901"
    assert message =~ "1 violation(s)"
  end

  test "T-TASK-MISSING-FILE -- an unreadable corpus raises rather than passing" do
    dir = Path.join(System.tmp_dir!(), "letflow-cds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.cd!(dir, fn ->
      error = assert_raise Mix.Error, fn -> Check.run([]) end
      assert Exception.message(error) =~ "[S5]"
      assert Exception.message(error) =~ "docs/requirements.yaml"
    end)
  end
end
