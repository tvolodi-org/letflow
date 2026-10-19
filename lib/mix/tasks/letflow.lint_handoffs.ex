defmodule Mix.Tasks.Letflow.LintHandoffs do
  @shortdoc "Validates every handoffs/**/*.json against HANDOFF_PROTOCOL.md's schema"

  @moduledoc """
  Implements ISS-0191: the handoff linter `HANDOFF_PROTOCOL.md`'s Enforcement
  note has described as a known gap since the protocol was written. Mirrors,
  for Letflow, what R-Co's `tools/lint_handoffs.py` does for R-Co (schema
  conformance, timestamp monotonicity, registry coverage), adopted after a
  2026-08-05 R-Co audit found unenforced bookkeeping rules were followed at
  0.4-8.6% compliance despite being written down.

  A plain Mix task, not a shell script: this project already has precedent
  (`mix letflow.check_toolchain`, `mix letflow.check_test`) and JSON decoding
  needs `Jason`, a runtime dependency only reachable inside the compiled app
  -- unlike `scripts/timed_test.sh`, which is deliberately a shell script for
  an unrelated reason (measuring a genuinely cold `mix compile`; this task
  has no such constraint, so that precedent does not apply here).

  ## Checks

  ### Hard (exit non-zero on any un-grandfathered violation)

    * **H1** -- top-level `status` is one of the six legal values.
    * **H2** -- `completed_at` never precedes `started_at`, when both are set.
    * **H3** -- top-level keys are a subset of `HANDOFF_PROTOCOL.md` §2's
      schema (`@schema_top_keys` below), or individually grandfathered; a
      present `tier` must be `FULL` or `SHORT`.
    * **H4** -- when `not_agent_attested` is present, its member set is
      **exactly** the required six (or those six plus `backfill_note`), read
      live out of `HANDOFF_PROTOCOL.md` §4.1(b)'s own table -- not hardcoded
      here, so a future edit to that table is what the linter measures, not
      what it silently drifts away from (ISS-0203's own concern about this
      exact class of drift). `backfill_note` itself is legal on at most the
      one file §4.1(b) names as its single spent exception, extracted the
      same way.
    * **H5** -- registry coverage: every `run_id` implied by a
      `handoffs/<run_id>/` directory appears in `handoffs/registry.json`'s
      `runs[].run_id`, and vice versa.
    * **H6** -- every discovered handoff-shaped file (basename starts with
      `step`) is JSON. A non-`.json` file is a discovery-completeness defect
      in its own right. **Unlike H1-H4, H6 is not grandfathered by an
      explicit file list** -- a file whose content already existed in git
      history at or before `@h6_floor_commit` is automatically exempt
      (reported, does not fail the build); a file introduced after that
      floor always fails the build. See `@h6_floor_commit`'s own comment and
      `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` for why.

  A hard violation on a file not in this module's grandfather maps is a
  **new** regression and fails the run. A hard violation on a grandfathered
  file is reported (so the debt stays visible) but does not fail the run --
  each grandfathered file is named individually, dated, and traced to
  ISS-0190, per that issue's "no blanket suppression" requirement. This
  module contains **no wildcard or pattern-based grandfathering, with one
  exception: H6**, which is governed by the `@h6_floor_commit`
  commit-boundary rule instead of a per-file list -- see above. Every other
  hard rule's grandfathering always means naming one exact path.

    * **H7** -- shape (ISS-1037 / Q-1020). Reported instead of crashing the
      scan, and **never grandfathered**. Violations name the file and the
      field: top-level value not a JSON object; `task` / `context` present
      but not an object; `task.description` present but not a string;
      `context.artifacts_in` / `result.artifacts_out` present but not a list
      of strings; `created_at` present but not a string. Absent keys and
      `null` values (e.g. `result: null` before completion) are legitimate.

  ### Advisory (WARN or INFO; never change the exit code)

    * **H7-RESULT** -- WARN when `result` is present, non-null and not an
      object (a few historical handoffs carry a bare string). Not a hard
      failure.

    * **H-SIZE-1/2/3** -- specified in `HANDOFF_PROTOCOL.md`'s Enforcement
      note ("Specified but NOT YET RUNNING" section, added by ISS-0198, the
      `result.summary` figures added by ISS-0200). Implemented here exactly
      per that spec: H-SIZE-1 (cite-and-restate), H-SIZE-2 (under-specified),
      H-SIZE-3 (per-run report, includes ISS-0200's `result.summary`
      figures -- report-only, no threshold, no pass/fail, per that issue's
      own ruling).
    * **artifacts_out self-reference** (ISS-0202) -- WARN when a handoff's
      `result.artifacts_out` lists its own file (by basename, or either path
      a suffix of the other). Applies only to handoffs created at or after
      the commit that landed ISS-0202's rule (`@artifacts_out_rule_commit`
      below) -- the 201 pre-existing self-referencing files are historical
      and are not, and must not be, flagged; see `HANDOFF_PROTOCOL.md`'s
      `result.artifacts_out does not include the handoff's own file`
      subsection for why.

  ## What this task deliberately does NOT check

  Whether a `result` block was actually attested by its acting agent, rather
  than reconstructed after that agent died. That property exists in no
  artefact on disk, so it is structurally unfalsifiable from the files this
  task reads -- asserting it would be a green run of a different, fictional
  test. This task only checks that a *present* `not_agent_attested` marker is
  internally well-formed (H4); a file that omits the marker without needing
  one and a file that omits it while needing one are indistinguishable here,
  by design, per ISS-0191's own scope note.

  ## Usage

      mix letflow.lint_handoffs
      mix letflow.lint_handoffs --dir <path>
      mix letflow.lint_handoffs --autofix
      mix letflow.lint_handoffs --autofix --dir <path>

  Exits non-zero (`Mix.raise/1`) iff at least one un-grandfathered hard
  violation exists. WARN/INFO output goes to stdout and never affects the
  exit code.

  ### `--dir <path>` (ISS-0440)

  Overrides the directory scanned, in place of the hardcoded `@handoffs_dir`
  default. With no `--dir` given at all (CI's own invocation, via the
  `letflow.check` alias in `mix.exs`), the scanned directory is exactly
  `@handoffs_dir` -- unchanged from before this flag existed. Every run,
  with or without `--dir`, prints a banner naming the directory actually
  scanned and the file count found there, so a scoped run is never
  mistaken for a full-corpus result from output alone. An explicitly
  supplied `--dir` that discovers zero files is a hard usage error (raises,
  non-zero exit) rather than a silent "0 violations" success -- this
  carve-out does not apply to the default `@handoffs_dir` itself, since a
  genuinely empty real `handoffs/` is a separate, pre-existing edge case,
  not a `--dir` misuse symptom.

  `--dir` also accepts a **single regular file** in place of a directory
  (ISS-0819) -- e.g. `mix letflow.lint_handoffs --dir
  handoffs/<run_id>/step-04-agent.json`, so an agent can validate the one
  handoff it just wrote before finishing its step, without waiting for the
  full-corpus CI gate. Single-file mode runs every schema check exactly as
  a directory scan would, except H5 (registry coverage), which is skipped
  entirely -- it is a corpus-level, report-only check, not meaningful for
  one file. The OK banner and H5 report section both name single-file mode
  explicitly, so its output is never confused with a directory or
  full-corpus result.

  ### `--autofix` (ISS-0440)

  Applies a closed, three-entry correction map to each file's top-level
  `status`: `"PASS"`, `"COMPLETE"`, and `"DONE"` are rewritten in place to
  `"COMPLETED"` and reported as fixed. `"FAIL"` and every other
  missing/non-string/unrecognized value are refused -- left untouched,
  reported by path and by the literal value found, and still counted as a
  hard violation for exit-code purposes. `--autofix` never guesses at an
  ambiguous status; it only ever acts on the three values with zero
  historical counterexamples. Combining `--autofix` with the default
  directory (i.e. omitting `--dir`, or passing `--dir handoffs`) runs the
  same restricted correction over the real handoff corpus -- this is
  intended, not restricted away, and every fixed file is reported so the
  action is never silent.
  """

  use Mix.Task

  @handoffs_dir "handoffs"
  @registry_file Path.join(@handoffs_dir, "registry.json")
  @protocol_file "docs/agents/shared/HANDOFF_PROTOCOL.md"
  @rule String.duplicate("=", 72)

  @legal_statuses ~w(PENDING IN_PROGRESS COMPLETED FAILED ESCALATED CANCELLED)

  # ISS-0440 §2.2 -- the closed, no-fifth-case --autofix mapping. `FAIL` MUST
  # NOT appear as a key here, and must not be added later without
  # re-deriving the ambiguity question the design's §6.1 leaves open on
  # purpose: `FAIL` is ambiguous between a lifecycle FAILED handoff and a
  # COMPLETED step with a failing result.status, and this tool will not
  # guess. Missing/non-string status values are likewise never keys here --
  # they fall through to the refuse path in run_autofix/1 below.
  @autofix_map %{
    "PASS" => "COMPLETED",
    "COMPLETE" => "COMPLETED",
    "DONE" => "COMPLETED"
  }

  @schema_top_keys ~w(
    handoff_id run_id workflow_id step from_agent to_agent file created_at
    started_at completed_at status priority context task result rework_count
    max_rework not_agent_attested gate_history tier
  )

  # REQ-524: the optional top-level `tier` (HANDOFF_PROTOCOL.md section 2).
  @legal_tiers ~w(FULL SHORT)

  # The commit that landed ISS-0202's rule (`result.artifacts_out` excludes
  # the handoff's own file) on `main`. Handoffs created before this commit
  # predate the rule and are never flagged by the artifacts_out WARN check.
  @artifacts_out_rule_commit "48a4a55"

  # The commit boundary before which a non-JSON handoff-shaped file (H6) is
  # automatically exempt -- a file whose content already existed in git
  # history at or before this commit is grandfathered; a file introduced
  # strictly after it always hard-fails. See
  # `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` for the full
  # mechanism and why it replaced the old per-file `@grandfathered` entries.
  #
  # 2026-08-22, ISS-0273: pinned to `c4a8e397...930252` -- the parent of
  # `184d846`, the commit that merged the H6 check onto `main` -- per
  # `lib/letflow/design/iss0273-h6-floor-commit-pin.md`. This value never
  # needs to move again: everything H6 was written to grandfather predates
  # it, and everything introduced from `184d846` onward (including H6's own
  # fixture) correctly lands on the "new, must pass or hard-fail honestly"
  # side. The BOOTSTRAP runtime-resolution fallback this constant previously
  # required has been removed -- `h6_floor_commit/0` now returns this
  # literal directly.
  @h6_floor_commit "c4a8e39729e253397d4f1aa34155a74522930252"

  # -- Individually-named pre-existing hard violations. Measured 2026-08-21
  # by this task's own first run against the corpus (626 files), then
  # RE-MEASURED the same day once ISS-0190 landed and fixed the 24 entries
  # that were in its scope (15 H1 status corrections, 6 H3 next_action
  # relocations, 2 H3 flat-schema migrations, 1 H3 gate_history -- the last
  # of these stopped being a violation at all once ISS-0190 formalised
  # `gate_history` as a documented optional top-level field in
  # HANDOFF_PROTOCOL.md §2 and `@schema_top_keys` above, rather than being
  # fixed by editing the file). No wildcards, no path prefixes: every entry
  # below is one exact file this task actually found violating. A NEW file
  # hitting the same rule is NOT covered by this list and fails the build --
  # grandfathering is per-file, never per-rule.
  #
  # 6 entries remain, all explicitly OUT OF ISS-0190's scope: 3 H3 (the
  # ISS-0117 recovery-marker keys `orch_timestamp_correction` x2 and
  # `orch_restart_note`, deliberately excluded by ISS-0190's own acceptance
  # criteria) + 1 H3 (`orch_status_correction` on
  # WF02-REQ062-20260819/step-03-test-designer.json, the same-shaped marker
  # ISS-0192 added for a non-agent-death status-flip correction -- same
  # class as the three ISS-0117 markers, not yet formalised into the schema
  # either) + 2 H2 (a negative started_at/completed_at gap, the timestamp
  # class ISS-0117/HANDOFF_PROTOCOL.md §1.2 already documents separately).
  #
  # 2026-08-22, ISS-0262 Step 8 change-approach rework (rework_count 2): H6 no
  # longer uses per-file grandfathering. The 12 entries previously here (10
  # from WF03-ISS0258-20260822, 2 from WF03-ISS0261-20260822) are removed --
  # H6 is now governed entirely by the `@h6_floor_commit` commit-boundary
  # rule (a file whose content predates that floor in git history is
  # automatically exempt; a file introduced at or after it always
  # hard-fails). See `lib/letflow/design/iss0262-h6-floor-commit-addendum.md`
  # for the mechanism and why the per-file list could not keep pace with
  # `main`. H1-H3's grandfathering below is unaffected by this change.
  @grandfathered [
    {"H3", "handoffs/WF02-REQ023-20260816/step-06-doc-updater.json"},
    {"H2", "handoffs/WF02-REQ025-20260817/step-01b-code-design-validator.json"},
    {"H3", "handoffs/WF02-REQ027-20260816/step-02d-reviewer.json"},
    {"H3", "handoffs/WF02-REQ037-20260817/step-02c-rework1-security-reviewer.json"},
    {"H3", "handoffs/WF02-REQ062-20260819/step-03-test-designer.json"},
    {"H2", "handoffs/WF03-ISS0047-20260818/step-03-elixir-dev.json"}
  ]

  @spec grandfathered?(String.t(), String.t()) :: boolean()
  defp grandfathered?(rule, path), do: {rule, path} in @grandfathered

  # -- H6 commit-boundary floor --------------------------------------------
  #
  # See `lib/letflow/design/iss0262-h6-floor-commit-addendum.md` §1-§2 for
  # the full mechanism, rationale, and fail-safe direction.

  @spec h6_floor_commit() :: String.t()
  defp h6_floor_commit, do: @h6_floor_commit

  # Two git calls: (A) find the file's first-ever appearance in history
  # (`--diff-filter=A`, `--follow` across renames, `--reverse` for oldest
  # first); (B) is that first-appearance commit at or before `floor`. Fails
  # safe to `false` on any git error or nil floor -- H6 is a hard gate, so a
  # git malfunction must surface as a failure, not silently exempt a file
  # that might be a genuine regression (design §1.4).
  @spec pre_floor_file?(path :: String.t(), floor :: String.t() | nil) :: boolean()
  def pre_floor_file?(path, floor) do
    case Process.get({:h6_pre_floor, path, floor}, :unset) do
      :unset ->
        result = compute_pre_floor_file?(path, floor)
        Process.put({:h6_pre_floor, path, floor}, result)
        result

      cached ->
        cached
    end
  end

  defp compute_pre_floor_file?(_path, nil), do: false

  defp compute_pre_floor_file?(path, floor) do
    case System.cmd(
           "git",
           ["log", "--follow", "--diff-filter=A", "--format=%H", "--reverse", "--", path],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case out |> String.trim() |> String.split("\n", trim: true) do
          [] -> false
          [first_add_sha | _] -> ancestor_or_equal?(first_add_sha, floor)
        end

      _ ->
        false
    end
  end

  defp ancestor_or_equal?(sha, floor) do
    case System.cmd("git", ["merge-base", "--is-ancestor", sha, floor], stderr_to_stdout: true) do
      {_, 0} -> true
      {_, 1} -> false
      _ -> false
    end
  end

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {dir, autofix?} = parse_flags(args)

    files = handoff_files(dir)

    guard_empty_scope(dir, files)

    refused =
      if autofix? do
        %{fixed: fixed, refused: refused} = run_autofix(files)
        print_autofix_report(fixed)
        refused
      else
        []
      end

    protocol = File.read!(@protocol_file)
    not_agent_attested_schema = parse_not_agent_attested_schema(protocol)

    results = Enum.map(files, &lint_file(&1, not_agent_attested_schema))

    registry_result = check_registry_coverage(files, dir)

    print_hard_violations(results)
    print_autofix_refused(refused)
    print_advisory(results)
    print_registry(registry_result, dir)

    hard_new = Enum.flat_map(results, & &1.hard_new)

    # H5 (registry coverage) is report-only, per ISS-0191's own acceptance
    # criteria wording: AC1 says the schema checks are things the task
    # "validates" (a gate); AC2 separately says registry coverage is
    # something the task "reports" -- a different verb, deliberately. It
    # does not participate in the exit code.
    total_new = length(hard_new)

    IO.puts(@rule)

    if total_new > 0 do
      IO.puts("letflow.lint_handoffs: FAIL -- #{total_new} new (un-grandfathered) violation(s).")

      IO.puts(@rule)
      Mix.raise("letflow.lint_handoffs found #{total_new} new violation(s) -- see output above")
    else
      grandfathered_count =
        results |> Enum.flat_map(& &1.hard_grandfathered) |> length()

      # ISS-0440 §2.1a(b) -- unconditional banner naming the directory
      # scanned, on every run including this healthy one, so a scoped
      # (--dir) run's output is never visually indistinguishable from a
      # genuine full-corpus clean result.
      # ISS-0819 -- single-file mode names the scan mode explicitly ("the
      # single handoff file") rather than "1 handoff files", so a
      # single-file run's OK banner is never visually confused with a
      # --dir <directory> run that happened to contain exactly one file.
      mode_phrase =
        if File.regular?(dir) do
          "the single handoff file"
        else
          "#{length(files)} handoff files"
        end

      IO.puts(
        "letflow.lint_handoffs: OK -- 0 new violations across #{mode_phrase} " <>
          "under #{inspect(dir)} (#{grandfathered_count} pre-existing grandfathered, " <>
          "traced to ISS-0190)."
      )

      IO.puts(@rule)
      :ok
    end
  end

  # -- CLI flag parsing (ISS-0440 §2.1, tightened by ISS-0443) -------------

  # Single parse point for both flags, via OptionParser's `strict:` mode --
  # replaces the old hand-walked find_dir_flag/1, which silently discarded
  # any token it didn't recognize (ISS-0443's root cause: a mistyped
  # --autofx or --dr, or any other unrecognized flag, produced a confident
  # "OK" instead of an error). No "--dir"/"--autofix" present in args ->
  # dir defaults to @handoffs_dir, autofix? defaults to false --
  # byte-identical to today's behavior on the no-flag path CI's own
  # `letflow.check` alias depends on. Any unrecognized flag, a malformed
  # value for a recognized flag, or a bare positional argument now raises
  # instead of being silently ignored.
  @spec parse_flags([String.t()]) :: {dir :: String.t(), autofix? :: boolean()}
  defp parse_flags(args) do
    {parsed, remaining, invalid} =
      OptionParser.parse(args, strict: [dir: :string, autofix: :boolean])

    case invalid do
      [entry | _rest] -> raise_invalid_flag(entry)
      [] -> :ok
    end

    if remaining != [] do
      Mix.raise(
        "letflow.lint_handoffs: unexpected argument(s) #{inspect(remaining)} -- this task " <>
          "takes no positional arguments"
      )
    end

    dir = Keyword.get(parsed, :dir, @handoffs_dir)
    autofix? = Keyword.get(parsed, :autofix, false)
    {dir, autofix?}
  end

  # "--dir" with no following value is special-cased ahead of the generic
  # unrecognized-flag clause below, preserving today's exact message --
  # OptionParser's `invalid` list carries both cases as {flag, nil}, so they
  # are only distinguishable by which flag string appears, not by the nil.
  @spec raise_invalid_flag({String.t(), String.t() | nil}) :: no_return()
  defp raise_invalid_flag({"--dir", nil}) do
    Mix.raise("letflow.lint_handoffs: --dir given with no path argument")
  end

  defp raise_invalid_flag({flag, nil}) do
    Mix.raise(
      "letflow.lint_handoffs: unrecognized flag #{inspect(flag)} -- known flags are " <>
        "--dir <path> and --autofix"
    )
  end

  defp raise_invalid_flag({flag, value}) do
    Mix.raise("letflow.lint_handoffs: invalid value #{inspect(value)} for flag #{inspect(flag)}")
  end

  # Preserved for callers: same input type ([String.t()]) and same success
  # return type (String.t()) as before ISS-0443. Delegates to parse_flags/1
  # so --dir's validation stays in the single parse point above -- no
  # duplicated logic between run/1's flag handling and this public helper.
  @spec resolve_dir([String.t()]) :: String.t()
  def resolve_dir(args) do
    {dir, _autofix?} = parse_flags(args)
    dir
  end

  # ISS-0440 §2.1a(a) -- a hard guard: an EXPLICITLY-supplied --dir that
  # discovers zero files is a usage error (Mix.raise/1, non-zero exit), not
  # a clean result. Does NOT apply when dir is the default @handoffs_dir
  # (i.e. no --dir was given at all) -- a genuinely empty real handoffs/ is
  # a separate, pre-existing edge case of handoff_files/1's own default
  # behaviour, not a --dir misuse symptom, and is out of scope here.
  @spec guard_empty_scope(scan_target :: String.t(), files :: [String.t()]) :: :ok | no_return()
  def guard_empty_scope(scan_target, files) do
    if files == [] and scan_target != @handoffs_dir do
      Mix.raise(
        "letflow.lint_handoffs: --dir #{inspect(scan_target)} #{empty_scope_reason(scan_target)} " <>
          "-- refusing to report success for an empty or non-existent scan target"
      )
    else
      :ok
    end
  end

  # ISS-0819 -- reason phrase for guard_empty_scope/2's message, selected by
  # this precedence (first match wins). The regular-file branch is
  # defensive only: per handoff_files/1 above, a regular file always
  # yields a one-element list, so guard_empty_scope/2's failure branch is
  # never reached for a valid single-file target -- this exists only so
  # the function stays defined and non-crashing if that invariant is ever
  # violated by a future change.
  @spec empty_scope_reason(String.t()) :: String.t()
  defp empty_scope_reason(scan_target) do
    cond do
      not File.exists?(scan_target) -> "does not exist"
      File.regular?(scan_target) -> "is a file lint_handoffs could not read"
      true -> "discovered 0 files"
    end
  end

  # -- --autofix (ISS-0440 §2.2-§2.5) --------------------------------------

  @spec run_autofix(files :: [String.t()]) :: %{
          fixed: [%{path: String.t(), from: String.t(), to: String.t()}],
          refused: [%{path: String.t(), found: String.t(), reason: String.t()}]
        }
  def run_autofix(files) do
    files
    |> Enum.filter(&(handoff_kind(&1) == :json))
    |> Enum.reduce(%{fixed: [], refused: []}, fn path, acc ->
      case autofix_file(path) do
        {:fixed, from, to} ->
          %{acc | fixed: [%{path: path, from: from, to: to} | acc.fixed]}

        {:refused, found, reason} ->
          %{acc | refused: [%{path: path, found: found, reason: reason} | acc.refused]}

        :skip ->
          acc
      end
    end)
    |> then(fn %{fixed: fixed, refused: refused} ->
      %{fixed: Enum.reverse(fixed), refused: Enum.reverse(refused)}
    end)
  end

  # Reads one file's top-level status and decides fixed / refused / skip
  # (skip = already-legal status, nothing for --autofix to do; the plain
  # lint pass that runs afterward still evaluates it normally).
  defp autofix_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} when is_map(data) <- Jason.decode(raw) do
      case Map.get(data, "status") do
        status when is_map_key(@autofix_map, status) ->
          to = Map.fetch!(@autofix_map, status)
          rewrite_top_level_status!(path, raw, to)
          {:fixed, status, to}

        "FAIL" ->
          {:refused, "FAIL",
           "FAIL is ambiguous between a lifecycle FAILED handoff and a COMPLETED step " <>
             "with a failing result.status -- this tool will not guess; correct the " <>
             "top-level status field by hand."}

        status when is_binary(status) and status in @legal_statuses ->
          :skip

        status when is_binary(status) ->
          {:refused, status,
           "top-level status #{inspect(status)} is not one of #{inspect(@legal_statuses)} " <>
             "and is not in the closed --autofix map -- this tool will not guess; correct " <>
             "the top-level status field by hand."}

        other ->
          {:refused, "missing/non-string (#{inspect(other)})",
           "missing or non-string top-level status (#{inspect(other)}) -- this tool will " <>
             "not guess; correct the top-level status field by hand."}
      end
    else
      _ -> :skip
    end
  end

  # ISS-0442 -- replaces the old write_json!/2 whole-document re-encode
  # (Jason.decode -> mutate -> Jason.encode!(pretty: true)), which turned a
  # one-field status correction into a near-total-file rewrite: every
  # level's keys got alphabetically re-sorted (Jason.decode/1's plain map
  # has no order metadata) AND every value got independently reflowed by
  # Jason.Formatter's pretty-printer, regardless of key order. See
  # `lib/letflow/design/iss0442-lint-handoffs-minimal-diff-autofix.md` for
  # the full analysis and the option comparison (a: Jason.OrderedObject --
  # rejected, only fixes reordering, not reflow; b: this raw-text splice --
  # adopted; c: correct the reviewability claim instead -- rejected as
  # premature given (b) is proportionate).
  #
  # `rewrite_top_level_status!/3` writes `raw`, rewritten by
  # `splice_top_level_status/2`, straight back to `path` with a single
  # `File.write!/2` call and NO trailing-newline append -- the original
  # file's own trailing-newline convention (or lack of one) is preserved
  # automatically because it lies entirely outside the one modified span.
  @spec rewrite_top_level_status!(path :: String.t(), raw :: String.t(), new_status :: String.t()) ::
          :ok
  def rewrite_top_level_status!(path, raw, new_status) do
    rewritten = splice_top_level_status(raw, new_status)
    File.write!(path, rewritten)
    :ok
  end

  # Pure (no I/O): implements the depth-aware raw-text substitution
  # algorithm from the design doc's §2.2. Walks `raw` left to right exactly
  # once, tracking JSON nesting `depth` via brace/bracket counting OUTSIDE
  # string literals -- string boundaries are always resolved first
  # (`consume_json_string/1`), so embedded `{`/`}`/`:`/`"` inside string
  # VALUES never affect depth tracking or key detection. The root object's
  # members sit at `depth == 1`; a depth-1 string immediately followed
  # (mod whitespace) by `:` is a KEY candidate -- this is a purely
  # syntactic rule, not an odd/even alternation count, so it cannot desync
  # on an odd/malformed structure. Only a depth-1 KEY whose *decoded*
  # content equals exactly "status" is a candidate; a nested `result.status`
  # (or any `status` key at depth >= 2) is scanned over but never a
  # candidate, by construction, regardless of where it appears in the file
  # -- this is what structurally rules out the PASS/PASS collision
  # ISSUE-FIXER demonstrated on a real fixture. If more than one depth-1
  # `status` key exists (a malformed/duplicate-key document), the FIRST one
  # found wins and every later depth-1 `status` match is ignored -- this
  # matches `Jason.decode/1`'s own confirmed FIRST-key-wins duplicate-key
  # semantics (verified directly against the pinned `jason 1.4.5`:
  # `Jason.decode!(~s({"status":"a","status":"b"}))` returns
  # `%{"status" => "a"}`, not `"b"`), so the span this scan edits is
  # guaranteed to be the same member `autofix_file/1`'s `Map.get(data,
  # "status")` actually acted on. (An earlier version of this comment
  # claimed the opposite -- last-key-wins -- which was false; see ISS-0457
  # for the correction.)
  #
  # Raises if no depth-1 "status" key is found -- an internal invariant
  # violation, not a normal refusal path: it can only happen if `raw`'s
  # structure disagrees with what `Jason.decode/1` already reported
  # earlier in `autofix_file/1` on this same `raw`, which should never
  # occur for valid JSON. Deliberately does NOT fall back to the old
  # whole-document re-encode on this failure -- that would silently
  # reintroduce the exact bug ISS-0442 is about.
  @spec splice_top_level_status(raw :: String.t(), new_status :: String.t()) :: String.t()
  def splice_top_level_status(raw, new_status) do
    case scan_for_status(raw, 0, "", nil) do
      {_consumed, {prefix_before_value, _old_value_raw, suffix_after_value}} ->
        prefix_before_value <> Jason.encode!(new_status) <> suffix_after_value

      {_consumed, nil} ->
        raise "letflow.lint_handoffs: internal invariant violation -- " <>
                "splice_top_level_status/2 found no depth-1 \"status\" key in raw text " <>
                "that Jason.decode/1 already reported as having one; this indicates a bug " <>
                "in the scanner, not a normal --autofix refusal case"
    end
  end

  # Single forward pass. `depth` is the current JSON nesting depth; `acc` is
  # every byte consumed so far (used only to build a candidate's
  # `prefix_before_value` at the moment a match is found -- not needed for
  # anything else, since the winning candidate's own two captured pieces
  # are enough to reconstruct the final text); `best` is `nil` or the most
  # recently found candidate as `{prefix_before_value, old_value_raw,
  # suffix_after_value}`.
  @spec scan_for_status(String.t(), integer(), String.t(), tuple() | nil) ::
          {String.t(), tuple() | nil}
  defp scan_for_status(<<>>, _depth, acc, best), do: {acc, best}

  defp scan_for_status(<<c::utf8, rest::binary>>, depth, acc, best) when c in [?{, ?[] do
    scan_for_status(rest, depth + 1, acc <> <<c::utf8>>, best)
  end

  defp scan_for_status(<<c::utf8, rest::binary>>, depth, acc, best) when c in [?}, ?]] do
    scan_for_status(rest, depth - 1, acc <> <<c::utf8>>, best)
  end

  defp scan_for_status(<<?", _::binary>> = rest, depth, acc, best) do
    {string_raw, after_string} = consume_json_string(rest)
    handle_string_token(string_raw, after_string, depth, acc, best)
  end

  defp scan_for_status(<<c::utf8, rest::binary>>, depth, acc, best) do
    scan_for_status(rest, depth, acc <> <<c::utf8>>, best)
  end

  # A depth-1 string immediately followed (mod whitespace) by `:` is a KEY
  # candidate. Every other string (depth >= 2, or a depth-1 VALUE not
  # followed by `:`) is just copied through and scanning continues.
  defp handle_string_token(string_raw, after_string, depth, acc, best) do
    acc_with_string = acc <> string_raw

    if depth == 1 and key_follows?(after_string) do
      {colon_and_ws, after_colon_ws} = consume_colon_and_ws(after_string)
      prefix_before_value = acc_with_string <> colon_and_ws

      if Jason.decode!(string_raw) == "status" do
        # Guaranteed to be a JSON string value at this call site: the fixed
        # branch is only reached when Map.get(data, "status") already
        # decoded as a string matching @autofix_map's keys, so the raw
        # text's corresponding value token here is necessarily a JSON
        # string literal -- never a number/bool/null/object/array.
        {old_value_raw, after_value} = consume_json_string(after_colon_ws)

        # ISS-0457 -- first-match-wins: `best` is set exactly once, on the
        # FIRST depth-1 "status" match. A later depth-1 "status" match (a
        # malformed/duplicate-key document) still gets scanned and consumed
        # here (so `acc`/the forward pass stays correct), but its candidate
        # tuple is discarded when `best` is already non-nil -- the earlier
        # match is carried forward unchanged instead of being overwritten.
        winner =
          if is_nil(best) do
            {prefix_before_value, old_value_raw, after_value}
          else
            best
          end

        scan_for_status(after_value, depth, prefix_before_value <> old_value_raw, winner)
      else
        scan_for_status(after_colon_ws, depth, prefix_before_value, best)
      end
    else
      scan_for_status(after_string, depth, acc_with_string, best)
    end
  end

  defp key_follows?(rest) do
    case skip_ws(rest) do
      <<?:, _::binary>> -> true
      _ -> false
    end
  end

  defp skip_ws(<<c::utf8, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  # Consumes leading whitespace, the mandatory `:`, and trailing whitespace,
  # returning `{exact consumed text, remainder starting at the value's
  # opening quote}`.
  defp consume_colon_and_ws(rest), do: consume_colon_and_ws(rest, "")

  defp consume_colon_and_ws(<<c::utf8, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r] do
    consume_colon_and_ws(rest, acc <> <<c::utf8>>)
  end

  defp consume_colon_and_ws(<<?:, rest::binary>>, acc) do
    consume_colon_and_ws_after(rest, acc <> ":")
  end

  defp consume_colon_and_ws_after(<<c::utf8, rest::binary>>, acc)
       when c in [?\s, ?\t, ?\n, ?\r] do
    consume_colon_and_ws_after(rest, acc <> <<c::utf8>>)
  end

  defp consume_colon_and_ws_after(rest, acc), do: {acc, rest}

  # Consumes one JSON string literal starting at its opening `"` (inclusive)
  # through its matching closing `"` (inclusive), escape-aware: a `\`
  # starts a two-character escape, so `\"` inside the string never ends it,
  # and a `\uXXXX` escape is handled correctly for free -- `\u` is consumed
  # as the two-character escape, and the four hex digits that follow are
  # then just ordinary characters (they can never be a bare `"` or `\`), so
  # no special-casing beyond skipping past `\u` is needed. Returns `{raw
  # text including both quotes, remainder after the closing quote}`.
  # Decoding the raw token's actual string content (when needed) is done by
  # the caller via `Jason.decode!/1` on the returned raw text, rather than
  # by hand-rolling escape resolution here.
  defp consume_json_string(<<?", rest::binary>>), do: consume_json_string_body(rest, "\"")

  defp consume_json_string_body(<<?\\, c::utf8, rest::binary>>, acc) do
    consume_json_string_body(rest, acc <> <<?\\, c::utf8>>)
  end

  defp consume_json_string_body(<<?", rest::binary>>, acc), do: {acc <> "\"", rest}

  defp consume_json_string_body(<<c::utf8, rest::binary>>, acc) do
    consume_json_string_body(rest, acc <> <<c::utf8>>)
  end

  defp print_autofix_report(fixed) do
    if fixed != [] do
      IO.puts(@rule)
      IO.puts("AUTOFIX -- FIXED (status rewritten to COMPLETED):")

      Enum.each(fixed, fn %{path: path, from: from, to: to} ->
        IO.puts("  #{path}: #{inspect(from)} -> #{inspect(to)}")
      end)
    end
  end

  # ISS-0440 §2.3 -- refused files are reported distinctly from fixed
  # files AND distinctly from the "NEW HARD VIOLATIONS" heading the normal
  # H1 lint pass will also separately print for the same file (it is still
  # untouched, so the plain lint pass still finds and counts it there too --
  # that is deliberate: --autofix never removes a refused file from the
  # hard-violation count). This heading exists so the caller does not have
  # to infer "this was an --autofix candidate that got refused" from the
  # generic H1 message alone.
  defp print_autofix_refused(refused) do
    if refused != [] do
      IO.puts(@rule)
      IO.puts("AUTOFIX -- REFUSED (REQUIRES HUMAN-EQUIVALENT DECISION):")

      Enum.each(refused, fn %{path: path, found: found, reason: reason} ->
        IO.puts("  #{path}: found #{inspect(found)} -- #{reason}")
      end)
    end
  end

  # -- discovery ----------------------------------------------------------

  # ISS-0819 -- `scan_target` is either a directory (existing behavior,
  # unchanged) or a single regular file. A single file is returned as its
  # own one-element list, with NO filtering against the "**/step*.*" glob
  # or the registry_file/1 exclusion: those two filters exist only to keep
  # a *directory* scan from picking up registry.json or other non-handoff
  # files it stumbles across, and a file the caller named explicitly has no
  # such ambiguity -- see design doc §2's "open design point" for the full
  # rationale (e.g. `--dir handoffs/registry.json` is linted, not silently
  # filtered to []). Anything that is neither a regular file nor a
  # directory (does not exist, or is some other filesystem object) falls
  # through to the empty list, unchanged from today's wildcard-based
  # behavior for a bad --dir path -- handoff_files/1 stays a pure "what did
  # I find" query; guard_empty_scope/2 is what turns [] into a failure.
  @spec handoff_files(scan_target :: String.t()) :: [String.t()]
  def handoff_files(scan_target \\ @handoffs_dir) do
    cond do
      File.regular?(scan_target) ->
        [scan_target]

      File.dir?(scan_target) ->
        Path.wildcard(Path.join(scan_target, "**/step*.*"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&(&1 == registry_file(scan_target)))
        |> Enum.sort()

      true ->
        []
    end
  end

  @spec registry_file(dir :: String.t()) :: String.t()
  defp registry_file(dir), do: Path.join(dir, "registry.json")

  # ISS-0834 -- handoffs/registry.json was found committed with a leading
  # UTF-8 byte-order-mark (EF BB BF), which `Jason.decode!/1`/`Jason.decode/1`
  # reject outright. The committed file itself is fixed (BOM stripped), but
  # per ISS-0834's own fix direction this read path is hardened too, so a
  # future write that reintroduces a BOM (e.g. some Windows-originated
  # tooling in this multi-session environment) degrades to the same
  # non-crashing PARSE-advisory shape ISS-0347 already established for
  # arbitrary handoff files, rather than resurfacing as a silent decode
  # failure specifically for the shared registry.
  #
  # Deliberately scoped to registry.json's two read call sites
  # (`do_check_registry_coverage/2` below, and `lint_file/2`'s :json branch
  # when the scanned path IS registry.json in single-file mode) rather than
  # applied unconditionally to every handoff-shaped JSON file: the
  # F-BOM-PARSE-ADVISORY-SHAPE regression test (ISS-0347) asserts that an
  # arbitrary handoff file with a leading BOM still lands in the PARSE
  # branch without crashing -- stripping BOMs universally would silently
  # make that fixture decode clean and invalidate that regression guard.
  # registry.json is the one file this issue is actually about, so the fix
  # is scoped to it, not generalized into a decode-everything-permissively
  # policy the requirement never asked for.
  @spec strip_bom(binary()) :: binary()
  def strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  def strip_bom(raw), do: raw

  # -- §4.1(b) schema, read live from HANDOFF_PROTOCOL.md ------------------

  # Returns %{required: [String.t()], optional: [String.t()], spent_exception_file: String.t() | nil}
  @spec parse_not_agent_attested_schema(String.t()) :: map()
  defp parse_not_agent_attested_schema(protocol) do
    table_section =
      case String.split(protocol, "### (b) The mandatory marking", parts: 2) do
        [_, rest] -> rest |> String.split("### (c)", parts: 2) |> hd()
        _ -> ""
      end

    row_re = ~r/^\|\s*`(\w+)`\s*(\*\*\(OPTIONAL[^)]*\)\*\*)?\s*\|/m

    {required, optional} =
      Regex.scan(row_re, table_section)
      |> Enum.reduce({[], []}, fn match, {req, opt} ->
        name = Enum.at(match, 1)
        optional_marker = Enum.at(match, 2, "")

        if optional_marker in [nil, ""] do
          {[name | req], opt}
        else
          {req, [name | opt]}
        end
      end)

    spent_file =
      case Regex.run(~r/One backfill was authorised.*?\n`([^`]+)`/s, protocol) do
        [_, path] -> path
        nil -> nil
      end

    %{
      required: Enum.reverse(required),
      optional: Enum.reverse(optional),
      spent_exception_file: spent_file
    }
  end

  # -- per-file lint --------------------------------------------------------

  @spec handoff_kind(path :: String.t()) :: :json | :non_json
  def handoff_kind(path) do
    if String.downcase(Path.extname(path)) == ".json" do
      :json
    else
      :non_json
    end
  end

  @spec lint_file(path :: String.t(), not_agent_attested_schema :: map()) :: map()
  def lint_file(path, not_agent_attested_schema) do
    case handoff_kind(path) do
      :non_json ->
        floor = h6_floor_commit()
        pre_floor? = pre_floor_file?(path, floor)

        v =
          violation(
            path,
            "H6",
            "non-JSON handoff-shaped file: #{path} has extension " <>
              "#{inspect(Path.extname(path))}, expected .json " <>
              "(pre_floor?: #{pre_floor?}, h6_floor_commit: #{inspect(floor)})",
            pre_floor?
          )

        %{
          path: path,
          hard_new: if(v.grandfathered, do: [], else: [v]),
          hard_grandfathered: if(v.grandfathered, do: [v], else: []),
          advisory: %{path: path, warnings: [], size_info: %{desc_len: 0, summary_len: 0}},
          parse_error: nil
        }

      :json ->
        # ISS-0834 -- when this file itself IS registry.json (single-file
        # mode, e.g. `--dir handoffs/registry.json`), strip a leading BOM
        # before decoding, same as the H5 registry-coverage reader below.
        # Every other .json handoff file is read byte-for-byte unchanged --
        # see strip_bom/1's own comment for why this is not generalized.
        with {:ok, raw0} <- File.read(path),
             raw = if(path == @registry_file, do: strip_bom(raw0), else: raw0),
             {:ok, data} <- Jason.decode(raw),
             {:ok, data} <- ensure_object(path, data) do
          hard = check_h7_shape(path, data)

          hard = hard ++ check_h1_status(path, data)
          hard = hard ++ check_h2_timestamps(path, data)
          hard = hard ++ check_h3_keys(path, data)
          hard = hard ++ check_h3_tier(path, data)
          hard = hard ++ check_h4_not_agent_attested(path, data, not_agent_attested_schema)

          {grandfathered, new} = Enum.split_with(hard, & &1.grandfathered)

          advisory = check_advisory(path, data)

          %{
            path: path,
            hard_new: new,
            hard_grandfathered: grandfathered,
            advisory: advisory,
            parse_error: nil
          }
        else
          {:not_object, v} ->
            %{
              path: path,
              hard_new: [v],
              hard_grandfathered: [],
              advisory: %{path: path, warnings: [], size_info: %{desc_len: 0, summary_len: 0}},
              parse_error: nil
            }

          {:error, reason} ->
            %{
              path: path,
              hard_new: [
                %{
                  path: path,
                  rule: "PARSE",
                  message: "could not read/decode: #{inspect(reason)}",
                  grandfathered: false
                }
              ],
              hard_grandfathered: [],
              advisory: %{path: path, warnings: [], size_info: %{desc_len: 0, summary_len: 0}},
              parse_error: inspect(reason)
            }
        end
    end
  end

  defp violation(path, rule, message, grandfathered? \\ false) do
    %{path: path, rule: rule, message: message, grandfathered: grandfathered?}
  end

  # H7 -------------------------------------------------------------------
  #
  # ISS-1037 / Q-1020 -- shape guard. Every later check (and the advisory
  # pass) assumes a decoded map with maps/lists/strings in the documented
  # places; a malformed handoff used to crash the whole corpus scan with a
  # FunctionClauseError/BadMapError. H7 reports the malformed field instead.
  # Never grandfathered. Absent keys and `null` (e.g. `result: null` before
  # completion) are legitimate and are not violations.

  @spec ensure_object(String.t(), term()) :: {:ok, map()} | {:not_object, map()}
  defp ensure_object(_path, data) when is_map(data), do: {:ok, data}

  defp ensure_object(path, data) do
    {:not_object,
     violation(
       path,
       "H7",
       "top-level value is not a JSON object (got #{json_type(data)})"
     )}
  end

  @spec json_type(term()) :: String.t()
  defp json_type(v) when is_list(v), do: "array"
  defp json_type(v) when is_binary(v), do: "string"
  defp json_type(v) when is_number(v), do: "number"
  defp json_type(v) when is_boolean(v), do: "boolean"
  defp json_type(nil), do: "null"
  defp json_type(v) when is_map(v), do: "object"

  @spec check_h7_shape(String.t(), map()) :: [map()]
  defp check_h7_shape(path, data) do
    task = Map.get(data, "task")
    context = Map.get(data, "context")
    result = Map.get(data, "result")

    top_level =
      for key <- ["task", "context"],
          Map.has_key?(data, key),
          not is_map(Map.get(data, key)),
          do: "#{key} must be an object (got #{json_type(Map.get(data, key))})"

    nested =
      [
        if(is_map(task), do: string_field_problem(task, "description", "task.description")),
        if(is_map(context),
          do: string_list_problem(context, "artifacts_in", "context.artifacts_in")
        ),
        if(is_map(result),
          do: string_list_problem(result, "artifacts_out", "result.artifacts_out")
        ),
        string_field_problem(data, "created_at", "created_at")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.map(top_level ++ nested, &violation(path, "H7", "malformed shape: " <> &1))
  end

  defp string_field_problem(map, key, label) do
    case Map.get(map, key) do
      nil -> nil
      v when is_binary(v) -> nil
      v -> "#{label} must be a string (got #{json_type(v)})"
    end
  end

  defp string_list_problem(map, key, label) do
    case Map.get(map, key) do
      nil ->
        nil

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: nil,
          else: "#{label} must be a list of strings (has non-string element)"

      v ->
        "#{label} must be a list of strings (got #{json_type(v)})"
    end
  end

  # H1 -------------------------------------------------------------------

  defp check_h1_status(path, %{"status" => status}) when is_binary(status) do
    if status in @legal_statuses do
      []
    else
      [
        violation(
          path,
          "H1",
          "top-level status #{inspect(status)} is not one of #{inspect(@legal_statuses)}",
          grandfathered?("H1", path)
        )
      ]
    end
  end

  defp check_h1_status(path, data) do
    [
      violation(
        path,
        "H1",
        "missing or non-string top-level status (#{inspect(Map.get(data, "status"))})",
        grandfathered?("H1", path)
      )
    ]
  end

  # H2 -------------------------------------------------------------------

  defp check_h2_timestamps(path, %{"started_at" => s, "completed_at" => c})
       when is_binary(s) and is_binary(c) do
    with {:ok, started, _} <- DateTime.from_iso8601(s),
         {:ok, completed, _} <- DateTime.from_iso8601(c) do
      if DateTime.compare(completed, started) == :lt do
        [
          violation(
            path,
            "H2",
            "completed_at (#{c}) precedes started_at (#{s})",
            grandfathered?("H2", path)
          )
        ]
      else
        []
      end
    else
      _ -> [violation(path, "H2", "started_at/completed_at present but not parseable ISO8601")]
    end
  end

  defp check_h2_timestamps(_path, _data), do: []

  # H3 -------------------------------------------------------------------

  defp check_h3_keys(path, data) do
    extra = Map.keys(data) -- @schema_top_keys

    if extra == [] do
      []
    else
      [
        violation(
          path,
          "H3",
          "non-schema top-level key(s): #{inspect(extra)}",
          grandfathered?("H3", path)
        )
      ]
    end
  end

  defp check_h3_tier(path, %{"tier" => tier}) when tier not in @legal_tiers do
    [
      violation(
        path,
        "H3",
        "top-level tier #{inspect(tier)} is not one of #{inspect(@legal_tiers)}",
        grandfathered?("H3", path)
      )
    ]
  end

  defp check_h3_tier(_path, _data), do: []

  # H4 -------------------------------------------------------------------

  defp check_h4_not_agent_attested(_path, %{"not_agent_attested" => nil}, _schema), do: []

  defp check_h4_not_agent_attested(path, %{"not_agent_attested" => marker}, schema)
       when is_map(marker) do
    keys = Map.keys(marker)
    required = schema.required
    optional = schema.optional
    legal = required ++ optional

    missing_required = required -- keys
    illegal_extra = keys -- legal

    violations =
      []
      |> add_if(
        missing_required != [],
        violation(
          path,
          "H4",
          "not_agent_attested missing required member(s): #{inspect(missing_required)}"
        )
      )
      |> add_if(
        illegal_extra != [],
        violation(
          path,
          "H4",
          "not_agent_attested has member(s) outside the closed set: #{inspect(illegal_extra)}"
        )
      )

    backfill_violation =
      if "backfill_note" in keys and path != schema.spent_exception_file do
        [
          violation(
            path,
            "H4",
            "backfill_note present, but the §4.1(b) spent exception names only " <>
              "#{inspect(schema.spent_exception_file)} -- admissible on no other file"
          )
        ]
      else
        []
      end

    violations ++ backfill_violation
  end

  defp check_h4_not_agent_attested(_path, _data, _schema), do: []

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list

  # -- advisory checks ------------------------------------------------------

  @cite_restate_threshold 6_000
  @under_specified_threshold 400

  defp check_advisory(path, data) do
    # ISS-1037 -- shape-safe extraction: never raises on a malformed handoff
    # (H7 reports those); for well-formed handoffs the values are unchanged.
    task = map_or_empty(Map.get(data, "task"))
    context = map_or_empty(Map.get(data, "context"))
    raw_result = Map.get(data, "result")
    result_map = map_or_empty(raw_result)

    desc =
      case Map.get(task, "description") do
        d when is_binary(d) -> d
        _ -> ""
      end

    acs = Map.get(task, "acceptance_criteria") || []
    artifacts_in = binary_elements(Map.get(context, "artifacts_in"))
    artifacts_out = binary_elements(Map.get(result_map, "artifacts_out"))

    result_warn =
      if is_nil(raw_result) or is_map(raw_result) do
        []
      else
        [
          {:warn, "H7-RESULT",
           "result is not an object (got #{json_type(raw_result)}); expected an object or null"}
        ]
      end

    summary =
      case Map.get(result_map, "summary") do
        s when is_binary(s) -> s
        _ -> ""
      end

    created_at =
      case Map.get(data, "created_at") do
        c when is_binary(c) -> c
        _ -> nil
      end

    names = artifacts_in |> Enum.map(&Path.basename/1) |> MapSet.new()

    h_size_1 =
      if String.length(desc) > @cite_restate_threshold and
           Enum.any?(names, &String.contains?(desc, &1)) do
        [
          {:warn, "H-SIZE-1",
           "cite-and-restate: description is #{String.length(desc)} chars and repeats a named artifacts_in file"}
        ]
      else
        []
      end

    # ISS-0825-adjacent hardening (2026-09-25): a handoff's `acceptance_criteria`
    # must be a list per HANDOFF_PROTOCOL.md's schema, but a malformed handoff
    # (e.g. a map grouping criteria by issue id) previously crashed this entire
    # full-corpus scan via `to_string/1` on a `{key, value}` tuple from
    # `Enum.reduce` over a map -- one bad file took down every PR's backend
    # gate. Treat a non-list shape as zero-length for this advisory-only length
    # heuristic rather than raising; the malformed shape itself is a real
    # authoring defect but is not this check's job to catch or crash on.
    ac_len =
      case acs do
        list when is_list(list) ->
          Enum.reduce(list, 0, fn ac, acc ->
            # ISS-1037 -- only scalars have a meaningful length; a nested
            # map/list element counts as 0 instead of raising in to_string/1.
            if is_binary(ac) or is_number(ac) or is_atom(ac),
              do: acc + String.length(to_string(ac)),
              else: acc
          end)

        _ ->
          0
      end

    h_size_2 =
      if String.length(desc) + ac_len < @under_specified_threshold do
        [
          {:warn, "H-SIZE-2",
           "under-specified: description + acceptance_criteria total #{String.length(desc) + ac_len} chars"}
        ]
      else
        []
      end

    artifacts_out_self_ref =
      if created_at_after_rule?(created_at) and self_referencing?(path, artifacts_out) do
        [{:warn, "ARTIFACTS_OUT_SELF_REF", "result.artifacts_out lists this handoff's own file"}]
      else
        []
      end

    %{
      path: path,
      warnings: h_size_1 ++ h_size_2 ++ artifacts_out_self_ref ++ result_warn,
      size_info: %{
        desc_len: String.length(desc),
        summary_len: String.length(summary)
      }
    }
  end

  defp map_or_empty(v) when is_map(v), do: v
  defp map_or_empty(_), do: %{}

  defp binary_elements(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp binary_elements(_), do: []

  defp self_referencing?(path, artifacts_out) do
    base = Path.basename(path)

    Enum.any?(artifacts_out, fn out ->
      out_base = Path.basename(out)
      out_base == base or String.ends_with?(path, out) or String.ends_with?(out, path)
    end)
  end

  # Handoffs created at or after @artifacts_out_rule_commit's landing are in
  # scope for the WARN; earlier ones are historical and exempt. We can't ask
  # git "was this created_at before or after a commit" directly, so we use
  # the commit's own committed-at timestamp as the floor -- resolved once,
  # lazily, via `git show`.
  defp created_at_after_rule?(nil), do: false

  defp created_at_after_rule?(created_at) do
    with {:ok, ts, _} <- DateTime.from_iso8601(created_at),
         floor when not is_nil(floor) <- rule_commit_timestamp() do
      DateTime.compare(ts, floor) != :lt
    else
      _ -> false
    end
  end

  defp rule_commit_timestamp do
    case Process.get(:artifacts_out_rule_floor, :unset) do
      :unset ->
        floor = fetch_rule_commit_timestamp()
        Process.put(:artifacts_out_rule_floor, floor)
        floor

      cached ->
        cached
    end
  end

  defp fetch_rule_commit_timestamp do
    case System.cmd("git", ["show", "-s", "--format=%cI", @artifacts_out_rule_commit],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case out |> String.trim() |> DateTime.from_iso8601() do
          {:ok, ts, _offset} -> ts
          {:error, _reason} -> nil
        end

      _ ->
        nil
    end
  end

  # -- registry coverage ------------------------------------------------------

  # `dir` is the directory actually scanned (§2.1's resolve_dir/1 result) --
  # identical to @handoffs_dir on the default no-flag path, so this
  # function's behaviour there is unchanged from before ISS-0440. Threading
  # it through (rather than hardcoding @handoffs_dir here) avoids computing
  # nonsense run_ids when `files` came from a --dir scratch fixture, since
  # H5 registry-coverage reporting was never meant to run against anything
  # but the directory that was actually scanned.
  # ISS-0819 -- H5 is skipped entirely in single-file mode (`scan_target` a
  # regular file): the run_id derivation below assumes `scan_target` is the
  # immediate parent directory of `<run_id>/`, which a single file's own
  # calling convention does not guarantee, and what H5 verifies (two-way
  # coverage between handoffs/<run_id>/ directories and registry.json) is
  # inherently a corpus-level property, not a per-file one. See design doc
  # §4 for the full rationale. registry.json is not read at all in this
  # branch.
  defp check_registry_coverage(files, scan_target) do
    if File.regular?(scan_target) do
      %{missing_from_registry: [], missing_on_disk: []}
    else
      do_check_registry_coverage(files, scan_target)
    end
  end

  defp do_check_registry_coverage(files, dir) do
    disk_run_ids =
      files
      |> Enum.map(&(&1 |> Path.relative_to(dir) |> Path.split() |> hd()))
      |> Enum.uniq()
      |> MapSet.new()

    registry_run_ids =
      case File.read(@registry_file) do
        {:ok, raw} ->
          case raw |> strip_bom() |> Jason.decode() do
            {:ok, %{"runs" => runs}} when is_list(runs) ->
              runs
              |> Enum.filter(&is_map/1)
              |> Enum.map(& &1["run_id"])
              |> Enum.reject(&is_nil/1)
              |> MapSet.new()

            _ ->
              MapSet.new()
          end

        _ ->
          MapSet.new()
      end

    missing_from_registry = MapSet.difference(disk_run_ids, registry_run_ids) |> Enum.sort()
    missing_on_disk = MapSet.difference(registry_run_ids, disk_run_ids) |> Enum.sort()

    %{missing_from_registry: missing_from_registry, missing_on_disk: missing_on_disk}
  end

  # -- output ---------------------------------------------------------------

  defp print_hard_violations(results) do
    new = Enum.flat_map(results, & &1.hard_new)
    grandfathered = Enum.flat_map(results, & &1.hard_grandfathered)

    if new != [] do
      IO.puts(@rule)
      IO.puts("NEW HARD VIOLATIONS (fail the build):")

      Enum.each(new, fn v ->
        IO.puts("  [#{v.rule}] #{v.path}: #{v.message}")
      end)
    end

    if grandfathered != [] do
      IO.puts(@rule)
      IO.puts("GRANDFATHERED (pre-existing, traced to ISS-0190, do not fail the build):")

      Enum.each(grandfathered, fn v ->
        IO.puts("  [#{v.rule}] #{v.path}: #{v.message}")
      end)
    end
  end

  defp print_advisory(results) do
    all_warnings =
      Enum.flat_map(results, fn r -> Enum.map(r.advisory.warnings, &{r.path, &1}) end)

    if all_warnings != [] do
      IO.puts(@rule)
      IO.puts("ADVISORY (WARN, does not affect exit code):")

      Enum.each(all_warnings, fn {path, {:warn, rule, msg}} ->
        IO.puts("  [#{rule}] #{path}: #{msg}")
      end)
    end

    sizes = Enum.map(results, & &1.advisory.size_info)
    desc_lens = Enum.map(sizes, & &1.desc_len) |> Enum.sort()
    summary_lens = Enum.map(sizes, & &1.summary_len) |> Enum.sort()

    IO.puts(@rule)
    IO.puts("H-SIZE-3 (INFO, report only):")
    IO.puts("  n_steps: #{length(results)}")

    IO.puts(
      "  task.description len -- median: #{median(desc_lens)}, max: #{Enum.max(desc_lens, fn -> 0 end)}, total: #{Enum.sum(desc_lens)}"
    )

    h1_hits =
      results
      |> Enum.flat_map(& &1.advisory.warnings)
      |> Enum.count(fn {:warn, rule, _} -> rule == "H-SIZE-1" end)

    IO.puts("  H-SIZE-1 hits: #{h1_hits}")

    IO.puts(
      "  result.summary len -- median: #{median(summary_lens)}, max: #{Enum.max(summary_lens, fn -> 0 end)}, total: #{Enum.sum(summary_lens)}"
    )
  end

  defp print_registry(%{missing_from_registry: mfr, missing_on_disk: mod}, scan_target) do
    IO.puts(@rule)
    IO.puts("H5 REGISTRY COVERAGE:")

    # ISS-0819 -- disambiguate an empty pair caused by "H5 didn't run" (single-
    # file mode) from an empty pair caused by "H5 ran and found nothing."
    if File.regular?(scan_target) do
      IO.puts("  skipped: H5 is a corpus-level check, not applicable to a single-file scan")
    end

    IO.puts("  run_id on disk but missing from registry.json: #{inspect(mfr)}")
    IO.puts("  run_id in registry.json but missing on disk: #{inspect(mod)}")
  end

  defp median([]), do: 0

  defp median(sorted) do
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end
end
