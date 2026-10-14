defmodule Mix.Tasks.Letflow.CheckRequirementsRegistration do
  @shortdoc "Classifies every docs/requirements.yaml entry's letflow-queue registration state"

  @moduledoc """
  Implements ISS-0231: requirement-registration drift detection.

  ISS-0221's resolution claimed that every requirement in
  `docs/requirements.yaml` already carried an `impl_order`, "checked via a
  full-file scan, not a sample". The claim was false when written. The
  verifying scan matched only the *registered field form* (a line
  containing `impl_order:`), and `docs/agents/protocols/TASK_QUEUE.md`
  permits a second, deliberately-deferred surface form whose text contains
  that same substring:

      # impl_order: UNREGISTERED -- see the S8 note above

  So 21 deliberate deferrals were counted as registrations and the scan
  concluded zero unregistered. Nothing in the pipeline re-checked the
  conclusion, and the only symptom of the underlying condition is an idle
  pipeline -- i.e. a false all-clear about queue registration was
  unfalsifiable by any automated gate.

  This task makes registration state **classified, total, and printed on
  every gate run**.

  ## The four states (a partition -- every entry lands in exactly one)

    * `:registered`   -- exactly one attributed line of the field form
      `impl_order: <integer>`.
    * `:deferred`     -- exactly one attributed line of the marker form
      `# impl_order: UNREGISTERED <rationale>`.
    * `:neither`      -- no attributed line contains the token
      `impl_order` at all. The genuinely invisible case, and the exact
      condition ISS-0221 was filed about.
    * `:unclassified` -- an attributed `impl_order` line matching neither
      recognised shape, **or** more than one attributed `impl_order`
      line, **or** an entry whose id is not a well-formed `REQ-NNN`.

  ### Why this cannot be fooled the same way

  The classifier's final clause is `:unclassified`, and `:unclassified`
  hard-fails. There is no "everything else is registered" branch anywhere.
  Attribution of a line to an entry is decided by position and
  indentation; whether a line *concerns registration* is decided by the
  bare token `impl_order`; and only then is the shape matched. A surface
  form this module does not recognise therefore appears as a named,
  failing entry instead of being absorbed into a bucket. (Design doc
  section 3(b)/3(d); section 3(c)'s totality claim was corrected by
  CODE-DESIGN-VALIDATOR -- see R5 below.)

  ## Rules (any violation => non-zero exit)

    * **R1** -- no entry is `:neither`. A silently unregistered
      requirement has no rationale recorded anywhere and is
      indistinguishable from an oversight.
    * **R2** -- no entry is `:unclassified`. An unrecognised surface form
      is the ISS-0231 root cause itself reappearing.
    * **R3** -- a deferral carries a rationale: every marker-form line has
      non-empty text after `UNREGISTERED`. Fires exactly when
      `state == :deferred` and `rationale` is `nil` or the empty string.
    * **R4** -- requirement ids are unique.
    * **R5** -- the partition is total:
      `registered + deferred + neither + unclassified == entry_count`,
      and `entry_count > 0`. The equality half is a cheap aggregation
      sanity check, not a structural defence (it holds identically by
      construction); the `entry_count > 0` half does the real work -- a
      scan that finds zero entries must never be a silent green pass.
    * **R6** -- `docs/requirements.yaml` is readable and contains a
      top-level `requirements:` key.
    * **R7** -- *after the work-board cutover only* (ISS-1073 / GH #2430,
      `docs/status/work_board_cutover.yaml`): a requirement that is not
      terminal (`done` / `cancelled`) and is registered only by a legacy
      `impl_order: <n>` line carries no `gh: <number>`, so it has no work-board
      issue. Before cutover this rule never fires.

  ## The work-board registration form (ISS-1073 / GH #2430)

  The letflow-queue is replaced by GitHub issues
  (`docs/agents/protocols/WORK_BOARD.md`). A requirement is registered by an
  attributed, field-level (exactly four spaces) line

      gh: <positive integer>   # the GitHub issue number; optional `# comment`

  A `gh:` line classifies as `:registered`, alone or next to a legacy
  `impl_order: <n>` line (history is kept). During the transition either form
  registers a requirement; legacy `impl_order` lines on terminal requirements
  remain valid history after cutover (R7). The deliberate-deferral marker is
  unchanged. A malformed `gh:` line, more than one `gh:` line, or a `gh:` line
  next to the deferral marker is `:unclassified`, so a surface form this
  module does not recognise still fails by name.

  ## Always printed, never gating

  The full `:deferred` roster -- every id, grouped by stage, with its
  rationale text and the group counts -- plus the `:registered` count and
  the totality line, e.g.

      111 entries = 90 registered + 21 deferred + 0 neither + 0 unclassified

  **The deferred count never influences the exit code, at any value.**
  Deferrals in this project are deliberate and documented (three inline
  block notes in `docs/requirements.yaml` explain why S8/S9/S4 are held
  back), and a gate that is permanently red for a known intended state
  gets ignored -- the same failure class as a check nobody runs. So the
  split follows *documentedness*, not registration state: documented debt
  is printed loudly and stays green; undocumented absence hard-fails.

  This module ships with **no exception list of any kind** -- no
  grandfathering, no wildcard, no prefix suppression. It is green on
  `main` at the moment it lands (measured: `:neither` = 0,
  `:unclassified` = 0 of 111), so any future red is a new fact.

  ## What this task never does

  It never writes to `docs/requirements.yaml`, never assigns or suggests
  an `impl_order` or `gh:` value, and makes no network call -- in particular
  none to the (retired) letflow-queue or to GitHub. Legacy `impl_order`
  values came only from the queue's registration call and `gh:` values only
  from the GitHub issue; an unregistered requirement carries neither at all,
  never a guessed one.

  It scans `docs/requirements.yaml` **only** -- never `lib/`. That is
  deliberate: this moduledoc itself contains both surface forms it
  recognises, so a directory-wide scan would make the module fail its own
  check (`docs/anti-patterns.md`, "A grep-shaped acceptance criterion can
  be tripped by the module's own moduledoc describing the invariant").

  ## Parsing model

  Line-oriented, not YAML. This project has no YAML dependency and adding
  one for a bug fix would be a library choice requiring REVIEWER sign-off.
  Only lines after the top-level `requirements:` key are scanned, so the
  10 `stages:` entries are out of scope by construction rather than by an
  exception list. Within that section an entry starts at a line matching
  two-space `- id: ` and runs to the line before the next such line. A
  line belongs to an entry only if its indentation is **4 or more
  spaces** -- the file's field level. That rule matters: four prose
  block-note lines mentioning `impl_order` sit at 2-space indent between
  entries and describe the convention rather than any one entry's state;
  without the indentation rule three requirements would gain a second
  attributed line and be misclassified.

  Both recognised shapes are anchored to the whole line. An unanchored
  marker pattern would match `impl_order: 5  # was UNREGISTERED until
  Tuesday`, reproducing the absorption bug with the buckets reversed.

  ## Usage

      mix letflow.check_requirements_registration

  Wired into the `letflow.check` alias immediately after
  `letflow.check_toolchain` -- a check nobody runs is not a check, and
  this repository has no CI configuration, so `mix letflow.check` is the
  only gate surface there is.

  Exits `0` iff R1-R6 all hold; `Mix.raise/1` otherwise, naming every
  violating entry by exact `REQ-NNN` and rule id.
  """

  use Mix.Task

  alias Mix.Letflow.WorkBoardCutover

  @requirements_file "docs/requirements.yaml"

  @rule String.duplicate("=", 72)
  @thin_rule String.duplicate("-", 72)

  @requirements_key_re ~r/^requirements:\s*$/
  @entry_start_re ~r/^  - id: /
  @id_line_re ~r/^  - id:\s*(.*?)\s*$/
  @attributed_re ~r/^ {4,}\S/
  @token_re ~r/\bimpl_order\b/
  @field_form_re ~r/^\s+impl_order:\s+(\d+)\s*(#.*)?$/
  @marker_form_re ~r/^\s+#\s*impl_order:\s*UNREGISTERED\b\s*(\S.*)?$/
  @well_formed_id_re ~r/^REQ-\d+$/
  # Work-board registration (ISS-1073): field level, exactly four spaces, so a
  # prose line inside a folded block (6+ spaces) is never read as a field.
  @gh_token_re ~r/^ {4}gh:/
  @gh_form_re ~r/^ {4}gh:[ \t]+([1-9]\d*)\s*(#.*)?$/
  @terminal_statuses ["done", "cancelled"]
  @stage_re ~r/^\s+stage:\s*(\S+)/
  # First whitespace-delimited token only, mirroring @stage_re: 8 real `status:`
  # lines carry a trailing `# ...` comment, which a rest-of-line capture would
  # sweep in. Stored raw and uninterpreted -- all status semantics live in
  # `Mix.Tasks.Letflow.CheckDeferralStaleness` (ISS-0258), never here.
  @status_re ~r/^\s+status:\s*(\S+)/

  @type state :: :registered | :deferred | :neither | :unclassified

  @type entry :: %{
          id: String.t(),
          line: pos_integer(),
          stage: String.t() | nil,
          status: String.t() | nil,
          state: state(),
          impl_order: non_neg_integer() | nil,
          gh: pos_integer() | nil,
          rationale: String.t() | nil,
          detail: String.t() | nil
        }

  @type violation :: %{
          rule: String.t(),
          id: String.t() | nil,
          line: pos_integer() | nil,
          message: String.t()
        }

  @type counts :: %{
          registered: non_neg_integer(),
          deferred: non_neg_integer(),
          neither: non_neg_integer(),
          unclassified: non_neg_integer()
        }

  @type report :: %{
          entries: [entry()],
          entry_count: non_neg_integer(),
          counts: counts(),
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
            "mix letflow.check_requirements_registration: FAILED [R6] -- " <>
              "could not read #{@requirements_file}: #{inspect(reason)}"
          )
      end

    report = scan(content, cutover: WorkBoardCutover.cutover?())

    report |> render() |> IO.write()

    if report.violations == [] do
      :ok
    else
      Mix.raise(
        "mix letflow.check_requirements_registration: FAILED -- " <>
          "#{length(report.violations)} violation(s):\n" <>
          Enum.map_join(report.violations, "\n", &format_violation/1)
      )
    end
  end

  # -- pure core ------------------------------------------------------------

  @doc """
  Classifies the whole file. Pure: takes **content**, not a path, so
  hermetic fixture strings can be passed directly.

  Never raises on content -- a malformed file is expressed as violations
  in the returned report. Raises only on a non-binary argument.
  """
  @spec scan(String.t(), keyword()) :: report()
  def scan(content, opts \\ []) when is_binary(content) and is_list(opts) do
    cutover = Keyword.get_lazy(opts, :cutover, &WorkBoardCutover.cutover?/0)

    numbered =
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} -> {n, line} end)

    case Enum.find_index(numbered, fn {_n, line} -> Regex.match?(@requirements_key_re, line) end) do
      nil ->
        %{
          entries: [],
          entry_count: 0,
          counts: zero_counts(),
          violations: [
            violation(
              "R6",
              nil,
              nil,
              "no top-level `requirements:` key found -- the file's shape changed " <>
                "underneath this check; a zero-entry pass is never silent"
            )
          ]
        }

      idx ->
        section = Enum.drop(numbered, idx + 1)

        # Derived by counting entry-start lines directly over the section,
        # separately from the split/classify fold below.
        entry_count =
          Enum.count(section, fn {_n, line} -> Regex.match?(@entry_start_re, line) end)

        entries = section |> split_entries() |> Enum.map(&classify_entry/1)
        counts = tally(entries)

        %{
          entries: entries,
          entry_count: entry_count,
          counts: counts,
          violations: collect_violations(entries, counts, entry_count, cutover)
        }
    end
  end

  @doc """
  Classifies a single entry -- the list of `{line_number, line_text}`
  pairs from its `- id:` line through the line before the next one.

  Returns exactly one `state` per call. This is the unit the hermetic
  fixture tests and every mutant target.
  """
  @spec classify_entry([{pos_integer(), String.t()}]) :: entry()
  def classify_entry([{line_no, id_line} | body]) do
    id = extract_id(id_line)
    attributed = Enum.filter(body, fn {_n, line} -> Regex.match?(@attributed_re, line) end)

    base = %{
      id: id,
      line: line_no,
      stage: extract_stage(attributed),
      status: extract_status(attributed),
      state: :unclassified,
      impl_order: nil,
      gh: nil,
      rationale: nil,
      detail: nil
    }

    if Regex.match?(@well_formed_id_re, id) do
      classify_registration(
        base,
        # A `gh:` line is classified as a gh line only, even when its trailing
        # comment mentions `impl_order` (the backfilled lines say "impl_order above
        # is history").
        Enum.filter(attributed, fn {_n, l} ->
          token?(l) and not Regex.match?(@gh_token_re, l)
        end),
        Enum.filter(body, fn {_n, l} -> Regex.match?(@gh_token_re, l) end)
      )
    else
      %{base | detail: "id #{inspect(id)} is not a well-formed REQ-NNN"}
    end
  end

  @spec classify_registration(
          entry(),
          [{pos_integer(), String.t()}],
          [{pos_integer(), String.t()}]
        ) :: entry()
  defp classify_registration(base, impl_lines, []), do: classify_legacy(base, impl_lines)

  defp classify_registration(base, impl_lines, [{_n, gh_line}]) do
    case Regex.run(@gh_form_re, gh_line) do
      nil ->
        %{
          base
          | detail:
              "attributed gh line is not `gh: <positive integer>`: " <>
                inspect(String.trim(gh_line))
        }

      [_, number | _] ->
        gh_registered(%{base | gh: String.to_integer(number)}, classify_legacy(base, impl_lines))
    end
  end

  defp classify_registration(base, _impl_lines, gh_lines) do
    %{
      base
      | detail:
          "#{length(gh_lines)} attributed gh lines (ambiguous), at line(s) " <>
            Enum.map_join(gh_lines, ", ", fn {n, _} -> Integer.to_string(n) end)
    }
  end

  # A `gh:` line registers the entry. Beside it, a legacy field-form
  # `impl_order: <n>` is kept as history and a bare absence is fine; the
  # deferral marker (or any unrecognised/ambiguous impl_order shape) contradicts
  # a real work-board issue and stays unclassified.
  @spec gh_registered(entry(), entry()) :: entry()
  defp gh_registered(with_gh, %{state: :neither}), do: %{with_gh | state: :registered}

  defp gh_registered(with_gh, %{state: :registered, impl_order: n}),
    do: %{with_gh | state: :registered, impl_order: n}

  defp gh_registered(with_gh, legacy) do
    reason =
      if legacy.state == :deferred,
        do: "deferral marker -- a requirement with a GitHub issue is not deferred",
        else: "registration form this check does not recognise: #{legacy.detail}"

    %{with_gh | detail: "`gh:` line sits beside a " <> reason}
  end

  @spec classify_legacy(entry(), [{pos_integer(), String.t()}]) :: entry()
  defp classify_legacy(base, []), do: %{base | state: :neither}

  defp classify_legacy(base, [{_n, line}]) do
    field = Regex.run(@field_form_re, line)
    marker = Regex.run(@marker_form_re, line)

    cond do
      field != nil ->
        %{base | state: :registered, impl_order: field |> Enum.at(1) |> String.to_integer()}

      marker != nil ->
        %{base | state: :deferred, rationale: marker |> Enum.at(1) |> normalise_rationale()}

      true ->
        %{
          base
          | detail:
              "attributed impl_order line matches neither recognised shape: " <>
                inspect(String.trim(line))
        }
    end
  end

  defp classify_legacy(base, lines) do
    %{
      base
      | detail:
          "#{length(lines)} attributed impl_order lines (ambiguous), at line(s) " <>
            Enum.map_join(lines, ", ", fn {n, _} -> Integer.to_string(n) end)
    }
  end

  @doc """
  Renders the always-printed report: the registered count, the full
  `:deferred` roster grouped by stage, the totality line, and -- when
  present -- the violation list. Pure, so a test can assert on the roster
  text without capturing task IO.
  """
  @spec render(report()) :: iodata()
  def render(report) do
    [
      @rule,
      "\n",
      "mix letflow.check_requirements_registration -- ",
      @requirements_file,
      "\n",
      @rule,
      "\n",
      render_deferred(report),
      @thin_rule,
      "\n",
      totality_line(report),
      "\n",
      render_violations(report),
      @rule,
      "\n"
    ]
  end

  @spec totality_line(report()) :: String.t()
  defp totality_line(%{entry_count: entry_count, counts: c}) do
    "#{entry_count} entries = #{c.registered} registered + #{c.deferred} deferred + " <>
      "#{c.neither} neither + #{c.unclassified} unclassified"
  end

  @spec render_deferred(report()) :: iodata()
  defp render_deferred(%{entries: entries}) do
    deferred = Enum.filter(entries, &(&1.state == :deferred))

    if deferred == [] do
      ["DEFERRED (visible debt -- always reported, never gates): none\n"]
    else
      groups =
        deferred
        |> Enum.group_by(& &1.stage)
        |> Enum.sort_by(fn {stage, _group} -> stage || "" end)

      [
        "DEFERRED (visible debt -- always reported, never gates):\n",
        Enum.map(groups, fn {stage, group} ->
          [
            "  ",
            stage || "(no stage)",
            " (",
            Integer.to_string(length(group)),
            "):\n",
            Enum.map(Enum.sort_by(group, & &1.line), fn e ->
              ["    ", e.id, "  ", e.rationale || "(NO RATIONALE -- R3)", "\n"]
            end)
          ]
        end),
        "  total deferred: ",
        Integer.to_string(length(deferred)),
        "\n"
      ]
    end
  end

  @spec render_violations(report()) :: iodata()
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

  @spec collect_violations([entry()], counts(), non_neg_integer(), boolean()) :: [violation()]
  defp collect_violations(entries, counts, entry_count, cutover) do
    Enum.flat_map(entries, &entry_violations/1) ++
      Enum.flat_map(entries, &cutover_violations(&1, cutover)) ++
      duplicate_id_violations(entries) ++
      totality_violations(counts, entry_count)
  end

  @spec entry_violations(entry()) :: [violation()]
  defp entry_violations(%{state: :neither} = e) do
    [
      violation(
        "R1",
        e.id,
        e.line,
        "carries no `impl_order` line of any form and no `gh:` issue -- a deliberate " <>
          "deferral must be recorded as `# impl_order: UNREGISTERED -- <rationale>`; bare absence is " <>
          "indistinguishable from an oversight"
      )
    ]
  end

  defp entry_violations(%{state: :unclassified} = e) do
    [violation("R2", e.id, e.line, "unrecognised registration form -- #{e.detail}")]
  end

  defp entry_violations(%{state: :deferred, rationale: r} = e) when r in [nil, ""] do
    [
      violation(
        "R3",
        e.id,
        e.line,
        "deferral marker carries no rationale after `UNREGISTERED` -- a deferral " <>
          "nobody recorded a reason for cannot be audited"
      )
    ]
  end

  defp entry_violations(_entry), do: []

  # R7: after cutover a live (non-terminal) requirement needs its work-board
  # issue; a legacy impl_order alone is history for terminal entries only.
  @spec cutover_violations(entry(), boolean()) :: [violation()]
  defp cutover_violations(
         %{state: :registered, gh: nil, impl_order: n, status: status} = e,
         true
       )
       when is_integer(n) and status not in @terminal_statuses do
    [
      violation(
        "R7",
        e.id,
        e.line,
        "work board is live (docs/status/work_board_cutover.yaml) and this " <>
          "#{inspect(status)} requirement carries only the legacy `impl_order: #{n}`; add " <>
          "`gh: <issue number>` (legacy impl_order stays as history)"
      )
    ]
  end

  defp cutover_violations(_entry, _cutover), do: []

  @spec duplicate_id_violations([entry()]) :: [violation()]
  defp duplicate_id_violations(entries) do
    entries
    |> Enum.group_by(& &1.id)
    |> Enum.filter(fn {_id, group} -> length(group) > 1 end)
    |> Enum.sort_by(fn {id, _group} -> id end)
    |> Enum.map(fn {id, group} ->
      lines = group |> Enum.map(& &1.line) |> Enum.sort()

      violation(
        "R4",
        id,
        List.first(lines),
        "duplicate requirement id -- appears at lines " <>
          Enum.map_join(lines, ", ", &Integer.to_string/1)
      )
    end)
  end

  @spec totality_violations(counts(), non_neg_integer()) :: [violation()]
  defp totality_violations(counts, entry_count) do
    sum = counts.registered + counts.deferred + counts.neither + counts.unclassified

    zero =
      if entry_count == 0 do
        [
          violation(
            "R5",
            nil,
            nil,
            "the requirements section contains zero entries -- a scan that finds " <>
              "nothing is always a hard failure, never a green pass"
          )
        ]
      else
        []
      end

    total =
      if sum == entry_count do
        []
      else
        [
          violation(
            "R5",
            nil,
            nil,
            "partition is not total: #{sum} classified entries vs. #{entry_count} " <>
              "entry-start lines in the requirements section"
          )
        ]
      end

    zero ++ total
  end

  # -- helpers --------------------------------------------------------------

  @spec split_entries([{pos_integer(), String.t()}]) :: [[{pos_integer(), String.t()}]]
  defp split_entries(section) do
    section
    |> Enum.reduce([], fn {_n, line} = pair, acc ->
      cond do
        Regex.match?(@entry_start_re, line) -> [[pair] | acc]
        acc == [] -> acc
        true -> [[pair | hd(acc)] | tl(acc)]
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  @spec extract_id(String.t()) :: String.t()
  defp extract_id(id_line) do
    case Regex.run(@id_line_re, id_line) do
      [_, id] -> id
      nil -> String.trim(id_line)
    end
  end

  @spec extract_stage([{pos_integer(), String.t()}]) :: String.t() | nil
  defp extract_stage(attributed) do
    Enum.find_value(attributed, fn {_n, line} ->
      case Regex.run(@stage_re, line) do
        [_, stage] -> stage
        nil -> nil
      end
    end)
  end

  @spec extract_status([{pos_integer(), String.t()}]) :: String.t() | nil
  defp extract_status(attributed) do
    Enum.find_value(attributed, fn {_n, line} ->
      case Regex.run(@status_re, line) do
        [_, status] -> status
        nil -> nil
      end
    end)
  end

  @spec token?(String.t()) :: boolean()
  defp token?(line), do: Regex.match?(@token_re, line)

  @spec normalise_rationale(String.t() | nil) :: String.t() | nil
  defp normalise_rationale(nil), do: nil

  defp normalise_rationale(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @spec zero_counts() :: counts()
  defp zero_counts, do: %{registered: 0, deferred: 0, neither: 0, unclassified: 0}

  @spec tally([entry()]) :: counts()
  defp tally(entries) do
    Enum.reduce(entries, zero_counts(), fn e, acc ->
      Map.update!(acc, e.state, &(&1 + 1))
    end)
  end

  @spec violation(String.t(), String.t() | nil, pos_integer() | nil, String.t()) :: violation()
  defp violation(rule, id, line, message) do
    %{rule: rule, id: id, line: line, message: message}
  end
end
