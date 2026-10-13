defmodule Mix.Tasks.Letflow.CheckDeferralStaleness do
  @shortdoc "Fails when a deferred requirement's stage has become active (a stale deferral)"

  @moduledoc """
  Implements ISS-0258: deferral-staleness detection.

  `mix letflow.check_requirements_registration` (ISS-0231) classifies every
  requirement into `:registered | :deferred | :neither | :unclassified`, and
  its only rule touching `:deferred` is R3 -- fires exactly when the
  rationale is `nil` or `""`. Its roster header states the contract in
  words: *"DEFERRED (visible debt -- always reported, never gates)"*.

  So *any* non-empty rationale satisfies R3 forever. There is no time
  dimension and no re-evaluation against the world. A requirement deferred
  with a once-true reason stays green after that reason stops being true.
  That is the ISS-0221 failure mode -- a validated-looking requirement
  no worker is ever offered, whose only symptom is an idle pipeline --
  displaced one layer up. `UNREGISTERED` is now watched; **`DEFERRED` is
  the state nothing watches.**

  The root cause is not a bug in ISS-0231's logic. It is a **missing
  invariant**: the project has a written rule for *whether a deferral is
  documented* and no rule at all for *whether a deferral is still
  justified*. Free text is unfalsifiable by construction. This task adds
  the missing half.

  ## What "stale" means -- the activity derivation

  Stage activity is **not a readable field**. A `stages:` entry carries
  `id`, `name`, `description`, `depends_on`, `detail_file` and no status of
  any kind, so activity must be *derived* from the per-requirement
  `status:` values of the requirements assigned to that stage:

  > A stage is `:active` iff at least one requirement assigned to it --
  > **excluding the requirement currently under test** -- has a status in
  > `#{inspect([:done, :in_progress, :blocked])}`. `:pending` and
  > `:cancelled` do not confer activity. `:unknown` confers nothing and
  > separately hard-fails.

  Status by status, and why:

    * `:done` -- **active**. Work in the stage completed, so the stage is
      demonstrably underway. Removing `:done` from the set makes the whole
      derivation vacuous and reproduces ISS-0258 *inside its own fix*.
    * `:in_progress` -- **active**, definitionally.
    * `:blocked` -- **active**. `blocked` is not reachable from the initial
      state without someone starting the work and recording an impediment;
      that is engagement, not idleness. The error costs are also
      asymmetric: a missed stale deferral is silent and unfalsifiable (the
      whole reason this issue exists), while a false positive is loud,
      named by `REQ-NNN`, printed with its witnesses, and closable in one
      line.
    * `:pending` -- **not active**. The initial state carries no
      information that work began. Counting it would make every stage that
      has any requirement at all active, flagging every deferral that has
      ever been written.
    * `:cancelled` -- **not active. Abandonment is not activity.** Measured
      rather than asserted: S8 held `1 cancelled + 10 pending` when the
      project's 21 historical deferrals existed, so counting `cancelled`
      would have flipped 9 known-good deferrals from legitimate to stale.

  A stage with **no** requirements is `:inactive` by the same rule, not by
  a special case: the empty set contains no active status.

  ### Self-exclusion

  The entry under test is excluded from its own stage's activity set.
  Without it, a deferred requirement that is itself `done` would activate
  its own stage and flag itself -- an unfixable red. This is not gameable:
  the exclusion is of *the entry under test from its own computation*, not
  of deferred entries generally, so two deferred entries in one stage do
  not mutually excuse each other. The one case it deliberately declines to
  judge -- a lone deferred entry that is itself `done`/`in_progress`/
  `blocked` -- is *annotated* on the roster and never gated, because that
  anomaly is registration-shaped, not staleness-shaped.

  ## The escape hatch: `blocked-by: REQ-NNN`

  A deferral scoped to a sibling *requirement* rather than to a whole stage
  is legitimate inside an active stage, and a bare stage-activity rule
  would flag it. The hatch is a recognised scope prefix parsed out of the
  existing rationale text -- no new field, no schema change:

      # impl_order: UNREGISTERED -- blocked-by: REQ-042 -- <free-text rationale>

  Four properties, each load-bearing, plus acyclicity:

    * **Anchored to the start of the rationale.** An unanchored match would
      let prose that merely *mentions* the form activate the hatch.
    * **The named id must exist in the corpus** (S3). A dangling reference
      would be a permanent unfalsifiable suppression -- this issue again.
    * **The blocker's status is checked, and the hatch expires** (S3). If
      the blocker is `done` or `cancelled` the deferral is stale again. The
      hatch is not an exemption; it is a machine-checkable assertion that
      goes stale on its own. Self-reference is rejected for the same
      reason.
    * **Free text after the hatch is still required**, so R3's spirit -- a
      human-readable reason -- survives the hatch rather than being
      replaced by it.
    * **The hatch graph must be acyclic** (S6). `REQ-A -- blocked-by:
      REQ-B` together with `REQ-B -- blocked-by: REQ-A` satisfies all four
      properties above and *never expires*, precisely because neither
      member can reach `done` or `cancelled` while it waits on the other.
      A cycle is an exception list of size >= 2 written in rationale text.

  ## Rules (any violation => non-zero exit)

    * **S1** -- no deferred requirement is STALE. A deferral is stale when
      its stage is active (self-excluded) and it carries no *live*
      `blocked-by:` scope. The message names the entry, its line, its
      stage, and the sibling ids/statuses that made the stage active.
    * **S2** -- every deferred requirement carries a `stage:`. Absent stage
      => staleness is undecidable => violation. Not a silent pass; a silent
      exemption is the failure class this task exists to remove.
    * **S3** -- a `blocked-by:` scope resolves and is live. Violated when
      the named id is absent from the corpus, is the entry's own id, or
      names a requirement that is `done` or `cancelled`.
    * **S4** -- every requirement's status is a recognised value.
      `:unknown` hard-fails, naming the entry and the offending raw token.
      This is the totality defence transplanted from ISS-0231's R2:
      silently treating an unrecognised status as inactive would let a typo
      (`status: donee`) un-activate a stage and make a stale deferral look
      legitimate. Applied to **all** entries, not only deferred ones.
    * **S5** -- the corpus is non-empty and shaped: at least one entry, and
      at least one recognised status. A scan that finds nothing is never a
      silent green pass. This deliberately duplicates part of the
      registration check's R5: this module must be correct on its own, not
      correct only because another task ran first.
    * **S6** -- the `blocked-by:` graph over deferred entries is acyclic.
      The one-step case (self-reference) is S3's; S6 is the >= 2-step case
      and it is the same defect. The message names every id on the cycle,
      in order.

  ## Always printed, never gating

  The **stage-activity table** (each stage, its status histogram, the
  derived verdict and the witness ids) so the derivation is auditable
  rather than hidden inside an exit code, and the **deferral roster**
  (every deferred entry with its stage, scope, verdict and the one-line
  reason for that verdict).

  **`:legitimate` deferrals never influence the exit code, at any count.**
  ISS-0231's visible-debt principle is preserved exactly; only its
  never-expiring half changes. Documented-and-still-true stays free.
  Documented-but-no-longer-true now fails.

  This module ships with **no exception list of any kind** -- no
  grandfathering, no wildcard, no id allowlist, no prefix suppression. It
  is green on `main` at the moment it lands (measured: 0 deferrals and 0
  unknown statuses of 115 entries), so any future red is a new fact.

  ## Why this is a separate task, not an extension

  1. **Different data shape.** Registration state is decidable from one
     entry's own lines. Staleness needs a cross-entry aggregate -- every
     sibling's status in the same stage -- which no per-entry classifier
     can express.
  2. **Different gating semantics.** The registration module's moduledoc
     contracts, in words, that *"The deferred count never influences the
     exit code, at any value."* A staleness rule must gate. Adding a gating
     rule on the deferred bucket inside that module would contradict its
     own written contract.
  3. **Different failure class** -- "never registered" vs.
     "registered-adjacent staleness".
  4. **Different inputs, therefore different blast radius on a red run.**
     One exit code covering two independent invariants forces the reader to
     disambiguate which one broke before knowing whether the file changed
     or the world did.

  ## Work-board registration (ISS-1073 / GH #2430)

  This task has no registration vocabulary of its own: it consumes the
  registration module's entry list, so a requirement registered by
  `gh: <number>` (alone, or beside a legacy `impl_order`) is an ordinary
  non-deferred entry exactly like an `impl_order`-registered one, and counts
  toward stage activity by its `status:` as before. The deferral marker and
  the `blocked-by:` hatch are unchanged. The transition switch
  (`docs/status/work_board_cutover.yaml`) is passed straight through to
  `scan/2`; it changes only registration rule R7, never an S-rule.

  Exactly **one parser** exists for `docs/requirements.yaml` across both
  tasks: `Mix.Tasks.Letflow.CheckRequirementsRegistration.scan/1`. A second
  parser would drift into its own form-blindness, which is ISS-0231's root
  cause recurring by duplication.

  ## What this task never does

  It never writes to `docs/requirements.yaml`, never assigns or suggests an
  `impl_order`, never edits a `status`, and makes no network call -- in
  particular none to letflow-queue. It is a read-only auditor.

  It scans `docs/requirements.yaml` **only** -- never `lib/`, never a
  directory walk. That is deliberate: this moduledoc itself contains both
  the deferral marker form and the hatch grammar it recognises, so a
  directory-wide scan would make the module fail its own check
  (`docs/anti-patterns.md`, "A grep-shaped acceptance criterion can be
  tripped by the module's own moduledoc describing the invariant").

  ## Usage

      mix letflow.check_deferral_staleness

  Wired into the `letflow.check` alias immediately after
  `letflow.check_requirements_registration` -- adjacent to its data source,
  and after it because if the file's *shape* broke, R2/R6 must be the first
  error the reader sees. A check nobody runs is not a check, and this
  repository has no CI configuration of any kind, so `mix letflow.check` is
  the only gate surface there is.

  Exits `0` iff S1-S6 all hold; `Mix.raise/1` otherwise, naming every
  violating entry by exact `REQ-NNN` and rule id.
  """

  use Mix.Task

  alias Mix.Letflow.WorkBoardCutover
  alias Mix.Tasks.Letflow.CheckRequirementsRegistration, as: Registration

  @requirements_file "docs/requirements.yaml"

  @rule String.duplicate("=", 72)
  @thin_rule String.duplicate("-", 72)

  @active_statuses [:done, :in_progress, :blocked]
  @expired_blocker_statuses [:done, :cancelled]
  @known_statuses %{
    "pending" => :pending,
    "in_progress" => :in_progress,
    "done" => :done,
    "blocked" => :blocked,
    "cancelled" => :cancelled
  }

  @blocked_by_re ~r/^(?:--\s*)?blocked-by:\s*(REQ-\d+)\b\s*(?:--\s*)?(\S.*)?$/

  @type status :: :pending | :in_progress | :done | :blocked | :cancelled | :unknown
  @type activity :: :active | :inactive
  @type scope :: :stage_scoped | {:blocked_by, String.t()}
  @type verdict :: :legitimate | :stale | :undecidable

  @type deferral :: %{
          id: String.t(),
          line: pos_integer(),
          stage: String.t() | nil,
          status: status(),
          scope: scope(),
          rationale: String.t() | nil,
          verdict: verdict(),
          reason: String.t()
        }

  @type stage_facts :: %{
          stage: String.t(),
          counts: %{status() => non_neg_integer()},
          activity: activity(),
          witnesses: [String.t()]
        }

  @type violation :: %{
          rule: String.t(),
          id: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t()
        }

  @type audit :: %{
          deferrals: [deferral()],
          stages: [stage_facts()],
          statuses: %{String.t() => status()},
          deferral_count: non_neg_integer(),
          stale_count: non_neg_integer(),
          violations: [violation()]
        }

  # -- Mix.Task entry point -------------------------------------------------

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    content =
      case File.read(@requirements_file) do
        {:ok, content} ->
          content

        {:error, reason} ->
          Mix.raise(
            "mix letflow.check_deferral_staleness: FAILED [S5] -- " <>
              "could not read #{@requirements_file}: #{inspect(reason)}"
          )
      end

    result = audit(content, cutover: WorkBoardCutover.cutover?())

    result |> render() |> IO.write()

    if result.violations == [] do
      :ok
    else
      Mix.raise(
        "mix letflow.check_deferral_staleness: FAILED -- " <>
          "#{length(result.violations)} violation(s):\n" <>
          Enum.map_join(result.violations, "\n", &format_violation/1)
      )
    end
  end

  # -- pure core ------------------------------------------------------------

  @doc """
  Audits the whole file. Pure: takes **content**, not a path, so hermetic
  fixture strings can be passed directly.

  That is not a convenience here. The live corpus holds zero deferred
  entries, so every live-corpus assertion about S1/S2/S3 passes vacuously
  and would keep passing under almost any mutation of the staleness rules.
  Fixture-level access is the entire regression value this check has.

  Never raises on content -- a malformed corpus is expressed as violations
  in the returned audit. Raises only on a non-binary argument.

  Deliberately **not** named `scan/1`: a test file exercising both this
  module and `CheckRequirementsRegistration` would otherwise hold two
  same-named public functions with different return shapes.
  """
  @spec audit(String.t(), keyword()) :: audit()
  def audit(content, opts \\ []) when is_binary(content) and is_list(opts) do
    report = Registration.scan(content, opts)
    entries = report.entries

    statuses =
      Map.new(entries, fn e -> {e.id, normalise_status(Map.get(e, :status))} end)

    stages = stage_activity(entries)

    deferrals =
      entries
      |> Enum.filter(&(&1.state == :deferred))
      |> Enum.map(&classify_deferral(&1, stages, statuses))

    violations =
      Enum.flat_map(deferrals, &deferral_violations(&1, statuses)) ++
        unknown_status_violations(entries) ++
        shape_violations(entries, report.entry_count) ++
        cycle_violations(deferrals)

    %{
      deferrals: deferrals,
      stages: stages,
      statuses: statuses,
      deferral_count: length(deferrals),
      stale_count: Enum.count(deferrals, &(&1.verdict == :stale)),
      violations: violations
    }
  end

  @doc """
  Derives the stage-activity table from the registration module's entry
  list -- the ruling above, isolated so it has a single mutation target and
  one test group can pin the whole table.

  Stage ids are compared by **exact equality** (via grouping), never by
  prefix: `S1` must not be activated by work in `S10`.
  """
  @spec stage_activity([map()]) :: [stage_facts()]
  def stage_activity(entries) do
    entries
    |> Enum.reject(&is_nil(&1.stage))
    |> Enum.group_by(& &1.stage)
    |> Enum.map(fn {stage, group} -> stage_facts(stage, group) end)
    |> Enum.sort_by(& &1.stage)
  end

  @spec stage_facts(String.t(), [map()]) :: stage_facts()
  defp stage_facts(stage, group) do
    counts =
      Enum.reduce(group, %{}, fn e, acc ->
        Map.update(acc, normalise_status(Map.get(e, :status)), 1, &(&1 + 1))
      end)

    witnesses =
      group
      |> Enum.filter(&(normalise_status(Map.get(&1, :status)) in @active_statuses))
      |> Enum.map(& &1.id)
      |> Enum.sort()

    %{
      stage: stage,
      counts: counts,
      activity: if(witnesses == [], do: :inactive, else: :active),
      witnesses: witnesses
    }
  end

  @doc """
  Classifies a single deferred entry -- the analogue of
  `CheckRequirementsRegistration.classify_entry/1`, and the unit the
  hermetic fixtures target.

  Returns exactly one `verdict` per call with `reason` populated in every
  branch, including `:legitimate`, so a green roster still explains itself.
  Applies self-exclusion against the stage's witness list.

  **S6 is deliberately not this function's job.** Cycle detection over the
  `blocked-by:` graph is inherently multi-entry and cannot be decided from
  one entry plus a status map, so it is collected in `audit/1` over the
  full deferral list -- exactly as `duplicate_id_violations/1` sits outside
  `classify_entry/1` in the precedent module.
  """
  @spec classify_deferral(map(), [stage_facts()], %{String.t() => status()}) :: deferral()
  def classify_deferral(entry, stages, statuses) do
    base = %{
      id: entry.id,
      line: entry.line,
      stage: entry.stage,
      status: normalise_status(Map.get(entry, :status)),
      scope: parse_scope(entry.rationale),
      rationale: entry.rationale,
      verdict: :undecidable,
      reason: ""
    }

    if is_nil(entry.stage) do
      %{
        base
        | verdict: :undecidable,
          reason:
            "carries no `stage:` field, so its staleness cannot be decided at all -- " <>
              "undecidable is a violation (S2) in its own right, never the benefit of the doubt"
      }
    else
      judge(base, active_witnesses(base, stages), statuses)
    end
  end

  @spec judge(deferral(), [String.t()], %{String.t() => status()}) :: deferral()
  defp judge(base, witnesses, statuses) do
    case hatch_state(base.id, base.scope, statuses) do
      {:live, blocker} ->
        %{
          base
          | verdict: :legitimate,
            reason:
              "scoped to #{blocker} (status #{statuses[blocker]}), which is still open -- " <>
                "the `blocked-by:` assertion has not expired"
        }

      {:expired, blocker, blocker_status} ->
        %{
          base
          | verdict: :stale,
            reason:
              "its `blocked-by: #{blocker}` scope has EXPIRED -- #{blocker} is " <>
                "#{blocker_status}, so the recorded reason for this deferral is no longer true"
        }

      {:invalid, detail} ->
        by_stage(base, witnesses, statuses, "its `blocked-by:` scope is unusable (#{detail})")

      :none ->
        by_stage(base, witnesses, statuses, "stage-scoped")
    end
  end

  @spec by_stage(deferral(), [String.t()], %{String.t() => status()}, String.t()) :: deferral()
  defp by_stage(base, [], _statuses, prefix) do
    %{
      base
      | verdict: :legitimate,
        reason:
          "#{prefix}; stage #{base.stage} is inactive -- no other requirement in it is " <>
            "done, in_progress, or blocked"
    }
  end

  defp by_stage(base, witnesses, statuses, prefix) do
    %{
      base
      | verdict: :stale,
        reason:
          "#{prefix}; stage #{base.stage} is ACTIVE -- " <> witness_text(witnesses, statuses)
    }
  end

  @doc """
  Parses the `blocked-by:` scope out of a deferral's rationale, anchored to
  the rationale's start.

  Returns `:stage_scoped` for anything that is not a well-formed anchored
  hatch -- including a malformed near-miss and a hatch with no trailing
  free text, neither of which may silently become a hatch.
  """
  @spec parse_scope(String.t() | nil) :: scope()
  def parse_scope(nil), do: :stage_scoped

  def parse_scope(rationale) when is_binary(rationale) do
    case Regex.run(@blocked_by_re, String.trim(rationale)) do
      [_, id, text] ->
        if String.trim(text) == "", do: :stage_scoped, else: {:blocked_by, id}

      _ ->
        # Either no match at all, or a match with no trailing free text --
        # the latter degenerates the hatch into a bare id and would replace
        # R3's human-readable-reason requirement rather than preserve it.
        :stage_scoped
    end
  end

  @doc """
  Normalises a raw `status:` token. Total: anything outside the declared
  set, and `nil`, map to `:unknown`, which **hard-fails** (S4). There is no
  branch anywhere that treats an unrecognised status as acceptable.

  Takes the **first whitespace-delimited token only**. That is measured,
  not defensive: 8 of the 115 real `status:` lines carry a trailing
  comment, e.g. `status: cancelled  # MVP-1 milestone dropped`, and a
  rest-of-line extractor would turn all 8 into `:unknown` and make this
  gate red on day one for a non-reason.
  """
  @spec normalise_status(String.t() | nil) :: status()
  def normalise_status(nil), do: :unknown

  def normalise_status(raw) when is_binary(raw) do
    token = raw |> String.trim() |> String.split(~r/\s+/, parts: 2) |> List.first()

    Map.get(@known_statuses, token, :unknown)
  end

  @doc """
  Renders the always-printed blocks -- the stage-activity table and the
  deferral roster -- plus the violation list. Pure, so a test can assert on
  the roster and the table without capturing task IO.
  """
  @spec render(audit()) :: iodata()
  def render(result) do
    [
      @rule,
      "\n",
      "mix letflow.check_deferral_staleness -- ",
      @requirements_file,
      "\n",
      @rule,
      "\n",
      render_stages(result),
      @thin_rule,
      "\n",
      render_roster(result),
      @thin_rule,
      "\n",
      totality_line(result),
      "\n",
      render_violations(result),
      @rule,
      "\n"
    ]
  end

  @spec totality_line(audit()) :: String.t()
  defp totality_line(result) do
    "#{result.deferral_count} deferred of #{map_size(result.statuses)} entries; " <>
      "#{result.stale_count} stale"
  end

  @spec render_stages(audit()) :: iodata()
  defp render_stages(%{stages: []}) do
    ["STAGE ACTIVITY (derived, always reported, never gates): no stages present\n"]
  end

  defp render_stages(%{stages: stages}) do
    [
      "STAGE ACTIVITY (derived, always reported, never gates):\n",
      Enum.map(stages, fn s ->
        [
          "  ",
          s.stage,
          "  ",
          String.upcase(Atom.to_string(s.activity)),
          "  [",
          histogram(s.counts),
          "]",
          witness_suffix(s),
          "\n"
        ]
      end)
    ]
  end

  @spec histogram(%{status() => non_neg_integer()}) :: String.t()
  defp histogram(counts) do
    counts
    |> Enum.sort_by(fn {status, _n} -> Atom.to_string(status) end)
    |> Enum.map_join(", ", fn {status, n} -> "#{n} #{status}" end)
  end

  @spec witness_suffix(stage_facts()) :: String.t()
  defp witness_suffix(%{witnesses: []}), do: ""

  defp witness_suffix(%{witnesses: witnesses}) do
    shown = Enum.take(witnesses, 3)
    more = length(witnesses) - length(shown)
    suffix = if more > 0, do: " (+#{more} more)", else: ""

    "  active via " <> Enum.join(shown, ", ") <> suffix
  end

  @spec render_roster(audit()) :: iodata()
  defp render_roster(%{deferrals: []}) do
    ["DEFERRALS (legitimate ones are reported and never gate): none\n"]
  end

  defp render_roster(%{deferrals: deferrals}) do
    [
      "DEFERRALS (legitimate ones are reported and never gate):\n",
      deferrals
      |> Enum.sort_by(& &1.line)
      |> Enum.map(fn d ->
        [
          "  ",
          d.id,
          "  ",
          d.stage || "(no stage)",
          "  ",
          scope_text(d.scope),
          "  ",
          String.upcase(Atom.to_string(d.verdict)),
          self_status_note(d),
          "\n",
          "      ",
          d.reason,
          "\n"
        ]
      end)
    ]
  end

  @spec scope_text(scope()) :: String.t()
  defp scope_text(:stage_scoped), do: "stage-scoped"
  defp scope_text({:blocked_by, id}), do: "blocked-by: #{id}"

  @spec self_status_note(deferral()) :: String.t()
  defp self_status_note(%{status: status}) when status in @active_statuses do
    "  (NOTE: deferred entry is itself #{status})"
  end

  defp self_status_note(_deferral), do: ""

  @spec render_violations(audit()) :: iodata()
  defp render_violations(%{violations: []}), do: []

  defp render_violations(%{violations: violations}) do
    [
      @thin_rule,
      "\n",
      "VIOLATIONS (each one fails the run):\n",
      Enum.map(violations, fn v -> ["  ", format_violation(v), "\n"] end)
    ]
  end

  @spec format_violation(violation()) :: String.t()
  defp format_violation(%{rule: rule, id: id, line: line, message: message}) do
    where =
      case {id, line} do
        {nil, nil} -> ""
        {nil, l} -> " (line #{l})"
        {i, nil} -> " #{i}"
        {i, l} -> " #{i} (line #{l})"
      end

    "[#{rule}]#{where}: #{message}"
  end

  # -- rules ----------------------------------------------------------------

  @spec deferral_violations(deferral(), %{String.t() => status()}) :: [violation()]
  defp deferral_violations(deferral, statuses) do
    s1(deferral) ++ s2(deferral) ++ s3(deferral, statuses)
  end

  @spec s1(deferral()) :: [violation()]
  defp s1(%{verdict: :stale} = d) do
    [
      violation(
        "S1",
        d.id,
        d.line,
        "STALE deferral -- #{d.reason}. Either register it (open its GitHub issue and add " <>
          "`gh: <number>`, see docs/agents/protocols/WORK_BOARD.md), or re-scope the rationale to a live " <>
          "`blocked-by: REQ-NNN -- <reason>`"
      )
    ]
  end

  defp s1(_deferral), do: []

  @spec s2(deferral()) :: [violation()]
  defp s2(%{stage: nil} = d) do
    [
      violation(
        "S2",
        d.id,
        d.line,
        "deferred requirement carries no `stage:` -- its staleness is undecidable, and " <>
          "an undecidable deferral is a violation rather than a silent exemption"
      )
    ]
  end

  defp s2(_deferral), do: []

  @spec s3(deferral(), %{String.t() => status()}) :: [violation()]
  defp s3(d, statuses) do
    case hatch_state(d.id, d.scope, statuses) do
      {:invalid, detail} ->
        [
          violation(
            "S3",
            d.id,
            d.line,
            "`blocked-by:` scope does not resolve -- it #{detail}. An unresolvable " <>
              "scope is a permanent unfalsifiable suppression, so it is rejected rather " <>
              "than honoured"
          )
        ]

      {:expired, blocker, blocker_status} ->
        [
          violation(
            "S3",
            d.id,
            d.line,
            "`blocked-by: #{blocker}` has EXPIRED -- #{blocker} is #{blocker_status}. " <>
              "The hatch is not an exemption; it is an assertion that goes stale on its own"
          )
        ]

      _ ->
        []
    end
  end

  @spec unknown_status_violations([map()]) :: [violation()]
  defp unknown_status_violations(entries) do
    entries
    |> Enum.filter(&(normalise_status(Map.get(&1, :status)) == :unknown))
    |> Enum.map(fn e ->
      violation(
        "S4",
        e.id,
        e.line,
        "unrecognised status #{inspect(Map.get(e, :status))} -- known values are " <>
          "#{Enum.map_join(Enum.sort(Map.keys(@known_statuses)), " | ", & &1)}. An " <>
          "unrecognised status must land in a failing bucket: absorbing it would let a " <>
          "typo un-activate a stage and make a stale deferral read as legitimate"
      )
    end)
  end

  @spec shape_violations([map()], non_neg_integer()) :: [violation()]
  defp shape_violations(entries, entry_count) do
    zero =
      if entry_count == 0 do
        [
          violation(
            "S5",
            nil,
            nil,
            "the requirements section contains zero entries (or the file has no " <>
              "top-level `requirements:` key) -- a scan that finds nothing is always a " <>
              "hard failure, never a green pass"
          )
        ]
      else
        []
      end

    unrecognised =
      if entries != [] and
           Enum.all?(entries, &(normalise_status(Map.get(&1, :status)) == :unknown)) do
        [
          violation(
            "S5",
            nil,
            nil,
            "no entry in the corpus yields a recognised status -- the file's shape " <>
              "changed underneath this check, so no stage activity could be derived"
          )
        ]
      else
        []
      end

    zero ++ unrecognised
  end

  @spec cycle_violations([deferral()]) :: [violation()]
  defp cycle_violations(deferrals) do
    edges =
      for %{id: id, scope: {:blocked_by, blocker}} <- deferrals, into: %{}, do: {id, blocker}

    lines = Map.new(deferrals, fn d -> {d.id, d.line} end)

    edges
    |> Map.keys()
    |> Enum.map(&find_cycle(&1, edges))
    |> Enum.reject(&(&1 == nil or length(&1) < 2))
    |> Enum.map(&canonical_cycle/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn cycle ->
      violation(
        "S6",
        List.first(cycle),
        Map.get(lines, List.first(cycle)),
        "`blocked-by:` cycle -- #{Enum.join(cycle ++ [List.first(cycle)], " -> ")}. " <>
          "No member of a cycle can ever reach done or cancelled while it waits on the " <>
          "others, so the hatch never expires and the deferrals license each other " <>
          "forever -- an exception list written in rationale text"
      )
    end)
  end

  # -- helpers --------------------------------------------------------------

  @spec active_witnesses(deferral(), [stage_facts()]) :: [String.t()]
  defp active_witnesses(%{id: id, stage: stage}, stages) do
    case Enum.find(stages, &(&1.stage == stage)) do
      nil -> []
      facts -> facts.witnesses -- [id]
    end
  end

  @spec witness_text([String.t()], %{String.t() => status()}) :: String.t()
  defp witness_text(witnesses, statuses) do
    shown = Enum.take(witnesses, 5)
    more = length(witnesses) - length(shown)
    suffix = if more > 0, do: " (+#{more} more)", else: ""

    "made active by " <>
      Enum.map_join(shown, ", ", fn id -> "#{id} (#{Map.get(statuses, id, :unknown)})" end) <>
      suffix
  end

  @spec hatch_state(String.t(), scope(), %{String.t() => status()}) ::
          :none
          | {:live, String.t()}
          | {:expired, String.t(), status()}
          | {:invalid, String.t()}
  defp hatch_state(_id, :stage_scoped, _statuses), do: :none

  defp hatch_state(id, {:blocked_by, id}, _statuses) do
    {:invalid, "names its own id #{id}, which would be an unfalsifiable self-license"}
  end

  defp hatch_state(_id, {:blocked_by, blocker}, statuses) do
    case Map.fetch(statuses, blocker) do
      :error ->
        {:invalid, "names #{blocker}, which is not present in the corpus"}

      {:ok, blocker_status} when blocker_status in @expired_blocker_statuses ->
        {:expired, blocker, blocker_status}

      {:ok, _blocker_status} ->
        {:live, blocker}
    end
  end

  @spec find_cycle(String.t(), %{String.t() => String.t()}) :: [String.t()] | nil
  defp find_cycle(start, edges), do: walk(start, start, edges, [start], MapSet.new([start]))

  @spec walk(String.t(), String.t(), %{String.t() => String.t()}, [String.t()], MapSet.t()) ::
          [String.t()] | nil
  defp walk(start, node, edges, path, seen) do
    case Map.fetch(edges, node) do
      :error ->
        nil

      {:ok, next} ->
        cond do
          next == start -> Enum.reverse(path)
          MapSet.member?(seen, next) -> nil
          true -> walk(start, next, edges, [next | path], MapSet.put(seen, next))
        end
    end
  end

  @spec canonical_cycle([String.t()]) :: [String.t()]
  defp canonical_cycle(cycle) do
    idx = Enum.find_index(cycle, &(&1 == Enum.min(cycle)))

    Enum.drop(cycle, idx) ++ Enum.take(cycle, idx)
  end

  @spec violation(String.t(), String.t() | nil, pos_integer() | nil, String.t()) :: violation()
  defp violation(rule, id, line, message) do
    %{rule: rule, id: id, line: line, message: message}
  end
end
