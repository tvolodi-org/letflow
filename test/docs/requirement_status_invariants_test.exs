defmodule Letflow.Docs.RequirementStatusInvariantsTest do
  @moduledoc """
  ISS-0119 regression test — the requirement run history stays readable,
  append-only, and schema-conformant.

  Specified by `lib/letflow/design/iss-0119-status-file-readability.md` §7
  (assertions A0–A11) and §7.1 (the fail-first demonstration). No database, no
  new dependencies; all helpers live in `Letflow.Test.StatusHistory`
  (`test/support/status_history.ex`) and take explicit paths.

  ## One `test` block per assertion — deliberate, not stylistic

  ExUnit aborts a block at its *first* failed assertion. A0 is **expected to
  fail** when this file is run against a pre-fix tree (there is no index there),
  and A3 is the fail-first proof. If A0 and A3 shared a block with A0 first, A3
  would never execute and the pre-fix run would short-circuit on the missing
  index — resurrecting the precise failure design §7.1 opens by rejecting.
  A0..A8 (and A3b) therefore each get their own block, and A3 is never preceded
  by A0 within a block. (REVIEWER ruling C3 at Step 3d; raised as MINOR M1 by
  CODE-DESIGN-VALIDATOR.)

  The fail-first evidence itself is recorded in `test/specs/ISS-0119.md`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Test.StatusHistory, as: SH

  @index_path "docs/status/requirement_status.index.yaml"
  @status_dir "docs/status"
  @volume_glob "docs/status/requirement_status*.yaml"

  @legal_reqs [~r/^REQ-\d{3}$/, "SCOPE-CHANGE"]
  @legal_events ~w(started done blocked cancelled revised verified)

  # ── A0 ──────────────────────────────────────────────────────────────────────

  test "A0: the index exists and current-volume resolution is not degraded" do
    resolution = SH.current_volume(@index_path, @status_dir)

    assert match?({:index, path} when is_binary(path), resolution), """
    A0 — current-volume resolution is DEGRADED.

    #{@index_path} is missing, unreadable, or names no `status: current` volume,
    so StatusHistory.current_volume/2 fell back to the pre-index layout:

        #{inspect(resolution)}

    A0 exists so that fallback can never be *silently* active on a tree that is
    supposed to have ISS-0119's fix. On a PRE-FIX tree this failure is expected
    and correct — see design §7.1 and test/specs/ISS-0119.md.
    """
  end

  # ── A1 ──────────────────────────────────────────────────────────────────────

  test "A1: every indexed volume exists on disk, and every volume on disk is indexed" do
    index = SH.parse_index(@index_path)
    indexed = index.volumes |> Enum.map(& &1.path) |> Enum.sort()

    missing = Enum.reject(indexed, &File.exists?/1)

    # The glob also matches the index itself, which is not a volume; exclude it
    # by its own path rather than by a naming heuristic.
    on_disk =
      @volume_glob
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @index_path))
      |> Enum.sort()

    orphans = on_disk -- indexed

    assert {missing, orphans} == {[], []}, """
    A1 — index/disk disagreement.

      indexed but absent from disk: #{inspect(missing)}
      on disk but absent from index: #{inspect(orphans)}

      indexed: #{inspect(indexed)}
      on disk: #{inspect(on_disk)}
    """
  end

  # ── A2 ──────────────────────────────────────────────────────────────────────

  test "A2: exactly one volume is current and all others are closed" do
    index = SH.parse_index(@index_path)
    statuses = Enum.map(index.volumes, &{&1.volume, &1.status})

    current = Enum.filter(statuses, &(elem(&1, 1) == "current"))
    other = Enum.reject(statuses, &(elem(&1, 1) in ["current", "closed"]))

    assert {length(current), other} == {1, []}, """
    A2 — volume statuses are not well formed.

      current volumes: #{inspect(current)} (must be exactly one)
      neither current nor closed: #{inspect(other)}

      all: #{inspect(statuses)}
    """
  end

  # ── A3 — THE ISS-0119 REGRESSION ASSERTION (design §7.1) ────────────────────

  test "A3: the current volume is within the roll-rule ceilings" do
    resolution = SH.current_volume(@index_path, @status_dir)

    {tag, current_path} = resolution

    {max_lines, max_bytes} =
      case tag do
        :index ->
          roll_rule = SH.parse_index(@index_path).roll_rule
          {roll_rule.max_lines, roll_rule.max_bytes}

        :no_index_fallback ->
          SH.default_ceilings()
      end

    result = SH.within_bounds?(current_path, max_lines, max_bytes)

    assert result == :ok, """
    A3 — THE CURRENT RUN-HISTORY VOLUME IS TOO LARGE TO READ IN FULL.

    This is ISS-0119 itself: the append-only safeguard requires reading the
    volume you are about to append to, and a volume over the ceilings cannot be
    read in one un-scoped call.

      resolution: #{inspect(resolution)}
      ceilings:   #{max_lines} lines / #{max_bytes} bytes (#{ceiling_source(tag)})
      measured:   #{inspect(result)}

    A `resolution` of `{:no_index_fallback, _}` means this ran against a tree
    with no index — i.e. a pre-fix tree — and the failure above is a SIZE
    failure on the pre-index status file, not a missing-file error. That pairing
    is the fail-first demonstration design §7.1 requires; see
    test/specs/ISS-0119.md.
    """
  end

  # ── A3b — detector calibration, explicitly NOT the fail-first proof ─────────

  test "A3b: within_bounds?/3 actually fires at the index ceilings against frozen volume 1" do
    roll_rule = SH.parse_index(@index_path).roll_rule
    volume_1 = "docs/status/requirement_status.yaml"

    result = SH.within_bounds?(volume_1, roll_rule.max_lines, roll_rule.max_bytes)

    assert {:error, %{over: [:lines, :bytes]}} = result

    # Calibration guard only (design §7.1): volume 1 is oversized before AND
    # after the fix, so this is green in both worlds and is never shown to fail.
    # What it buys is that the detector fires at the index's REAL ceilings
    # against a real ~361 KB artefact — it goes red if the helper's line or byte
    # measurement regresses, or if a future agent raises the ceilings toward the
    # tool limits (which design §12 #2 forbids). It is NOT the ISS-0119
    # regression proof; A3 is.
  end

  # ── A4a — vocabulary (design §13.5; A4's vocabulary limb, unchanged) ────────

  test "A4a: every entry in every volume uses the documented req/event vocabulary" do
    index = SH.parse_index(@index_path)

    declared =
      index.known_anomalies
      |> Enum.map(&Map.take(&1, [:path, :line, :field, :value]))
      |> MapSet.new()

    drift =
      index.volumes
      |> Enum.flat_map(&SH.anomalies(&1.path, @legal_reqs, @legal_events))
      |> Enum.reject(&MapSet.member?(declared, &1))

    assert drift == [], """
    A4a — undeclared vocabulary violations (#{length(drift)}).

    #{indent(drift)}

    Legal `req:` values: REQ-NNN | SCOPE-CHANGE.
    Legal `event:` values: #{Enum.join(@legal_events, " | ")}.

    Violations already declared in the index's `known_anomalies:` are excluded
    above; A5 checks that declared set separately, in both directions. Entry
    SHAPE is a separate defect class with a separate declaration key and is
    asserted by A4b (design §13.5).
    """
  end

  # ── A4b — shape (design §13.5) ──────────────────────────────────────────────

  test "A4b: the on-disk shape-violation set equals known_shape_anomalies:, and every record cites a closed, pinned volume" do
    findings = a4b_findings(@index_path)

    assert a4b_clean?(findings), a4b_message(@index_path, findings)
  end

  # ── A4b negative controls — proof the assertion actually bites ──────────────
  #
  # An A4b that is green because it asserts nothing would be worse than no A4b
  # at all. These two blocks drive `a4b_findings/1` — the SAME function the A4b
  # block above asserts on — against throwaway fixtures written to a tmp dir, so
  # each of its two failure modes is shown firing. Nothing here reads or writes
  # the real index or any real volume.

  test "A4b (negative control 1): a declared record that is not on disk is reported, by side" do
    dir = fixture_dir("a4b-neg-1")

    write_volume!(Path.join(dir, "v1.yaml"), [conforming_entry("REQ-001", "done")])
    write_volume!(Path.join(dir, "v2.yaml"), [conforming_entry("REQ-002", "started")])

    write_index!(Path.join(dir, "index.yaml"), dir,
      shape_records: [
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-001",
          event: "done",
          kind: "missing_field",
          field: "note"
        }
      ]
    )

    findings = a4b_findings(Path.join(dir, "index.yaml"))
    message = a4b_message(Path.join(dir, "index.yaml"), findings)

    refute a4b_clean?(findings)
    assert findings.undeclared == []
    assert [%{entry_line: 3, kind: "missing_field", field: "note"}] = findings.unfound
    assert message =~ "declared but not on disk"
    assert message =~ "entry_line=3"
    assert message =~ ~s(req="REQ-001")
    assert message =~ ~s(kind="missing_field")
    assert message =~ ~s(field="note")
  end

  test "A4b (negative control 2): a record citing an open, unpinned volume fails even though the violation is really on disk" do
    dir = fixture_dir("a4b-neg-2")

    # The cited entry IS genuinely malformed on disk — it has no `note:` — and
    # the record matches it exactly, so SET EQUALITY IS GREEN here. What must
    # still fail is the closed-and-pinned rule: v2 is the CURRENT volume, so the
    # defect has to be fixed in the working tree, never declared away. This is
    # the declare-to-silence hole CODE-DESIGN-VALIDATOR failed §13's first
    # version on, and the reason the two rules are computed independently rather
    # than folded together.
    write_volume!(Path.join(dir, "v1.yaml"), [conforming_entry("REQ-001", "done")])
    write_volume!(Path.join(dir, "v2.yaml"), [noteless_entry("REQ-002", "started")])

    write_index!(Path.join(dir, "index.yaml"), dir,
      shape_records: [
        %{
          path: Path.join(dir, "v2.yaml"),
          entry_line: 3,
          req: "REQ-002",
          event: "started",
          kind: "missing_field",
          field: "note"
        }
      ]
    )

    findings = a4b_findings(Path.join(dir, "index.yaml"))
    message = a4b_message(Path.join(dir, "index.yaml"), findings)

    assert {findings.undeclared, findings.unfound} == {[], []},
           "set equality must be GREEN here — the closed-volume rule has to fire on its own"

    refute a4b_clean?(findings)
    assert [%{path: _, entry_line: 3}] = findings.not_closed_and_pinned
    assert message =~ "records citing a volume that is not closed-and-pinned"
    assert message =~ ~s(volume status: "current")
  end

  # ── A4b (known_unparseable_at) — ISS-0833's escape hatch ────────────────────
  #
  # Design `iss0833-a4b-unparseable-at-declaration.md` §4. Same throwaway-
  # fixture-directory convention as negative controls 1/2 above: nothing here
  # reads or writes the real index or a real volume. Each fixture entry has
  # the `at:` slot occupied by an undocumented `summary:` field (an
  # unparseable YAML fold marker, `">"`) and the real timestamp two lines
  # later under an undocumented `timestamp:` field -- the exact shape of the
  # 9 real REQ-405/409-416 entries the design fixes.

  test "A4b (known_unparseable_at, positive): a correctly-declared exemption citing a real, parseable sibling suppresses the finding and is itself valid" do
    dir = fixture_dir("a4b-unparseable-pos")

    write_volume!(Path.join(dir, "v1.yaml"), [
      unparseable_entry("REQ-100", "done", ">", "2026-08-21T00:00:00Z")
    ])

    write_volume!(Path.join(dir, "v2.yaml"), [conforming_entry("REQ-002", "started")])

    write_index!(Path.join(dir, "index.yaml"), dir,
      shape_records: [
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "misnamed_field",
          field: "at",
          found_as: "summary",
          found_line: 6
        },
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "extra_field",
          field: "timestamp",
          found_line: 8
        }
      ],
      unparseable_records: [
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          found_as: "summary",
          found_line: 6,
          verified_via_field: "timestamp",
          verified_via_found_line: 8
        }
      ]
    )

    findings = a4b_findings(Path.join(dir, "index.yaml"))

    assert findings.unparseable_at == [],
           "a correctly cross-referenced exemption must suppress the unparseable_at finding"

    assert findings.invalid_unparseable_at_exemptions == [],
           "a correctly cross-referenced exemption must not itself be reported as invalid"

    assert a4b_clean?(findings), a4b_message(Path.join(dir, "index.yaml"), findings)
  end

  test "A4b (known_unparseable_at, negative control A): a citation of a sibling absent from known_shape_anomalies: is caught as an invalid exemption, and the original finding still fires" do
    dir = fixture_dir("a4b-unparseable-neg-a")

    write_volume!(Path.join(dir, "v1.yaml"), [
      unparseable_entry("REQ-100", "done", ">", "2026-08-21T00:00:00Z")
    ])

    write_volume!(Path.join(dir, "v2.yaml"), [conforming_entry("REQ-002", "started")])

    write_index!(Path.join(dir, "index.yaml"), dir,
      shape_records: [
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "misnamed_field",
          field: "at",
          found_as: "summary",
          found_line: 6
        },
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "extra_field",
          field: "timestamp",
          found_line: 8
        }
      ],
      unparseable_records: [
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          found_as: "summary",
          found_line: 6,
          # Orphaned: no known_shape_anomalies: record exists at this
          # {path, entry_line, kind: extra_field, field, found_line} -- the
          # real extra_field sibling is declared at found_line 8, not 999.
          verified_via_field: "timestamp",
          verified_via_found_line: 999
        }
      ]
    )

    findings = a4b_findings(Path.join(dir, "index.yaml"))

    assert [%{path: _, entry_line: 3, field: "summary", value: ">"}] = findings.unparseable_at,
           "an orphaned citation must not apply -- the original unparseable_at finding still fires"

    assert [%{entry_line: 3, verified_via_found_line: 999}] =
             findings.invalid_unparseable_at_exemptions,
           "the bogus exemption itself must be reported, naming the orphaned citation"
  end

  test "A4b (known_unparseable_at, negative control B): a citation of a real sibling whose on-disk value does not parse is caught as an invalid exemption, and the original finding still fires" do
    dir = fixture_dir("a4b-unparseable-neg-b")

    write_volume!(Path.join(dir, "v1.yaml"), [
      # verified_via correctly cites the real, declared "timestamp" extra
      # field -- but its ACTUAL on-disk content is a run-id, not a timestamp.
      unparseable_entry("REQ-100", "done", ">", "WF02-REQ100-20260927")
    ])

    write_volume!(Path.join(dir, "v2.yaml"), [conforming_entry("REQ-002", "started")])

    write_index!(Path.join(dir, "index.yaml"), dir,
      shape_records: [
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "misnamed_field",
          field: "at",
          found_as: "summary",
          found_line: 6
        },
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "extra_field",
          field: "timestamp",
          found_line: 8
        }
      ],
      unparseable_records: [
        %{
          path: Path.join(dir, "v1.yaml"),
          entry_line: 3,
          req: "REQ-100",
          found_as: "summary",
          found_line: 6,
          verified_via_field: "timestamp",
          verified_via_found_line: 8
        }
      ]
    )

    findings = a4b_findings(Path.join(dir, "index.yaml"))

    assert [%{path: _, entry_line: 3, field: "summary", value: ">"}] = findings.unparseable_at,
           "a sibling that is real but does not itself parse must not exempt the finding"

    assert [%{entry_line: 3, verified_via_found_line: 8}] =
             findings.invalid_unparseable_at_exemptions,
           "the exemption citing a non-parseable sibling must itself be reported"
  end

  test "A4b (known_unparseable_at, negative control C): a citation of an open, unpinned volume is caught even though the sibling genuinely parses" do
    dir = fixture_dir("a4b-unparseable-neg-c")

    # Structurally identical to the positive fixture, except the entry lives
    # in v2 -- the CURRENT (open, unpinned) volume -- rather than v1.
    write_volume!(Path.join(dir, "v1.yaml"), [conforming_entry("REQ-001", "done")])

    write_volume!(Path.join(dir, "v2.yaml"), [
      unparseable_entry("REQ-100", "done", ">", "2026-08-21T00:00:00Z")
    ])

    write_index!(Path.join(dir, "index.yaml"), dir,
      shape_records: [
        %{
          path: Path.join(dir, "v2.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "misnamed_field",
          field: "at",
          found_as: "summary",
          found_line: 6
        },
        %{
          path: Path.join(dir, "v2.yaml"),
          entry_line: 3,
          req: "REQ-100",
          event: "done",
          kind: "extra_field",
          field: "timestamp",
          found_line: 8
        }
      ],
      unparseable_records: [
        %{
          path: Path.join(dir, "v2.yaml"),
          entry_line: 3,
          req: "REQ-100",
          found_as: "summary",
          found_line: 6,
          verified_via_field: "timestamp",
          verified_via_found_line: 8
        }
      ]
    )

    findings = a4b_findings(Path.join(dir, "index.yaml"))

    # Empirically (verified against the shipped code, not assumed): the
    # shipped `exempt_unparseable_at?/3` has no pinning check inline (design
    # §2.4) -- so the exemption itself DOES apply, and `unparseable_at` stays
    # empty for this entry. What catches the open volume is the SAME
    # pre-existing `not_closed_and_pinned` sub-check that already runs over
    # every `known_shape_anomalies:` record -- both the `misnamed_field` and
    # `extra_field` records here cite v2 and are rejected by it, exactly as
    # negative control 2 above demonstrates for the pre-ISS-0833 mechanism.
    assert findings.unparseable_at == [],
           "exempt_unparseable_at?/3 has no inline pinning check (design §2.4) -- the exemption applies regardless of volume status"

    refute a4b_clean?(findings)

    citing_v2? = &(&1.path == Path.join(dir, "v2.yaml") and &1.entry_line == 3)

    assert Enum.count(findings.not_closed_and_pinned, citing_v2?) == 2,
           "both the misnamed_field and extra_field known_shape_anomalies: records citing " <>
             "the open v2 volume must fail the pre-existing closed-and-pinned rule"

    # The known_unparseable_at: record's OWN pinning is checked independently
    # in invalid_unparseable_at_exemptions/4 (§2.3 step 5) -- so it is ALSO
    # reported there, not just via not_closed_and_pinned.
    assert [%{entry_line: 3, verified_via_found_line: 8}] =
             findings.invalid_unparseable_at_exemptions
  end

  # ── A5 ──────────────────────────────────────────────────────────────────────

  test "A5: the on-disk vocabulary-anomaly set equals the index's declared set exactly, and every declared record cites a closed, pinned, warranted volume" do
    index = SH.parse_index(@index_path)
    volumes = Map.new(index.volumes, &{&1.path, &1})
    roll_rule = index.roll_rule

    on_disk =
      index.volumes
      |> Enum.flat_map(&SH.anomalies(&1.path, @legal_reqs, @legal_events))
      |> MapSet.new()

    declared =
      index.known_anomalies
      |> Enum.map(&Map.take(&1, [:path, :line, :field, :value]))
      |> MapSet.new()

    not_closed_pinned_warranted =
      Enum.reject(index.known_anomalies, &closed_pinned_and_warranted?(volumes, roll_rule, &1))

    closed_rule =
      case not_closed_pinned_warranted do
        [] ->
          "      (none)"

        records ->
          Enum.map_join(records, "\n", fn record ->
            "      path=#{record.path} line=#{inspect(Map.get(record, :line))} " <>
              "req=#{inspect(Map.get(record, :req))} field=#{inspect(Map.get(record, :field))} " <>
              "value=#{inspect(Map.get(record, :value))}  -> " <>
              disqualification(volumes, roll_rule, record)
          end)
      end

    assert on_disk == declared and not_closed_pinned_warranted == [], """
    A5 — the declared anomaly set does not match disk, or cites a volume that
    is not closed, pinned, and warranted.

      on disk but NOT declared (new drift):
    #{indent(MapSet.difference(on_disk, declared))}

      declared but NOT on disk (a past entry was silently normalised or deleted
      — the exact act the append-only rule forbids):
    #{indent(MapSet.difference(declared, on_disk))}

      records citing a volume that is not closed, pinned, and warranted (#{length(not_closed_pinned_warranted)}):
    #{closed_rule}

      A `known_anomalies:` record may cite ONLY a volume whose `volumes:` entry
      is `status: closed`, carries a `frozen_prefix_sha256:`, AND actually
      exceeded `roll_rule` at closure (design §13.6, §13.12.4). This fires on
      its own, independently of the set-equality checks above, and even when
      the violation it cites genuinely exists on disk. A vocabulary defect in
      the CURRENT volume is FIXED in the working tree before it is committed --
      it can never be declared away here.
    """
  end

  # ── A6 ──────────────────────────────────────────────────────────────────────

  test "A6: every closed volume's frozen prefix still hashes to its recorded digest" do
    index = SH.parse_index(@index_path)
    closed = Enum.filter(index.volumes, &(&1.status == "closed"))

    assert closed != [], "A6 — the index declares no closed volume; expected at least volume 1."

    for volume <- closed do
      actual = SH.frozen_prefix_digest(volume.path, volume.frozen_prefix_lines)

      assert actual == volume.frozen_prefix_sha256, """
      A6 — CLOSED VOLUME #{volume.volume} HAS BEEN MODIFIED.

        path:     #{volume.path}
        prefix:   first #{volume.frozen_prefix_lines} lines
        recorded: #{volume.frozen_prefix_sha256}
        actual:   #{actual}

      A closed volume is frozen: no entry in it may be edited, reordered,
      renumbered or deleted, ever. If a line above the closure footer changed,
      revert it. The hashed byte stream is design §8's convention — every line
      terminated by a single \\n including the last; terminators are trimmed
      "\\n" first then "\\r", never the two-byte "\\r\\n" (§8 erratum, Step 3d),
      so the digest is identical on a CRLF and an LF checkout.
      """
    end
  end

  # ── A7 ──────────────────────────────────────────────────────────────────────

  test "A7: every closed volume's footer names the next volume in the index" do
    index = SH.parse_index(@index_path)
    ordered = Enum.sort_by(index.volumes, & &1.volume)

    breaks =
      ordered
      |> Enum.chunk_every(2, 1)
      |> Enum.flat_map(fn
        [%{status: "closed"} = closed, successor] ->
          footer = SH.closure_footer(closed.path)

          cond do
            is_nil(footer) ->
              [%{volume: closed.volume, problem: :no_closure_footer}]

            not String.contains?(footer, successor.path) ->
              [
                %{
                  volume: closed.volume,
                  problem: :footer_does_not_name_successor,
                  expected: successor.path
                }
              ]

            true ->
              []
          end

        [%{status: "closed"} = closed] ->
          [%{volume: closed.volume, problem: :closed_volume_has_no_successor}]

        _ ->
          []
      end)

    assert breaks == [], """
    A7 — the volume chain is broken.

    #{indent(breaks)}

    Every closed volume must carry a closure footer naming the path of the next
    volume, and that path must be the next volume in the index. A closed volume
    with no successor, or a footer pointing somewhere else, strands an agent that
    arrives at a closed volume instead of the index.
    """
  end

  # ── A8 ──────────────────────────────────────────────────────────────────────

  test "A8: the current volume's header documents the full vocabulary and the real ceilings" do
    index = SH.parse_index(@index_path)
    {:index, current_path} = SH.current_volume(@index_path, @status_dir)
    header = SH.header(current_path)

    %{max_lines: max_lines, max_bytes: max_bytes} = index.roll_rule

    missing_vocabulary =
      Enum.reject(@legal_events ++ ["REQ-NNN", "SCOPE-CHANGE"], &String.contains?(header, &1))

    # The two ceiling restatements design §7/A8 names, rebuilt from the index —
    # so the index stays the single source of truth and a header that drifts
    # from it fails here rather than misleading an appending agent.
    prose_ceilings = "under #{thousands(max_lines)} lines / #{thousands(max_bytes)} bytes"
    rule_ceilings = "lines > #{max_lines} OR bytes > #{max_bytes}"

    missing_ceilings =
      Enum.reject([prose_ceilings, rule_ceilings], &String.contains?(header, &1))

    # Clause (c), design §13.7: the header must carry the literal
    # `known_shape_anomalies:` token, so a future volume opened by copying this
    # header cannot silently drop the shape declaration at roll time.
    missing_declarations =
      Enum.reject(["known_shape_anomalies:"], &String.contains?(header, &1))

    actual = {missing_vocabulary, missing_ceilings, missing_declarations, SH.default_ceilings()}
    expected = {[], [], [], {max_lines, max_bytes}}

    assert actual == expected, """
    A8 — the current volume's header is incomplete or has drifted from the index.

      volume: #{current_path}

      vocabulary tokens the header never names: #{inspect(missing_vocabulary)}
      ceiling restatements the header never names: #{inspect(missing_ceilings)}
      declaration keys the header never names: #{inspect(missing_declarations)}

      index roll_rule:              #{max_lines} lines / #{max_bytes} bytes
      StatusHistory.default_ceilings/0: #{inspect(SH.default_ceilings())}

    The header is the copy an appending agent actually reads. A volume opened by
    copy-paste error, a vocabulary extension that skips the header, a ceiling
    changed in the index but not in the header, or a roll that drops the
    `known_shape_anomalies:` declaration (clause (c), design §13.7), all land
    here.
    """
  end

  # ── A9 — entries: is derived, not merely declared (ISS-0199 finding 2) ──────

  test "A9: every indexed volume's declared entries: count equals what is actually on disk" do
    index = SH.parse_index(@index_path)

    mismatches =
      index.volumes
      |> Enum.map(fn v -> {v.path, v.entries, length(SH.entries(v.path))} end)
      |> Enum.reject(fn {_path, declared, actual} -> declared == actual end)

    assert mismatches == [], """
    A9 — a volume's declared entries: count has drifted from what is on disk.

      (path, declared entries:, actual entries on disk) for each mismatch:
      #{inspect(mismatches)}

    The declared count is a convenience for a reader who has not opened the
    volume; it must never silently go stale. Update it in the same commit that
    appends (HOW-TO-APPEND step 6) or that rolls a volume (roll rule step 3).
    ISS-0199 found volume 2 declared at 0 with 7 real entries already on disk —
    this assertion is what would have caught that.
    """
  end

  # ── A10 — a closed volume's closure was warranted (ISS-0193, design §13.12.4) ─

  test "A10: every closed volume actually exceeded a ceiling at closure -- its closure was warranted" do
    index = SH.parse_index(@index_path)
    roll_rule = index.roll_rule
    closed = Enum.filter(index.volumes, &(&1.status == "closed"))

    assert closed != [], "A10 — the index declares no closed volume; expected at least volume 1."

    unwarranted =
      Enum.reject(closed, &SH.warranted_closure?(&1, roll_rule.max_lines, roll_rule.max_bytes))

    assert unwarranted == [], """
    A10 — A CLOSED VOLUME'S CLOSURE WAS NOT WARRANTED.

    #{Enum.map_join(unwarranted, "\n", fn v -> "  volume #{v.volume} (#{v.path}): lines=#{inspect(Map.get(v, :lines))} " <> "bytes_working_tree=#{inspect(Map.get(v, :bytes_working_tree))}, ceilings: " <> "#{roll_rule.max_lines} lines / #{roll_rule.max_bytes} bytes " <> "— closed without exceeding either ceiling — closure was not warranted" end)}

    A volume may only be rolled to `closed` when it actually exceeded
    `roll_rule`'s ceilings (design §13.12.4, ISS-0193). Without this check, a
    volume could be closed early -- with `lines:`/`bytes_working_tree:` still
    under both ceilings -- in the same commit that declares a defect against
    it, satisfying "closed and pinned" (A4b/A5's own rule) without ever having
    been a legitimate roll. That would let a fresh defect in what is really
    still an appendable volume be declared away instead of fixed in the
    working tree.
    """
  end

  # ── A11 — every on-disk entry's list item is at the documented 2-space
  #         indent (ISS-0883 finding) ──────────────────────────────────────

  test "A11: every on-disk entry's list item uses the documented 2-space indent" do
    index = SH.parse_index(@index_path)

    violations =
      index.volumes
      |> Enum.flat_map(fn v ->
        v.path
        |> SH.entries()
        |> Enum.filter(&(&1.indent != 2))
        |> Enum.map(&{v.path, &1.line, &1.indent, &1.req})
      end)

    assert violations == [], """
    A11 — an entry's `- req:` list item is not at the documented 2-space indent.

      (path, line, actual indent in spaces, req) for each violation:
      #{inspect(violations)}

    The 2-space indent is documented in every volume's own header (ENTRY SCHEMA)
    and is what HOW-TO-APPEND's append procedure must produce. An entry at the
    wrong indent is still counted correctly by A9's on-disk total (entries/1 is
    indentation-tolerant), but it is malformed relative to the documented
    convention regardless of whether the declared `entries:` count happens to
    still be correct — fix the indent in the volume file itself; do not fix this
    by changing the convention or adding an exemption, since this is a
    mechanical formatting rule, not content that legitimately varies.
    """
  end

  # ── warranted_closure?/3 — direct unit coverage of its three own traps ──────
  #
  # A10 above and the negative controls below exercise warranted_closure?/3
  # only through fully-under-ceiling or fully-over-ceiling fixtures, which
  # cannot discriminate an "either" ceiling check from a "both" one, nor an
  # accidentally-dropped status gate, nor a silently-defaulted missing field.
  # These three tests target exactly those traps directly.

  test "warranted_closure?/3: EITHER ceiling exceeded is sufficient -- not both" do
    # lines over, bytes under -- an "and" mutant on the ceiling comparison
    # would wrongly report this volume as not warranted.
    assert SH.warranted_closure?(
             %{status: "closed", lines: 2000, bytes_working_tree: 10},
             1200,
             120_000
           )

    # bytes over, lines under -- same trap, the other operand.
    assert SH.warranted_closure?(
             %{status: "closed", lines: 10, bytes_working_tree: 200_000},
             1200,
             120_000
           )
  end

  test "warranted_closure?/3: a non-closed volume is never warranted, even if grossly over ceiling" do
    refute SH.warranted_closure?(
             %{status: "current", lines: 999_999, bytes_working_tree: 999_999},
             1200,
             120_000
           )
  end

  test "warranted_closure?/3: raises rather than silently defaulting when a closed volume has no recorded lines:/bytes_working_tree:" do
    assert_raise KeyError, fn ->
      SH.warranted_closure?(%{status: "closed"}, 1200, 120_000)
    end

    # lines: 10 is UNDER max_lines, so the `or` cannot short-circuit true
    # before reaching bytes_working_tree: -- this is the case that forces
    # Map.fetch! to actually look up the missing field.
    assert_raise KeyError, fn ->
      SH.warranted_closure?(%{status: "closed", lines: 10}, 1200, 120_000)
    end
  end

  # ── A10 negative control — proof the assertion actually bites ──────────────
  #
  # This is the MINOR-4 laundering scenario CODE-DESIGN-VALIDATOR's own finding
  # named: a volume closed with its recorded size still under BOTH ceilings.
  # Exercised directly against `SH.warranted_closure?/3` and the shared
  # `closed_pinned_and_warranted?/3` helper -- the exact functions A10, A4b, and
  # A5 all call -- with synthetic volume/record maps, so nothing here touches
  # the real index or a real volume file.

  test "A10 (negative control): a closed volume that did NOT exceed either ceiling is correctly reported as unwarranted" do
    roll_rule = %{max_lines: 1200, max_bytes: 120_000}

    unwarranted_volume = %{
      volume: 99,
      path: "fixture/unwarranted.yaml",
      status: "closed",
      lines: 10,
      bytes_working_tree: 500,
      frozen_prefix_sha256: "deadbeef"
    }

    refute SH.warranted_closure?(unwarranted_volume, roll_rule.max_lines, roll_rule.max_bytes),
           "A10's own instrument must report an under-ceiling closed volume as NOT warranted"

    volumes = %{unwarranted_volume.path => unwarranted_volume}
    record = %{path: unwarranted_volume.path}

    refute closed_pinned_and_warranted?(volumes, roll_rule, record),
           "closed_pinned_and_warranted?/3 must reject a record citing an unwarranted closure " <>
             "even though the volume IS closed and IS pinned"

    assert disqualifying_reason(volumes, roll_rule, record) == :not_warranted
  end

  # ── A5 negative control — an open-volume known_anomalies: record must fail ──
  #
  # Mirrors A4b's own negative control 2: a record whose `path:` names the
  # CURRENT (open, unpinned) volume must fail the shared closed-and-pinned rule
  # -- this is what stops `known_anomalies:` from becoming a declare-to-silence
  # mechanism for a fresh vocabulary defect in the current volume.

  test "A5 (negative control): a known_anomalies: record citing an open, unpinned volume fails the closed-and-pinned-and-warranted rule" do
    roll_rule = %{max_lines: 1200, max_bytes: 120_000}

    open_volume = %{
      volume: 2,
      path: "fixture/current.yaml",
      status: "current"
    }

    volumes = %{open_volume.path => open_volume}
    record = %{path: open_volume.path}

    refute closed_pinned_and_warranted?(volumes, roll_rule, record),
           "a record citing an open (status: current) volume must never pass the shared rule"

    assert disqualifying_reason(volumes, roll_rule, record) == :not_closed
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # ── A4b: findings, verdict and the §13.5-specified failure output ───────────
  #
  # Design §13.5 makes A4b's message part of the CONTRACT, not an implementer's
  # choice, because §13.9 lists `mix test` as one of the four places a reader
  # learns about the three volume-1 shape anomalies. So the message names EVERY
  # element of the symmetric difference, one per line, labelled by side, plus
  # every record that failed the closed-volume rule with the status that
  # disqualified it. A count is explicitly not sufficient.
  #
  # The closed-and-pinned rule is computed INDEPENDENTLY of set equality and is
  # reported alongside it rather than after it — folding the two together, or
  # short-circuiting one on the other, would lose exactly the property
  # CODE-DESIGN-VALIDATOR failed §13's first version for missing: a record must
  # fail for citing an open volume EVEN WHEN the violation it cites really is on
  # disk. (Negative control 2 above is the standing proof that it does.)

  defp a4b_findings(index_path) do
    index = SH.parse_index(index_path)
    volumes = Map.new(index.volumes, &{&1.path, &1})
    declared = index.known_shape_anomalies
    on_disk = Enum.flat_map(index.volumes, &SH.shape_anomalies(&1.path))

    on_disk_keys = MapSet.new(on_disk, &a4b_key/1)
    declared_keys = MapSet.new(declared, &a4b_key/1)

    entry_index =
      Map.new(index.volumes, fn volume ->
        {volume.path, Map.new(SH.entries(volume.path), &{&1.line, &1})}
      end)

    %{
      undeclared: Enum.reject(on_disk, &MapSet.member?(declared_keys, a4b_key(&1))),
      unfound: Enum.reject(declared, &MapSet.member?(on_disk_keys, a4b_key(&1))),
      not_closed_and_pinned:
        Enum.reject(declared, &closed_pinned_and_warranted?(volumes, index.roll_rule, &1)),
      misattributed: Enum.filter(declared, &misattributed?(entry_index, &1)),
      unparseable_at: unparseable_at(index.volumes, declared, index.known_unparseable_at),
      invalid_unparseable_at_exemptions:
        invalid_unparseable_at_exemptions(
          index.volumes,
          index.roll_rule,
          declared,
          index.known_unparseable_at
        )
    }
  end

  defp a4b_clean?(findings) do
    Enum.all?(
      [
        :undeclared,
        :unfound,
        :not_closed_and_pinned,
        :misattributed,
        :unparseable_at,
        :invalid_unparseable_at_exemptions
      ],
      &(Map.fetch!(findings, &1) == [])
    )
  end

  defp a4b_key(record) do
    {record.path, Map.get(record, :entry_line), Map.get(record, :kind), Map.get(record, :field),
     Map.get(record, :found_as)}
  end

  # A declared record may only cite a volume that is `status: closed`, carries
  # a `frozen_prefix_sha256:`, AND actually exceeded `roll_rule` at closure
  # (design §13.5, §13.6, §13.12.4 -- the ISS-0193 A10 amendment). This is the
  # ONE shared implementation of that comparison: both A4b's
  # `not_closed_and_pinned` finding (over `known_shape_anomalies:` records) and
  # A5's equivalent finding (over `known_anomalies:` records) call this same
  # function with their own record list -- the roll-rule comparison itself is
  # written exactly once, in `SH.warranted_closure?/3`.
  defp closed_pinned_and_warranted?(volumes, roll_rule, record) do
    disqualifying_reason(volumes, roll_rule, record) == nil
  end

  # `nil` when the record is not disqualified. Otherwise one of `:not_closed`,
  # `:not_pinned`, `:not_warranted` -- used only for message construction
  # (design §13.12.4), never for the pass/fail verdict, which stays the single
  # boolean `closed_pinned_and_warranted?/3` above returns.
  defp disqualifying_reason(volumes, roll_rule, record) do
    case Map.get(volumes, record.path) do
      nil ->
        :not_closed

      volume ->
        cond do
          Map.get(volume, :status) != "closed" ->
            :not_closed

          not is_binary(Map.get(volume, :frozen_prefix_sha256)) ->
            :not_pinned

          not SH.warranted_closure?(volume, roll_rule.max_lines, roll_rule.max_bytes) ->
            :not_warranted

          true ->
            nil
        end
    end
  end

  defp disqualification(volumes, roll_rule, record) do
    case Map.get(volumes, record.path) do
      nil ->
        "path is not a volume in the index at all"

      volume ->
        case disqualifying_reason(volumes, roll_rule, record) do
          :not_closed ->
            ~s(volume status: #{inspect(Map.get(volume, :status))} \(must be "closed"\))

          :not_pinned ->
            "volume has no frozen_prefix_sha256: (not digest-pinned)"

          :not_warranted ->
            "volume status: closed, lines: #{inspect(Map.get(volume, :lines))}, " <>
              "bytes_working_tree: #{inspect(Map.get(volume, :bytes_working_tree))}, " <>
              "ceilings: #{roll_rule.max_lines} lines / #{roll_rule.max_bytes} bytes " <>
              "-- closed without exceeding either ceiling -- closure was not warranted"

          nil ->
            "ok"
        end
    end
  end

  defp misattributed?(entry_index, record) do
    case entry_index |> Map.get(record.path, %{}) |> Map.get(record.entry_line) do
      # An unknown path is reported by the closed-volume rule, not here.
      nil -> Map.has_key?(entry_index, record.path)
      entry -> entry.req != record.req or entry.event != record.event
    end
  end

  defp unparseable_at(volumes, declared, exemptions) do
    from_disk =
      for volume <- volumes,
          entry <- SH.entries(volume.path),
          not is_nil(entry.at),
          not parseable_iso8601?(entry.at),
          do: %{path: volume.path, entry_line: entry.line, field: "at", value: entry.at}

    # Declaring the field NAME wrong does not license an unparseable timestamp
    # (design §13.5) -- UNLESS a `known_unparseable_at:` record exempts this
    # exact finding, and that exemption re-verifies against disk (design
    # `iss0833-a4b-unparseable-at-declaration.md` §2.3). This reject-pass is
    # applied ONLY to `from_declared` candidates, never to `from_disk` ones: a
    # correctly-named `at:` field that is itself unparseable has no
    # `misnamed_field` companion record to hang a `verified_via` citation off
    # of, and must stay structurally impossible to exempt via this mechanism
    # (design §3.4).
    from_declared =
      for record <- declared,
          Map.get(record, :kind) == "misnamed_field",
          Map.get(record, :field) == "at",
          is_integer(Map.get(record, :found_line)),
          File.exists?(record.path),
          value = value_at(record.path, record.found_line),
          not parseable_iso8601?(value),
          candidate = %{
            path: record.path,
            entry_line: record.entry_line,
            field: record.found_as,
            value: value
          },
          not exempt_unparseable_at?(exemptions, declared, candidate),
          do: candidate

    from_disk ++ from_declared
  end

  # §2.3 steps 1-4 of the design: look up a `known_unparseable_at:` record
  # citing this exact candidate, confirm its cited `known_shape_anomalies:`
  # sibling genuinely exists in the declared set, confirm that sibling's
  # `found_line` is a REAL, currently-true shape anomaly (not just a stale
  # declaration), then re-read that line's actual on-disk text and re-parse
  # it. Never trusts the exemption's own prose -- every fact is re-derived.
  defp exempt_unparseable_at?(exemptions, known_shape_anomalies, candidate) do
    Enum.any?(exemptions, fn x ->
      x.path == candidate.path and x.entry_line == candidate.entry_line and
        x.found_as == candidate.field and
        Enum.any?(known_shape_anomalies, fn s ->
          s.path == x.path and s.entry_line == x.entry_line and s.kind == "extra_field" and
            s.field == x.verified_via_field and s.found_line == x.verified_via_found_line
        end) and
        Enum.any?(SH.shape_anomalies(x.path), fn s ->
          s.path == x.path and s.entry_line == x.entry_line and s.kind == "extra_field" and
            s.field == x.verified_via_field and s.found_line == x.verified_via_found_line
        end) and
        File.exists?(x.path) and
        parseable_iso8601?(value_at(x.path, x.verified_via_found_line))
    end)
  end

  # The new 6th A4b sub-check (design §2.4/§2.5's "6th sub-check"). Any
  # declared `known_unparseable_at:` record that fails verification is a LOUD,
  # reported failure, not a silent no-op -- this is what makes a bogus
  # declaration (orphaned citation, non-parseable sibling, or a citation of a
  # volume that is not closed-and-pinned) visibly wrong rather than inert.
  defp invalid_unparseable_at_exemptions(volumes, roll_rule, known_shape_anomalies, exemptions) do
    volumes_by_path = Map.new(volumes, &{&1.path, &1})

    Enum.reject(exemptions, fn x ->
      sibling_declared? =
        Enum.any?(known_shape_anomalies, fn s ->
          s.path == x.path and s.entry_line == x.entry_line and s.kind == "extra_field" and
            s.field == x.verified_via_field and s.found_line == x.verified_via_found_line
        end)

      sibling_on_disk? =
        File.exists?(x.path) and
          Enum.any?(SH.shape_anomalies(x.path), fn s ->
            s.path == x.path and s.entry_line == x.entry_line and s.kind == "extra_field" and
              s.field == x.verified_via_field and s.found_line == x.verified_via_found_line
          end)

      sibling_parseable? =
        File.exists?(x.path) and parseable_iso8601?(value_at(x.path, x.verified_via_found_line))

      pinned? = closed_pinned_and_warranted?(volumes_by_path, roll_rule, x)

      sibling_declared? and sibling_on_disk? and sibling_parseable? and pinned?
    end)
  end

  defp value_at(path, line_number) do
    line =
      path
      |> File.read!()
      |> String.split(~r/\r?\n/)
      |> Enum.at(line_number - 1)

    case line && Regex.run(~r/^\s*[a-z][a-z0-9_]*: ?(.*)$/, line) do
      [_, value] -> value |> String.trim() |> String.trim("\"")
      _ -> nil
    end
  end

  defp a4b_message(index_path, findings) do
    index = SH.parse_index(index_path)
    volumes = Map.new(index.volumes, &{&1.path, &1})
    roll_rule = index.roll_rule

    closed_rule =
      case findings.not_closed_and_pinned do
        [] ->
          "      (none)"

        records ->
          Enum.map_join(records, "\n", fn record ->
            "      " <>
              a4b_line(record) <> "  -> " <> disqualification(volumes, roll_rule, record)
          end)
      end

    """
    A4b — ENTRY SHAPE DOES NOT AGREE WITH THE INDEX.

    An entry conforms when it carries exactly #{inspect(SH.entry_field_order())},
    in that order, with a parseable ISO-8601 `at:`. Exceptions live in the
    index's `known_shape_anomalies:` and must match disk EXACTLY, in BOTH
    directions (design §13.5).

      on disk but not declared (#{length(findings.undeclared)}) — NEW DRIFT:
    #{a4b_lines(findings.undeclared)}

      declared but not on disk (#{length(findings.unfound)}) — a past entry was
      silently normalised or deleted, the act the append-only rule forbids:
    #{a4b_lines(findings.unfound)}

      records citing a volume that is not closed-and-pinned (#{length(findings.not_closed_and_pinned)}):
    #{closed_rule}

      A `known_shape_anomalies:` record may cite ONLY a volume whose `volumes:`
      entry is `status: closed` with a `frozen_prefix_sha256:`. This fires on its
      own, independently of the two sets above, and even when the violation it
      cites genuinely exists on disk. A shape defect in the CURRENT volume is
      FIXED in the working tree before it is committed — it can never be declared
      away here, and neither deleting a record nor narrowing the detector is an
      available response (design §13.3, §13.5, §13.10).

      declared records that do not match the entry at their entry_line (#{length(findings.misattributed)}):
    #{a4b_lines(findings.misattributed)}

      unparseable ISO-8601 timestamps (#{length(findings.unparseable_at)}):
    #{a4b_lines(findings.unparseable_at)}

      invalid known_unparseable_at: exemptions (#{length(findings.invalid_unparseable_at_exemptions)}) —
      a declared exemption whose citation does not re-verify against disk (an
      orphaned/fabricated `verified_via` sibling, a sibling that is not itself
      a real, currently-true shape anomaly, a sibling value that does not
      parse as ISO-8601, or a citation of a volume that is not
      closed-and-pinned) is reported here rather than silently accepted:
    #{a4b_lines(findings.invalid_unparseable_at_exemptions)}
    """
  end

  defp a4b_lines([]), do: "      (none)"

  defp a4b_lines(records), do: Enum.map_join(records, "\n", &("      " <> a4b_line(&1)))

  defp a4b_line(record) do
    base = [
      "path=#{record.path}",
      "entry_line=#{inspect(Map.get(record, :entry_line))}",
      "req=#{inspect(Map.get(record, :req))}",
      "kind=#{inspect(Map.get(record, :kind))}"
    ]

    extra =
      for key <- [:field, :found_as, :found_line, :value],
          value = Map.get(record, key),
          not is_nil(value),
          do: "#{key}=#{inspect(value)}"

    Enum.join(base ++ extra, "  ")
  end

  # ── A4b negative-control fixtures ───────────────────────────────────────────
  #
  # Throwaway files under the system tmp dir, removed by on_exit. NOTHING here
  # touches docs/status/ — making A4b green by editing the real index or a real
  # volume is precisely the move design §13.10 forbids.

  defp fixture_dir(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "iss0119-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp conforming_entry(req, event) do
    """
      - req: #{req}
        event: #{event}
        agent: TEST-DESIGNER
        at: "2026-08-21T00:00:00Z"
        note: fixture entry
    """
  end

  defp noteless_entry(req, event) do
    """
      - req: #{req}
        event: #{event}
        agent: TEST-DESIGNER
        at: "2026-08-21T00:00:00Z"
    """
  end

  # ISS-0833 fixture entry: the `at:` slot is occupied by an undocumented
  # `summary:` field (mirroring the 9 real REQ-405/409-416 entries design
  # iss0833-a4b-unparseable-at-declaration.md §1 documents), and the real
  # timestamp sits a couple of lines later under an undocumented `timestamp:`
  # field. `summary_value` and `timestamp_value` are the raw (unquoted) text
  # written after each field's colon -- callers pass an unparseable value
  # (`">"`, a YAML fold marker) for `summary_value`, and either a genuinely
  # ISO-8601 value or a non-parseable one for `timestamp_value`, depending on
  # which fixture is being built.
  #
  # Field/line layout, given `write_volume!`'s fixed 2-line file header (`#
  # fixture volume` / `history:`) and exactly one entry: line 3 `req:`, 4
  # `event:`, 5 `agent:`, 6 `summary:`, 7 `note:`, 8 `timestamp:`.
  defp unparseable_entry(req, event, summary_value, timestamp_value) do
    """
      - req: #{req}
        event: #{event}
        agent: TEST-DESIGNER
        summary: #{summary_value}
        note: fixture note
        timestamp: #{timestamp_value}
    """
  end

  # Line 1 is the comment, line 2 is `history:`, so the first entry's `- req:`
  # line is line 3 — which is what the fixture records cite.
  defp write_volume!(path, entry_blocks) do
    File.write!(path, "# fixture volume\nhistory:\n" <> Enum.join(entry_blocks))
    path
  end

  defp write_index!(path, dir, opts) do
    records =
      opts
      |> Keyword.fetch!(:shape_records)
      |> Enum.map_join("", fn record ->
        """
          - path: #{record.path}
            entry_line: #{record.entry_line}
            req: #{record.req}
            event: #{record.event}
            kind: #{record.kind}
            field: #{record.field}
            found_as: #{Map.get(record, :found_as) || "null"}
            found_line: #{Map.get(record, :found_line) || "null"}
        """
      end)

    # ISS-0833: `known_unparseable_at:` is a sibling section to
    # `known_shape_anomalies:` (design iss0833-a4b-unparseable-at-declaration
    # §2.2/§2.5). Per §2.5, `verified_via:` is NOT a nested mapping on disk --
    # `parse_list/1` only recognises two flat indentation levels -- so it is
    # written as three flat sibling fields (`verified_via_kind`/
    # `verified_via_field`/`verified_via_found_line`). Omitted entirely
    # (rather than emitted empty) when no test passes the option, so every
    # existing call site of this helper is unaffected.
    unparseable_section =
      case Keyword.get(opts, :unparseable_records, []) do
        [] ->
          ""

        unparseable_records ->
          "\nknown_unparseable_at:\n" <>
            Enum.map_join(unparseable_records, "", fn record ->
              """
                - path: #{record.path}
                  entry_line: #{record.entry_line}
                  req: #{record.req}
                  field: at
                  found_as: #{record.found_as}
                  found_line: #{record.found_line}
                  verified_via_kind: extra_field
                  verified_via_field: #{record.verified_via_field}
                  verified_via_found_line: #{record.verified_via_found_line}
                  should_have_been: "at: <the real ISO-8601 timestamp>"
                  cause: "fixture: field misnamed, real value recoverable from a sibling extra_field"
              """
            end)
      end

    File.write!(path, """
    roll_rule:
      max_lines: 1200
      max_bytes: 120000

    volumes:
      - volume: 1
        path: #{Path.join(dir, "v1.yaml")}
        status: closed
        lines: 5766
        bytes_working_tree: 361376
        frozen_prefix_lines: 2
        frozen_prefix_sha256: "0000000000000000000000000000000000000000000000000000000000000000"
      - volume: 2
        path: #{Path.join(dir, "v2.yaml")}
        status: current

    known_anomalies:

    known_shape_anomalies:
    #{String.trim_trailing(records)}
    #{unparseable_section}
    """)

    path
  end

  defp ceiling_source(:index), do: "from the index's roll_rule"
  defp ceiling_source(:no_index_fallback), do: "from StatusHistory.default_ceilings/0"

  defp parseable_iso8601?(value) when is_binary(value) do
    match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp parseable_iso8601?(_), do: false

  defp thousands(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp indent(items) do
    case Enum.to_list(items) do
      [] -> "    (none)"
      list -> Enum.map_join(list, "\n", &("    " <> inspect(&1)))
    end
  end
end
