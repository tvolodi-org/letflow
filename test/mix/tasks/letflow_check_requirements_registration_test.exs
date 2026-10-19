defmodule Mix.Tasks.Letflow.CheckRequirementsRegistrationTest do
  @moduledoc """
  Regression coverage for ISS-0231 -- `mix letflow.check_requirements_registration`
  (`lib/mix/tasks/letflow.check_requirements_registration.ex`).

  Spec: `test/specs/ISS-0231.md`. Design:
  `lib/letflow/design/iss0231-requirement-registration-drift-detection.md`,
  built to its section 7.4 **as amended by section 11.4 (MAJOR-1) and section
  11.7 (MINOR-1/-3/-5)**, which supersede the design body where they differ.
  Run: `WF03-ISS0231-20260822`, WF-03 Step 4.

  ## Why this suite is almost entirely hermetic

  The fix ADDS a module, so the pre-fix failure of every test here is
  `UndefinedFunctionError` -- which proves the module is new and nothing
  else. WF-03's "when the pre-fix failure is 'the code under test does not
  exist'" clause therefore governs: discrimination has to be demonstrated by
  mutating the shipped logic, and the tests have to be shaped so the mutants
  actually go red.

  Design section 7.2 (independently re-derived by CODE-DESIGN-VALIDATOR in
  section 11.1) is the load-bearing constraint: under **M1** -- the mutant
  that reproduces the ISS-0231 bug verbatim, a classifier that treats any
  attributed `impl_order` line as `:registered` -- the live
  `docs/requirements.yaml` still satisfies R1, R2 and R5, so a suite built
  only against the live corpus is vacuous against the very bug this fix
  exists to prevent.

  **That argument is now strictly stronger than when it was written, and the
  reason is worth recording.** When the design was authored the live corpus
  was 111 entries with 21 `:deferred`. Mid-run a sibling session landed
  `c84c27a` (PR #495), registering REQ-115..139. On this branch the live
  corpus classifies as:

      115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified

  With **zero** deferred entries there is nothing left on the live corpus for
  M1 to misclassify -- M1 produces *no visible change at all* against the real
  file. M1 is now detectable **only** by hermetic fixtures. The same collapse
  hits **M5** (`:deferred` promoted to hard-fail), whose only detector in the
  design was the live corpus: with 0 deferred entries the live file is green
  under M5 too, so `F-DEFERRED-GREEN` below carries that detection instead.

  The consequence, stated plainly so no future reader mistakes the live tests
  for coverage: **the hermetic fixture group is the whole test.** The
  `T-LIVE-*` tests below are invariant smoke tests over the real corpus. They
  are deliberately not pinned to today's 115/115/0/0/0 (those numbers move
  legitimately whenever a stage is registered or a requirement is added), and
  none of them is cited as the detector for any mutant.

  ## What happened to T-ROSTER

  Design section 7.4 specified `T-ROSTER` against the live corpus, and section
  11.6's OQ-5 ruling revised it to the unpinned form: `render/1`'s output on
  the real file "names at least one id, **the printed deferred count is
  greater than zero**, and every id printed in the roster appears in the
  `:deferred` bucket of the same report".

  As specified, that test **fails on this branch** -- the printed deferred
  count is zero. Section 11.6 anticipated exactly this and ruled in advance
  what such a failure means: *"the deferred set is now empty, confirm that is
  intended and retire this test", not "regression".* It is intended: `c84c27a`
  registered the entire deferred set through real `register_task` calls.

  So `T-ROSTER` is **retired in its live-corpus form and the property it was
  protecting is relocated, not deleted.** The property -- *the printed roster
  and the classification agree* -- now lives in two places:

    * `F-ROSTER-AGREEMENT`, a hermetic fixture with a deliberately non-empty
      deferred set, where the property holds permanently and where it is
      genuinely discriminating (it goes red under M1). This is the real test.
    * `T-ROSTER-LIVE-AGREEMENT`, the same property stated *conditionally* over
      the live corpus, deriving its expectation from the report instead of
      pinning a count: empty deferred set implies the "none" line, non-empty
      implies every deferred id is printed with a matching total. That form is
      true of any corpus and never goes stale.

  ## Two other decisions worth stating

  **`classify_entry([])` raises.** The function has no `[]` clause, so an
  empty entry crashes with `FunctionClauseError` rather than returning. That
  is unreachable from `scan/1` (the splitter only ever emits lists whose head
  is the `- id:` line), so it is characterised here rather than treated as a
  defect -- see `F-CLASSIFY-EMPTY`. No helper in this file can produce it.

  **LF heredoc-style fixtures are safe against a CRLF corpus.** The real
  `docs/requirements.yaml` is CRLF; every fixture here is LF. `F-CRLF` pins
  that the two produce structurally identical entries with no `\\r` leaking
  into any rationale, so the LF fixtures are not testing a different parser
  than the one the live file exercises.

  ## Fixtures carry a `stages:` section on purpose

  `doc/1` wraps every fixture body in a realistic two-key file. That is not
  decoration: it makes every count assertion in this file sensitive to **M9**
  (section guard removed), because under M9 the stage entries are swept into
  `entry_count`. `F-STAGES-SECTION` states that as a named assertion in the
  stronger form required by section 11.7 MINOR-5.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckRequirementsRegistration, as: Check

  @project_root Path.expand("../../..", __DIR__)
  @live_corpus Path.join(@project_root, "docs/requirements.yaml")

  # ------------------------------------------------------------------
  # Fixture construction. Explicit, string-built, never a heredoc --
  # indentation is load-bearing for this parser (the >= 4-space
  # attribution rule of design section 4.3), so it is spelled out rather
  # than left to heredoc stripping.
  # ------------------------------------------------------------------

  @stages_section [
                    "stages:",
                    "  - id: S0",
                    "    name: Bootstrap",
                    "  - id: S8",
                    "    name: Multi-tenant hardening",
                    ""
                  ]
                  |> Enum.join("\n")

  # The number of `  - id: ` lines in @stages_section. Under M9 these leak
  # into entry_count; under the shipped section guard they cannot.
  @stage_entry_count 2

  defp doc(body), do: @stages_section <> "requirements:\n" <> body

  # One requirement entry: the 2-space `- id:` line plus 4-space fields.
  defp req(id, fields) do
    Enum.join(["  - id: " <> id | Enum.map(fields, &("    " <> &1))], "\n") <> "\n"
  end

  defp scan(body), do: Check.scan(doc(body))

  defp single(body) do
    report = scan(body)
    assert [entry] = report.entries
    {report, entry}
  end

  # For the pure state-assignment tests permitted by section 11.7 MINOR-1 to
  # call classify_entry/1 directly. Never produces an empty list.
  defp classify(entry_text) do
    lines =
      entry_text
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} -> {n, line} end)

    refute lines == [], "classify/1 must never be handed an empty entry -- see F-CLASSIFY-EMPTY"
    Check.classify_entry(lines)
  end

  defp violations_for(report, rule), do: Enum.filter(report.violations, &(&1.rule == rule))

  defp sum(%{counts: c}), do: c.registered + c.deferred + c.neither + c.unclassified

  # F-TOTALITY, applied to every fixture rather than stated once.
  defp assert_totality(report, expected_entries) do
    assert sum(report) == report.entry_count
    assert length(report.entries) == report.entry_count

    assert report.entry_count == expected_entries,
           "entry_count drifted -- if this is #{expected_entries + @stage_entry_count} " <>
             "the section guard of design section 4.1 is gone (M9)"

    report
  end

  defp rendered(report), do: report |> Check.render() |> IO.iodata_to_binary()

  # ------------------------------------------------------------------
  # Named fixture bodies
  # ------------------------------------------------------------------

  defp registered_entry(id \\ "REQ-001") do
    req(id, [
      "stage: S0",
      "title: A registered requirement",
      "impl_order: 42  # letflow-queue task id"
    ])
  end

  defp deferred_entry(id \\ "REQ-002") do
    req(id, [
      "stage: S8",
      "title: A deliberately deferred requirement",
      "# impl_order: UNREGISTERED -- see the S8 note above"
    ])
  end

  defp neither_entry(id \\ "REQ-003") do
    # NOTE: the title deliberately avoids the token `impl_order`. A field
    # whose *prose* mentions it is an attributed token line and lands in
    # :unclassified, not :neither -- caught while building this suite.
    req(id, ["stage: S1", "title: Carries no registration line of any form"])
  end

  # ==================================================================
  # F-* : hermetic fixtures. These are the discriminating tests.
  # ==================================================================

  describe "state assignment (hermetic fixtures)" do
    test "F-REGISTERED-BASIC -- the field form is :registered and its value is parsed" do
      entry = classify(registered_entry())

      assert entry.state == :registered
      assert entry.impl_order == 42
      assert entry.rationale == nil
      assert entry.id == "REQ-001"
      assert entry.stage == "S0"

      {report, from_scan} = single(registered_entry())
      assert from_scan.state == :registered
      assert report.counts.registered == 1
      assert report.violations == []
      assert_totality(report, 1)
    end

    test "F-DEFERRED-BASIC -- the marker form is :deferred and is NOT :registered (M1)" do
      entry = classify(deferred_entry())

      # This pair of assertions is what M1 breaks. M1 -- "any attributed
      # impl_order line is :registered" -- is the ISS-0231 bug verbatim:
      # the marker form's text contains the substring `impl_order:`, which
      # is exactly how 21 deferrals were counted as registrations.
      assert entry.state == :deferred
      refute entry.state == :registered

      assert entry.impl_order == nil
      assert is_binary(entry.rationale)
      assert entry.rationale != ""
      assert entry.rationale == "-- see the S8 note above"

      {report, from_scan} = single(deferred_entry())
      assert from_scan.state == :deferred
      assert report.counts.deferred == 1
      assert report.counts.registered == 0
      assert_totality(report, 1)
    end

    test "F-DEFERRED-GREEN -- a documented deferral is visible debt, not a failure (M5)" do
      # Design D3 / invariant I3: the deferred count never influences the
      # exit code, at any value. This is M5's ONLY detector now. The design
      # assigned M5 to T-LIVE-GREEN, which required the live corpus to hold
      # a non-zero deferred count; on this branch it holds zero, so the live
      # file is green under M5 and detects nothing. The property moves here.
      report = scan(registered_entry() <> deferred_entry())

      assert report.counts.deferred == 1
      assert report.counts.registered == 1
      assert report.violations == [], "a documented deferral must never gate -- design D3/I3"
      assert_totality(report, 2)
    end

    test "F-NEITHER -- an entry with no impl_order line of any form is :neither" do
      entry = classify(neither_entry())

      assert entry.state == :neither
      assert entry.impl_order == nil
      assert entry.rationale == nil
    end

    test "F-NEITHER-EXIT -- :neither carries an R1 violation, not merely a printed line (M4)" do
      # Section 11.7 MINOR-1: a test naming a rule id must go through scan/1,
      # because entry() has no violations field and cannot express R1-R6.
      report = scan(registered_entry() <> neither_entry())

      assert report.counts.neither == 1
      assert [violation] = violations_for(report, "R1")
      assert violation.id == "REQ-003"
      assert is_integer(violation.line)
      assert violation.message =~ "no `impl_order` line of any form"
      assert_totality(report, 2)
    end

    test "F-NOVEL-FORM -- an unrecognised shape is :unclassified, never absorbed (M2)" do
      # Every form here carries the BARE token `impl_order` (design section
      # 3(d)): the token is what triggers classification, the shape only
      # discriminates. The classifier's final clause is :unclassified and
      # :unclassified hard-fails -- there is no "everything else is fine"
      # branch, which is what M2 (final clause -> :registered) and M2b
      # (-> :deferred) each remove.
      for line <- ["impl_order = 7", "- impl_order: 7", "impl_order 7"] do
        entry = classify(req("REQ-005", ["stage: S3", line]))

        assert entry.state == :unclassified,
               "#{inspect(line)} classified as #{inspect(entry.state)} -- the fallback " <>
                 "clause must be a failure, not a bucket"

        refute entry.state == :registered
        refute entry.state == :deferred
        assert entry.impl_order == nil
        assert entry.detail =~ "neither recognised shape"
      end

      report = scan(req("REQ-005", ["stage: S3", "impl_order = 7"]))
      assert report.counts.unclassified == 1
      assert [violation] = violations_for(report, "R2")
      assert violation.id == "REQ-005"
      assert_totality(report, 1)
    end

    test "F-NOVEL-FORM-ADJACENT-TOKEN -- `impl_order_hint` / `impl-order` land in :neither" do
      # DIVERGENCE FROM THE DESIGN, recorded rather than papered over.
      # Design section 7.4's F-NOVEL-FORM predicted `impl_order_hint: 7` and
      # `impl-order: 7` would be :unclassified. They are not: the shipped
      # trigger is the BARE token, `~r/\bimpl_order\b/`, and neither string
      # contains it (`_` and `-` are on the wrong side of the word boundary
      # in the first and second case respectively). They therefore carry no
      # attributed impl_order line at all and are :neither.
      #
      # This is a bucket difference, not a hole: :neither hard-fails under
      # R1 exactly as :unclassified hard-fails under R2, so neither form is
      # silently absorbed, and design section 3(d) is satisfied as written
      # ("whether that line concerns registration is decided by the presence
      # of the bare token impl_order"). Pinned here so a future reader does
      # not re-derive the question, and so a change to the trigger regex --
      # which WOULD be a real behaviour change -- turns this test red.
      for line <- ["impl_order_hint: 7", "impl-order: 7"] do
        entry = classify(req("REQ-005", ["stage: S3", line]))

        assert entry.state == :neither,
               "#{inspect(line)} is #{inspect(entry.state)}; either way it must hard-fail, " <>
                 "but the state pinned here is :neither"
      end

      report = scan(req("REQ-005", ["stage: S3", "impl_order_hint: 7"]))
      assert [_] = violations_for(report, "R1")
      assert violations_for(report, "R2") == []
    end

    test "F-NONINT-VALUE -- a non-integer value is :unclassified, never coerced (M2)" do
      for {line, note} <- [
            {"impl_order: TBD", "a placeholder"},
            {"impl_order: 4a", "a trailing character after the digits"},
            {"impl_order:", "an empty value"},
            {"impl_order:42", "no space after the colon -- section 11.7 MINOR-3"}
          ] do
        entry = classify(req("REQ-004", ["stage: S2", line]))

        assert entry.state == :unclassified, "#{inspect(line)} (#{note})"
        assert entry.impl_order == nil, "#{inspect(line)} must never be coerced to a number"
      end
    end

    test "F-BOTH-FORMS -- an entry carrying both forms is ambiguous, not silently resolved" do
      entry =
        classify(
          req("REQ-006", [
            "stage: S8",
            "impl_order: 7  # letflow-queue task id",
            "# impl_order: UNREGISTERED -- superseded, kept by mistake"
          ])
        )

      assert entry.state == :unclassified
      refute entry.state == :registered
      refute entry.state == :deferred
      assert entry.impl_order == nil
      assert entry.detail =~ "2 attributed impl_order lines"

      report =
        scan(
          req("REQ-006", [
            "stage: S8",
            "impl_order: 7  # letflow-queue task id",
            "# impl_order: UNREGISTERED -- superseded, kept by mistake"
          ])
        )

      assert [violation] = violations_for(report, "R2")
      assert violation.id == "REQ-006"
      assert_totality(report, 1)
    end

    test "F-BARE-MARKER -- a marker with no rationale is an R3 violation (M7)" do
      # Section 11.7 MINOR-4: the rationale is NOT part of the recognition
      # shape. A bare marker still classifies :deferred; R3 is a separate
      # rule that then fires. Section 11.7 MINOR-2: rationale is nil when
      # the marker carries no trailing text.
      report = scan(req("REQ-007", ["stage: S8", "# impl_order: UNREGISTERED"]))

      assert [entry] = report.entries
      assert entry.state == :deferred
      assert entry.rationale == nil

      assert [violation] = violations_for(report, "R3")
      assert violation.id == "REQ-007"
      assert violation.message =~ "no rationale after `UNREGISTERED`"
      assert_totality(report, 1)

      # And the roster says so out loud rather than printing a blank.
      assert rendered(report) =~ "(NO RATIONALE -- R3)"
    end

    test "F-ANCHOR -- `impl_order: 5  # was UNREGISTERED until Tuesday` is :registered (M8)" do
      # Absorption with the buckets reversed. Design section 4.4: the marker
      # pattern is anchored to the whole line precisely so a registered entry
      # whose trailing comment happens to mention UNREGISTERED is not read as
      # a deferral.
      entry =
        classify(req("REQ-008", ["stage: S2", "impl_order: 5  # was UNREGISTERED until Tuesday"]))

      assert entry.state == :registered
      refute entry.state == :deferred
      assert entry.impl_order == 5
      assert entry.rationale == nil

      report =
        scan(req("REQ-008", ["stage: S2", "impl_order: 5  # was UNREGISTERED until Tuesday"]))

      assert report.counts.registered == 1
      assert report.counts.deferred == 0
      assert report.violations == []
      assert_totality(report, 1)

      # Second half of the anchoring property, and the case that makes the
      # regex mutant on its own detectable. `impl_order: 5  # was
      # UNREGISTERED` alone does NOT discriminate an unanchored marker
      # pattern, because `classify_registration/2`'s `cond` tries the field
      # form first and the field form still matches -- so unanchoring the
      # marker regex without also reordering the cond is behaviour-preserving
      # on that input. These lines carry the bare token `impl_order` and the
      # word UNREGISTERED but match NEITHER anchored shape, so the shipped
      # classifier reaches its `:unclassified` fallback while an unanchored
      # marker pattern reads them as documented deferrals.
      for line <- [
            "# impl_order was UNREGISTERED before Tuesday",
            "# TODO: impl_order -- REQ-008 was UNREGISTERED, ask ORCH"
          ] do
        entry = classify(req("REQ-008", ["stage: S2", line]))

        assert entry.state == :unclassified,
               "#{inspect(line)} is not a marker-form line; an unanchored marker pattern " <>
                 "would absorb it into :deferred (design section 4.4)"

        refute entry.state == :deferred
        assert entry.rationale == nil
      end
    end

    test "F-BLOCK-NOTE -- 2-space prose lines belong to no entry (M6)" do
      # Reproduces the real file's shape: a block note explaining the
      # deferral convention sits BETWEEN entries at 2-space indent. Design
      # section 4.3's >= 4-space attribution rule is what keeps it out of
      # both neighbours. Without it each neighbour gains a second attributed
      # impl_order line and flips to :unclassified.
      body =
        deferred_entry("REQ-009") <>
          "\n" <>
          "  # NOTE ON impl_order: none of REQ-009..010 carry one. Per\n" <>
          "  # TASK_QUEUE.md (\"an unregistered requirement carries no\n" <>
          "  # impl_order at all -- never a guessed one\"), the deferral is\n" <>
          "  # deliberate and is recorded on each entry instead.\n" <>
          "\n" <>
          deferred_entry("REQ-010")

      report = scan(body)

      assert report.counts.deferred == 2
      assert report.counts.unclassified == 0
      assert report.violations == []
      assert_totality(report, 2)

      for entry <- report.entries do
        assert entry.state == :deferred
        assert entry.rationale == "-- see the S8 note above"
      end
    end

    test "F-BAD-ID -- a malformed id is :unclassified AND still counted (M10)" do
      # Design section 4.2: a requirement whose id line is malformed must not
      # be invisible to the scan -- that is the original blindness class one
      # level up. M10 replaces this with a silent skip, which shows up here
      # both as a missing entry and, via assert_totality, as a broken R5.
      for bad <- ["REQ_115", "115", "REQ-", "req-115"] do
        entry = classify(req(bad, ["stage: S8", "impl_order: 3  # task id"]))

        assert entry.state == :unclassified, "id #{inspect(bad)}"
        assert entry.detail =~ "not a well-formed REQ-NNN"
      end

      report = scan(registered_entry() <> req("REQ_115", ["stage: S8", "impl_order: 3  # id"]))

      assert report.counts.unclassified == 1
      assert report.counts.registered == 1
      assert [violation] = violations_for(report, "R2")
      assert violation.id == "REQ_115"
      assert_totality(report, 2)
    end

    test "F-DUP-ID -- the same REQ-NNN twice is an R4 violation" do
      report = scan(registered_entry("REQ-001") <> registered_entry("REQ-001"))

      assert [violation] = violations_for(report, "R4")
      assert violation.id == "REQ-001"
      assert violation.message =~ "duplicate requirement id"
      assert_totality(report, 2)
    end
  end

  describe "file shape (hermetic fixtures)" do
    test "F-STAGES-SECTION -- stage entries contribute to nothing (M9)" do
      # Section 11.7 MINOR-5 requires the STRONGER form: it is not enough to
      # say stage entries "contribute nothing to any bucket". Under M9 the
      # section guard is gone and the stage entries become real entries, so
      # the fixture must assert counts.neither == 0 AND entry_count equal to
      # the requirement-entry count ONLY.
      content = doc(registered_entry() <> deferred_entry())
      report = Check.scan(content)

      assert report.entry_count == 2
      assert length(report.entries) == 2
      assert report.counts.neither == 0
      assert report.counts.unclassified == 0
      assert report.counts.registered == 1
      assert report.counts.deferred == 1
      assert report.violations == []

      # No stage id reached the entry list at all.
      ids = Enum.map(report.entries, & &1.id)
      assert ids == ["REQ-001", "REQ-002"]
      refute "S0" in ids
      refute "S8" in ids

      # And the fixture really does contain the stages section, so this test
      # could have failed.
      assert content =~ "stages:\n"
      assert content =~ "  - id: S0\n"
    end

    test "F-NO-REQUIREMENTS-KEY -- a missing key is an R6 violation, not a silent zero pass" do
      report = Check.scan(@stages_section <> "  - id: S9\n    name: Mobile\n")

      assert report.entries == []
      assert report.entry_count == 0
      assert [violation] = violations_for(report, "R6")
      assert violation.id == nil
      assert violation.message =~ "no top-level `requirements:` key"
      refute report.violations == []
    end

    test "F-EMPTY-SECTION -- `requirements:` present with zero entries is an R5 violation (M3)" do
      # Section 11.4 (MAJOR-1) narrowed M3 to "delete R5 entirely" and made
      # THIS the detector. The `== -> <=` variant was struck as undetectable
      # by construction: sum(counts) === length(entries) === entry_count holds
      # identically for every input, because classify_entry/1 returns exactly
      # one state per call and the splitter defines both sides of the
      # equation. F-TOTALITY / T-TOTALITY-LIVE remain in this file as
      # invariant assertions but detect no mutant, and nothing here claims
      # otherwise.
      report = Check.scan(@stages_section <> "requirements:\n")

      assert report.entries == []
      assert report.entry_count == 0
      assert [violation] = violations_for(report, "R5")
      assert violation.message =~ "zero entries"
      assert violation.message =~ "never a green pass"
    end

    test "F-CRLF -- a CRLF corpus and an LF fixture produce identical entries" do
      # The real docs/requirements.yaml is CRLF; every fixture in this file
      # is LF. This pins that the fixtures exercise the same parser the live
      # file does, and that no \r leaks into a rationale or an id.
      lf = doc(registered_entry() <> deferred_entry() <> neither_entry())
      crlf = String.replace(lf, "\n", "\r\n")

      lf_report = Check.scan(lf)
      crlf_report = Check.scan(crlf)

      assert lf_report.counts == crlf_report.counts
      assert lf_report.entry_count == crlf_report.entry_count

      strip_lines = fn r -> Enum.map(r.entries, &Map.delete(&1, :line)) end
      assert strip_lines.(lf_report) == strip_lines.(crlf_report)

      for entry <- crlf_report.entries do
        refute entry.id =~ "\r"
        refute (entry.rationale || "") =~ "\r"
        refute (entry.stage || "") =~ "\r"
      end
    end

    test "F-CLASSIFY-EMPTY -- classify_entry/1 has no [] clause and raises on one" do
      # Characterisation, not a defect claim. scan/1's splitter only ever
      # emits lists headed by the `- id:` line, so [] is unreachable in
      # production; a fixture that passed [] would crash rather than return.
      # Pinned so the behaviour is a decision on record instead of a surprise.
      # `apply/3` on purpose: a literal `[]` argument is a compile-time type
      # error under `--warnings-as-errors`, which `mix letflow.check` runs.
      assert_raise FunctionClauseError, fn -> apply(Check, :classify_entry, [[]]) end
    end
  end

  describe "F-TOTALITY -- the partition is total for every fixture" do
    test "sum(counts) == entry_count == length(entries) across all shapes" do
      fixtures = [
        {"registered", registered_entry(), 1},
        {"deferred", deferred_entry(), 1},
        {"neither", neither_entry(), 1},
        {"novel form", req("REQ-005", ["stage: S3", "impl_order = 7"]), 1},
        {"non-integer", req("REQ-004", ["stage: S2", "impl_order: TBD"]), 1},
        {"both forms",
         req("REQ-006", ["stage: S8", "impl_order: 7  # id", "# impl_order: UNREGISTERED -- x"]),
         1},
        {"bare marker", req("REQ-007", ["stage: S8", "# impl_order: UNREGISTERED"]), 1},
        {"bad id", req("REQ_115", ["stage: S8", "impl_order: 3  # id"]), 1},
        {"mixed",
         registered_entry() <> deferred_entry() <> neither_entry() <> req("REQ_9", ["stage: S1"]),
         4}
      ]

      for {name, body, expected} <- fixtures do
        report = scan(body)

        assert sum(report) == report.entry_count, name
        assert length(report.entries) == report.entry_count, name
        assert report.entry_count == expected, name
      end
    end
  end

  describe "F-ROSTER-AGREEMENT -- the printed roster and the classification agree" do
    test "the roster names exactly the :deferred ids, with a non-zero total (M1)" do
      # This is the relocated T-ROSTER. Design section 11.6 (OQ-5) ruled the
      # unpinned form, whose third clause -- "every id printed in the roster
      # appears in the :deferred bucket of the same report (and no
      # :registered id does)" -- is what keeps it honest. Held here against a
      # hermetic fixture with a deliberately non-empty deferred set, so it is
      # permanently true and genuinely discriminating: under M1 the deferred
      # bucket empties, the roster prints "none", and both the count and the
      # agreement assertions go red.
      body =
        registered_entry("REQ-001") <>
          deferred_entry("REQ-002") <>
          registered_entry("REQ-003") <>
          req("REQ-004", ["stage: S9", "# impl_order: UNREGISTERED -- S9 depends on S8"])

      report = scan(body)
      assert report.violations == []
      assert_totality(report, 4)

      out = rendered(report)

      deferred_ids = for e <- report.entries, e.state == :deferred, do: e.id
      registered_ids = for e <- report.entries, e.state == :registered, do: e.id

      assert length(deferred_ids) > 0
      assert out =~ "total deferred: #{length(deferred_ids)}"

      printed_ids = ~r/REQ-\d+/ |> Regex.scan(out) |> List.flatten() |> Enum.sort() |> Enum.uniq()

      assert printed_ids == Enum.sort(deferred_ids),
             "the roster and the classification must agree: printed #{inspect(printed_ids)} " <>
               "vs. deferred #{inspect(Enum.sort(deferred_ids))}"

      for id <- registered_ids do
        refute id in printed_ids, "#{id} is :registered and must not appear in the roster"
      end

      # Grouped by stage, with group counts and rationale text (design R5's
      # "always printed" half).
      assert out =~ "S8 (1):"
      assert out =~ "S9 (1):"
      assert out =~ "-- see the S8 note above"
      assert out =~ "-- S9 depends on S8"
      assert out =~ "4 entries = 2 registered + 2 deferred + 0 neither + 0 unclassified"
    end

    test "an empty deferred set renders the explicit `none` line, not a blank section" do
      report = scan(registered_entry())
      out = rendered(report)

      assert out =~ "DEFERRED (visible debt -- always reported, never gates): none"
      assert out =~ "1 entries = 1 registered + 0 deferred + 0 neither + 0 unclassified"
    end
  end

  # ==================================================================
  # T-LIVE-* : invariant smoke tests over the real corpus.
  #
  # NOT discrimination. See the moduledoc: with 0 deferred entries on this
  # branch the live corpus is unchanged under M1 and green under M5. These
  # tests are read-only (File.read!), assert properties rather than pinned
  # totals, and are cited as the detector for no mutant.
  # ==================================================================

  describe "T-LIVE-* -- the real docs/requirements.yaml" do
    setup do
      assert File.exists?(@live_corpus), "the live corpus must exist at #{@live_corpus}"
      %{report: @live_corpus |> File.read!() |> Check.scan()}
    end

    test "T-LIVE-GREEN -- the real file produces zero violations", %{report: report} do
      assert report.violations == [],
             "mix letflow.check would be RED on this branch:\n" <>
               Enum.map_join(report.violations, "\n", &inspect/1)
    end

    test "T-TOTALITY-LIVE -- the partition is total on the real file", %{report: report} do
      # Deliberately a property, not a pinned total: 115/115/0/0/0 today, and
      # the numbers move legitimately whenever a requirement is added or a
      # stage is registered. The only pinned bound is that the corpus is not
      # empty and not implausibly small.
      assert sum(report) == report.entry_count
      assert length(report.entries) == report.entry_count
      assert report.entry_count > 100
    end

    test "T-LIVE-INVARIANTS -- neither and unclassified are both empty", %{report: report} do
      # The two properties the mechanism exists to keep true (design I4).
      assert report.counts.neither == 0
      assert report.counts.unclassified == 0
    end

    test "T-ROSTER-LIVE-AGREEMENT -- roster and classification agree, whatever the count",
         %{report: report} do
      # The surviving, never-stale half of the retired T-ROSTER. It derives
      # its expectation from the report instead of pinning a count, so it is
      # true of a corpus with 21 deferrals and of today's corpus with 0.
      out = rendered(report)
      deferred_ids = for e <- report.entries, e.state == :deferred, do: e.id

      if deferred_ids == [] do
        assert out =~ "DEFERRED (visible debt -- always reported, never gates): none"
      else
        assert out =~ "total deferred: #{length(deferred_ids)}"
        for id <- deferred_ids, do: assert(out =~ id)
      end

      assert out =~
               "#{report.entry_count} entries = #{report.counts.registered} registered + " <>
                 "#{report.counts.deferred} deferred + #{report.counts.neither} neither + " <>
                 "#{report.counts.unclassified} unclassified"
    end
  end

  describe "R8 -- whole-file YAML parse guard (GH #2891)" do
    setup_all do
      {:ok, _} = Application.ensure_all_started(:yaml_elixir)
      :ok
    end

    # A requirements-shaped body: one registered entry carrying an
    # acceptance_criteria list whose single item is `item` (a full YAML list
    # item line payload, i.e. the text after "- ").
    defp entry_with_criterion(item) do
      req("REQ-001", [
        "stage: S0",
        "title: A registered requirement",
        "impl_order: 42  # letflow-queue task id",
        "acceptance_criteria:",
        "  - " <> item
      ])
    end

    # The real defect shape: a double-quoted scalar with unescaped inner
    # double quotes.
    @bad_item ~S|"x contains the sentence "A" and the sentence "B", end"|
    # The fix shape: inner quotes single-quoted.
    @good_item ~S|"x contains the sentence 'A' and the sentence 'B', end"|

    test "R8-VALID -- a small valid requirements document parses :ok" do
      assert Check.parse_check(doc(entry_with_criterion("plain criterion"))) == :ok
    end

    test "R8-BROKEN -- unescaped inner double quotes are rejected, and scan/2 alone misses it" do
      content = doc(entry_with_criterion(@bad_item))

      assert {:error, msg} = Check.parse_check(content)
      assert is_binary(msg)
      assert msg != ""

      # The gap the guard closes: the line-scanning check stays green on the
      # very same bytes.
      assert Check.scan(content).violations == []
    end

    test "R8-FIXED-SHAPE -- the same item with single-quoted inner quotes parses :ok" do
      assert Check.parse_check(doc(entry_with_criterion(@good_item))) == :ok
    end

    test "R8-NEVER-RAISES -- garbage input returns {:error, binary}, never raises or throws" do
      for garbage <- ["a: [unclosed", "		bad: :
  - -"] do
        assert {:error, msg} = Check.parse_check(garbage)
        assert is_binary(msg)
      end
    end

    test "T-LIVE-PARSE -- the real docs/requirements.yaml parses as YAML" do
      assert Check.parse_check(File.read!(@live_corpus)) == :ok
    end
  end
end

defmodule Mix.Tasks.Letflow.CheckRequirementsRegistrationTaskTest do
  @moduledoc """
  Task-level coverage (T-TASK-*) for `mix letflow.check_requirements_registration`.

  `async: false`, and in a separate module from the fixture suite above for
  exactly one reason: `run/1` reads `docs/requirements.yaml` from a module
  attribute relative to the **current working directory**, with no path seam.
  Adding one would be a design change and is not this file's to make (the same
  call `test/mix/tasks/letflow_check_toolchain_test.exs` records for the same
  reason). So these tests `File.cd!/2` into a temp directory holding a fixture
  corpus, which changes the working directory for the whole VM -- hence sync.
  The cd window is kept to the single `run/1` call.

  The hermetic fixture suite above stays `async: true` and never touches the
  filesystem.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 1]

  alias Mix.Tasks.Letflow.CheckRequirementsRegistration, as: Check

  @green """
  stages:
    - id: S8
      name: Multi-tenant hardening
  requirements:
    - id: REQ-001
      stage: S0
      impl_order: 42  # letflow-queue task id
    - id: REQ-002
      stage: S8
      # impl_order: UNREGISTERED -- see the S8 note above
  """

  @red """
  stages:
    - id: S8
      name: Multi-tenant hardening
  requirements:
    - id: REQ-001
      stage: S0
      impl_order: 42  # letflow-queue task id
    - id: REQ-002
      stage: S8
      title: Silently unregistered -- no registration line of any form
  """

  defp in_corpus(content, fun) do
    dir = Path.join(System.tmp_dir!(), "letflow-crr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/requirements.yaml"), content)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.cd!(dir, fun)
  end

  test "T-TASK-PRINTS-ON-GREEN -- the roster is printed unconditionally on a green run" do
    {result, out} = in_corpus(@green, fn -> with_io(fn -> Check.run([]) end) end)

    assert result == :ok
    assert out =~ "DEFERRED (visible debt -- always reported, never gates):"
    assert out =~ "S8 (1):"
    assert out =~ "REQ-002"
    assert out =~ "-- see the S8 note above"
    assert out =~ "total deferred: 1"
    assert out =~ "2 entries = 1 registered + 1 deferred + 0 neither + 0 unclassified"
    refute out =~ "VIOLATIONS"
  end

  test "T-TASK-RAISES -- an R1 violation raises Mix.Error" do
    {error, out} =
      in_corpus(@red, fn ->
        with_io(fn -> assert_raise Mix.Error, fn -> Check.run([]) end end)
      end)

    # The report is written before the raise -- the roster and the totality
    # line are visible on a red run too, not swallowed by the exception.
    assert out =~ "2 entries = 1 registered + 0 deferred + 1 neither + 0 unclassified"
    assert out =~ "VIOLATIONS (each one fails the run):"

    message = Exception.message(error)
    assert message =~ "[R1]"
    assert message =~ "REQ-002"
    assert message =~ "1 violation(s)"
  end

  test "T-TASK-R6-MISSING-FILE -- an unreadable corpus raises rather than passing silently" do
    dir = Path.join(System.tmp_dir!(), "letflow-crr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.cd!(dir, fn ->
      error = assert_raise Mix.Error, fn -> Check.run([]) end
      assert Exception.message(error) =~ "[R6]"
      assert Exception.message(error) =~ "docs/requirements.yaml"
    end)
  end
end
