defmodule Mix.Tasks.Letflow.CheckIssueRefs do
  @shortdoc "Enforces the prefixed issue-numbering schema across docs/issues/"

  @moduledoc """
  Enforces `docs/agents/protocols/ISSUE_QUEUE.md`'s "Numbering schema"
  section: three registries number independently from 1, so every
  cross-reference must carry its registry's prefix.

      id: ISS-0030          # local record (docs/issues/)
      queue_ref: Q-76       # letflow-queue task
      github_ref: GH-89     # GitHub issue

  ## Why this exists as a gate rather than a convention

  The rule this schema replaces — "`ISS-0187` is queue task `187`" — was
  itself documented, in the same protocol file, and it decayed anyway. It
  was true for the window in which queue-allocated ids were the only source
  of new issue numbers, and nothing re-checked it once that stopped being
  so. Measured on 2026-09-09 it held for 172 of 305 files: 27 contradicted
  it outright and 104 predated the queue.

  A documented convention with no validating step is exactly what
  `docs/migration/decisions/0004-humanless-pipeline.md` says will drift.
  This task is that validating step, applied to the project's own
  conventions rather than to its code.

  ## Rules

    * **R1 — no bare-number cross-reference.** `github_ref: 89` and
      `queue_ref: 76` are violations; the registry is part of the value.
      A bare number is the exact ambiguity the schema exists to remove.

    * **R2 — no superseded field name.** `github_issue`, `github_issue_number`
      and `queue_task_id` were normalised to `github_ref`/`queue_ref` across
      all 305 files in one pass. Reintroducing one re-splits the corpus into
      two shapes that every reader then has to handle.

    * **R3 — well-formed values.** A non-null `github_ref` matches `GH-<n>`
      and a non-null `queue_ref` matches `Q-<n>`, `<n>` being a positive
      integer with no leading zeros. A full GitHub URL is not a ref: it is
      the shape 139 files used before normalisation.

    * **R4 — `null` is explicit and explained.** `null` is legitimate and
      means "not in that registry" — a local-only finding, or one filed
      before the queue existed. It must carry a trailing comment saying
      which, so a reader can tell a deliberate absence from an omission.
      This is the same reasoning `check_requirements_registration` applies
      to a bare-missing `impl_order`.

    * **R5 — `id` matches the filename.** `docs/issues/ISS-0030.yaml` must
      declare `id: ISS-0030`. A file whose `id` is a placeholder such as
      `PENDING` is invisible to every registry at once. Since the work-board
      change (ISS-1073 / GH #2430) a record may instead be named by its
      GitHub issue number: `docs/issues/GH-2430.yaml` declares `id: GH-2430`.

    * **R6 — a GH-named record points at its own issue.** `GH-2430.yaml` must
      carry `github_ref: GH-2430`; the number in the name *is* the machine id
      (`docs/agents/protocols/WORK_BOARD.md`), so a different or null
      `github_ref` is a record about one issue filed under another's name.

    * **R7 — after cutover, no new `ISS-NNNN` names.** Only once
      `docs/status/work_board_cutover.yaml` says `cutover: true`: an
      `ISS-NNNN` file with `NNNN` above that file's `last_legacy_iss` is
      refused, because the number would have to come from the retired queue.
      Existing `ISS-*.yaml` files and their `queue_ref` fields stay as
      history. Before cutover this rule never fires, and a `queue_ref` is
      never required: a record carrying only a GitHub number is valid in
      both modes.

  ## Parsing model

  Line-oriented, not YAML, matching `check_requirements_registration`'s own
  stated reasoning: this project has no YAML dependency, and adding one for
  a lint would be a library choice needing REVIEWER sign-off. Only
  **column-0** field lines are considered, which is what keeps prose
  mentions inside `description: >` blocks — where `queue_task_id: 128`
  legitimately appears as quoted history — from being read as identity
  fields. Commentary fields like `github_issue_note` are matched exactly,
  not by prefix, so they are unaffected.

  ## Usage

      mix letflow.check_issue_refs

  Wired into the `letflow.check` alias alongside the other fast,
  non-compiling scans. Exits `0` iff R1-R5 all hold; `Mix.raise/1`
  otherwise, naming every violating file and rule id.
  """

  use Mix.Task

  alias Mix.Letflow.WorkBoardCutover

  @issues_dir "docs/issues"

  @gh_field "github_ref"
  @queue_field "queue_ref"
  @superseded %{
    "github_issue" => @gh_field,
    "github_issue_number" => @gh_field,
    "queue_task_id" => @queue_field
  }

  # Column-0 `key: value` only -- indented lines are description-block prose.
  @field_re ~r/^(?<key>[a-z_]+):[ \t]+(?<val>.*)$/
  @gh_ok ~r/^GH-[1-9]\d*$/
  @queue_ok ~r/^Q-[1-9]\d*$/
  @id_ok ~r/^ISS-\d{4}$/
  @gh_id_ok ~r/^GH-[1-9]\d*$/

  @impl Mix.Task
  def run(_argv) do
    config = WorkBoardCutover.load!()
    opts = [cutover: config.cutover, last_legacy_iss: config.last_legacy_iss]

    violations = @issues_dir |> issue_files() |> Enum.flat_map(&check_file(&1, opts))

    report(violations)

    if violations != [] do
      Mix.raise(
        "mix letflow.check_issue_refs: FAILED -- #{length(violations)} violation(s):\n" <>
          Enum.map_join(violations, "\n", &format/1)
      )
    end
  end

  @doc false
  def issue_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  @doc """
  Audits one file's content. Returns a list of violation maps.

  Exposed so tests can exercise the rules against fixture content without
  writing files, the same way the sibling checks' own audit functions are.
  """
  def audit(content, path, opts \\ []) when is_binary(content) and is_binary(path) do
    lines = String.split(content, ~r/\r?\n/)

    id_violations(lines, path, opts) ++
      Enum.flat_map(Enum.with_index(lines, 1), fn {line, no} ->
        line_violations(line, no, path)
      end)
  end

  defp check_file(path, opts), do: path |> File.read!() |> audit(path, opts)

  defp id_violations(lines, path, opts) do
    expected = path |> Path.basename(".yaml")
    declared = Enum.find_value(lines, &capture(&1, "id"))

    cond do
      declared == nil ->
        [v(:R5, path, 0, "declares no `id` field")]

      declared == expected and Regex.match?(@gh_id_ok, declared) ->
        gh_named_violations(lines, declared, path)

      declared == expected and Regex.match?(@id_ok, declared) ->
        legacy_name_violations(declared, path, opts)

      not (Regex.match?(@id_ok, declared) or Regex.match?(@gh_id_ok, declared)) ->
        [
          v(
            :R5,
            path,
            0,
            "`id: #{declared}` is not an ISS-NNNN or GH-<n> identifier -- a placeholder " <>
              "id is invisible to every registry at once"
          )
        ]

      true ->
        [v(:R5, path, 0, "`id: #{declared}` does not match filename `#{expected}`")]
    end
  end

  # R6: the number in a GH-named record's name is its machine id.
  defp gh_named_violations(lines, declared, path) do
    case Enum.find_value(lines, &capture(&1, @gh_field)) do
      ^declared ->
        []

      other ->
        [
          v(
            :R6,
            path,
            0,
            "`id: #{declared}` requires `github_ref: #{declared}`, found " <>
              inspect(other || "no github_ref")
          )
        ]
    end
  end

  # R7: after cutover the queue no longer allocates ISS numbers.
  defp legacy_name_violations(declared, path, opts) do
    # Pure: only run/1 reads the real switch file and passes it explicitly (hermetic callers).
    cutover = Keyword.get(opts, :cutover, false)
    last = Keyword.get(opts, :last_legacy_iss)

    "ISS-" <> digits = declared

    if cutover and is_integer(last) and String.to_integer(digits) > last do
      [
        v(
          :R7,
          path,
          0,
          "`#{declared}` is above last_legacy_iss #{last}: after the work-board cutover " <>
            "new records are named by GitHub issue number (GH-<n>.yaml)"
        )
      ]
    else
      []
    end
  end

  defp line_violations(line, no, path) do
    case Regex.named_captures(@field_re, line) do
      nil -> []
      %{"key" => key, "val" => val} -> field_violations(key, strip_comment(val), val, no, path)
    end
  end

  defp field_violations(key, value, raw, no, path) do
    cond do
      Map.has_key?(@superseded, key) ->
        [
          v(
            :R2,
            path,
            no,
            "`#{key}:` is a superseded field name -- use `#{@superseded[key]}:` " <>
              "with a prefixed value"
          )
        ]

      key not in [@gh_field, @queue_field] ->
        []

      value == "null" ->
        if has_comment?(raw),
          do: [],
          else: [
            v(
              :R4,
              path,
              no,
              "`#{key}: null` carries no comment -- say why this issue is absent from " <>
                "that registry, so a deliberate absence is distinguishable from an omission"
            )
          ]

      key == @gh_field ->
        if Regex.match?(@gh_ok, value), do: [], else: [malformed(:gh, key, value, no, path)]

      key == @queue_field ->
        if Regex.match?(@queue_ok, value), do: [], else: [malformed(:queue, key, value, no, path)]
    end
  end

  defp malformed(kind, key, value, no, path) do
    {rule, hint} =
      cond do
        Regex.match?(~r/^\d+$/, value) ->
          {:R1,
           "a bare number is ambiguous across three registries that all number from 1 -- " <>
             "write `#{prefix(kind)}#{value}`"}

        Regex.match?(~r{^https?://}, value) ->
          {:R3, "a URL is not a ref -- write `#{prefix(kind)}<n>`"}

        true ->
          {:R3, "expected `#{prefix(kind)}<n>` or `null`"}
      end

    v(rule, path, no, "`#{key}: #{value}` -- #{hint}")
  end

  defp prefix(:gh), do: "GH-"
  defp prefix(:queue), do: "Q-"

  defp capture(line, key) do
    case Regex.named_captures(@field_re, line) do
      %{"key" => ^key, "val" => val} -> strip_comment(val)
      _ -> nil
    end
  end

  # A `#` inside a quoted value is not a comment; these files never quote refs,
  # so the simple split is correct here and stays predictable.
  defp strip_comment(val) do
    val |> String.split("#", parts: 2) |> hd() |> String.trim() |> String.trim("\"")
  end

  defp has_comment?(raw), do: String.contains?(raw, "#")

  defp v(rule, path, line, message),
    do: %{rule: rule, path: path, line: line, message: message}

  defp format(%{rule: r, path: p, line: 0, message: m}), do: "[#{r}] #{p}: #{m}"
  defp format(%{rule: r, path: p, line: l, message: m}), do: "[#{r}] #{p}:#{l}: #{m}"

  defp report(violations) do
    files = @issues_dir |> issue_files() |> length()
    line = String.duplicate("=", 72)

    Mix.shell().info(line)
    Mix.shell().info("letflow.check_issue_refs -- #{files} file(s) under #{@issues_dir}/")

    if violations == [] do
      Mix.shell().info("OK -- every cross-reference is prefixed and well-formed.")
    else
      Mix.shell().info("VIOLATIONS (each one fails the run):")
      Enum.each(violations, &Mix.shell().info("  " <> format(&1)))
    end

    Mix.shell().info(line)
  end
end
