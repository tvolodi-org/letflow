defmodule Letflow.CiBackendPathFilterTest do
  @moduledoc """
  Q-1059 / GH #2411 (ISS-1059), acceptance criterion 2: a check fails when a path read by the
  backend gate is missing from the filter, so the gap cannot silently return.

  `.github/workflows/ci.yml`, step "Compute changed paths", feeds the changed-file list to
  `scripts/ci_changed_paths.sh` (GH #2622: the one source of CI's path rules), which prints
  `backend=true` iff a changed file matches `BACKEND_PATHS_RE`. A change confined to a path the backend gate READS but the
  regex omits (for example `.formatter.exs`, `docs/roles.md`, `docs/requirements.yaml`) would
  merge without the gate ever running on it. Three layers here:

    1. the regex is extracted from scripts/ci_changed_paths.sh (one single-quoted assignment
       line, else a clear failure) and compiled;
    2. a literal decision table: representative paths per class that MUST / must NOT trigger;
    3. the real guard: a scan of the files the gate executes (`test/**/*.exs`, `test/support`,
       `lib/mix/tasks/*.ex`, `mix.exs`) for string literals naming repo paths under the gate's
       input roots; every such path that exists in the tracked tree must match the regex or be
       in `@not_read_allowlist` with a stated reason.

  The in-memory mutation tests drop one alternative from the regex source and prove layers 2
  and 3 then report the gap (so a guard that cannot fail is caught here).

  Limits of the scan, stated so they are not mistaken for coverage: only double-quoted,
  single-line string literals are seen; a path assembled with `Path.join/2` from separate
  segments is invisible (the decision table covers the known ones); `\#{...}` interpolation is
  treated as a `*` wildcard.

  Known gap no filter can close: `test/letflow/no_smtp_secret_guard_test.exs` (lines 48-56) runs
  `git ls-files` and `git grep` over the WHOLE tracked tree, so any path, including README.md, can
  fail the backend gate. A change confined to a path the filter omits can therefore still break that
  test and merge ungated; the always-run-all-gates rule for push to main (ISS-0840) is the backstop.
  """

  use ExUnit.Case, async: true

  # GH #2622: the path rules moved out of ci.yml into this script (the one source).
  @rules_sh "scripts/ci_changed_paths.sh"

  # GH #2622: the four files of the CI/CD path and decision logic, and how many
  # `grep -qE ... <<<"$CHANGED"` here-string matches each must hold: the three rules live
  # only in the script; ci.yml feeds it, cd.yml and the decide script have no path rules.
  @here_string_files %{
    ".github/workflows/ci.yml" => 0,
    ".github/workflows/cd.yml" => 0,
    "scripts/ci_changed_paths.sh" => 3,
    "scripts/cd_qa_decide.sh" => 0
  }

  # Roots the backend gate may read, plus root-level files.
  @root_dirs ~w(docs handoffs web apps priv deploy .claude .github)
  @root_files ~w(.formatter.exs .gitattributes .env.example)

  # Paths that appear as string literals in gate sources, exist in the tracked tree, do NOT
  # match the filter, and are NOT read as input by the gate. Each key is an exact tracked
  # path (or, for a directory literal the filter does not reach, the literal itself).
  # Reason is mandatory. Keep this list small: an
  # entry here is a claim that a change confined to that path cannot change the gate result.
  @not_read_allowlist %{
    # Quoted only as TEXT asserted on, never opened: exam_definitions_test.exs:246 does
    # `assert description =~ "docs/anti-patterns.md"` on a string held in memory.
    "docs/anti-patterns.md" =>
      "substring asserted on an in-memory description; file is never read",

    # lib/mix/tasks/letflow.check_toolchain.ex:174 `@record`; its only use is an
    # interpolation into an output message (line 492). The gate reads `.tool-versions`.
    "docs/migration/decisions/0005-pin-formatting-toolchain.md" =>
      "printed in a check_toolchain message only; the task reads .tool-versions, not the record",

    # test/letflow/entities/definition/ddl_test.exs:459,480 assert that a module's SOURCE
    # TEXT / @moduledoc mentions the decision record by file name; the record is not opened.
    "docs/migration/decisions/0025-promoted-fk-ondelete-and-localized-text-search-strategy.md" =>
      "name asserted as a substring of Elixir source/moduledoc text; file is never read",

    # dlq_test.exs:373-374 and webhooks_test.exs:638-639: `assert moduledoc =~ "<path>"` on
    # the router's @moduledoc text. The web/ files are named, never opened.
    "web/src/api/dlq.ts" => "substring asserted on a moduledoc; file is never read",
    "web/src/types/api.ts" => "substring asserted on a moduledoc; file is never read"
  }

  # Files the gate reads WITHOUT any string literal naming them. Each is justified by the
  # command that reads it; `implicit_reads_are_real` below checks the command is still there.
  #   .formatter.exs  -- `mix format --check-formatted` (an alias step of `mix letflow.check`,
  #                      mix.exs) loads it to decide what to format and how.
  @implicit_reads [".formatter.exs"]

  # {path, must_trigger?, tracked_file_must_exist?}. `false` in the third slot marks a
  # pure-pattern entry: a representative of a class (a wildcard filename not tracked as such).
  @decision_table [
    # --- MUST trigger backend ---
    {"lib/letflow/engine.ex", true, true},
    {"test/letflow/engine_test.exs", true, true},
    {"priv/repo/migrations/20260101000000_x.exs", true, false},
    {"priv/keycloak/realms/bpm-default.json", true, true},
    {"priv/modules/exam/pack.json", true, true},
    {"priv/wasm_fixtures/req165_trivial.wat", true, true},
    {"priv/solutions/bilimbaga.json", true, true},
    {"config/config.exs", true, true},
    {"mix.exs", true, true},
    {"mix.lock", true, true},
    {".tool-versions", true, true},
    {".formatter.exs", true, true},
    {".gitattributes", true, true},
    {".env.example", true, true},
    {"scripts/seed_x.sh", true, false},
    {"deploy/Dockerfile", true, true},
    {".github/workflows/ci.yml", true, true},
    {".github/workflows/cd.yml", true, true},
    {"scripts/ci_changed_paths.sh", true, true},
    {"scripts/cd_qa_decide.sh", true, false},
    {".claude/agents/uat-runner.md", true, true},
    {"web/.env.example", true, true},
    {"web/vite.config.ts", true, true},
    {"web/tests/e2e/env04.e2e.spec.ts", true, true},
    {"web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts", true, true},
    {"docs/requirements.yaml", true, true},
    {"docs/issues/ISS-1059.yaml", true, false},
    {"docs/status/requirement_status.index.yaml", true, true},
    {"docs/status/work_board_cutover.yaml", true, true},
    {"docs/roles.md", true, true},
    {"docs/runbooks/x.md", true, false},
    {"docs/frontend/x-ui-widget-vocabulary.md", true, true},
    {"docs/migration/stage-7-simulation-uat-parity.md", true, true},
    {"docs/agents/shared/HANDOFF_PROTOCOL.md", true, true},
    {"handoffs/registry.json", true, true},
    {"handoffs/some-dir/step-01-x.json", true, false},
    # --- must NOT trigger backend ---
    {"README.md", false, true},
    {"CLAUDE.md", false, true},
    {"docs/anti-patterns.md", false, true},
    {"docs/agents/AGENT_SYSTEM.md", false, true},
    {"docs/issues/ISS-1059.md", false, false},
    {"handoffs/orchestrator.log", false, false},
    {"web/src/main.tsx", false, true},
    {"apps/mobile/lib/main.dart", false, false},
    {"scripts/README.md", false, true},
    {".claude/agents/reviewer.md", false, true},
    {"docker-compose.yml", false, true}
  ]

  # --- layer 1: extract + compile --------------------------------------------------------

  defp regex_source do
    lines =
      @rules_sh
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&Regex.match?(~r/^\s*BACKEND_PATHS_RE=/, &1))

    assert [line] = lines,
           "#{@rules_sh} must contain exactly ONE `BACKEND_PATHS_RE=` assignment line " <>
             "(found #{length(lines)}); the guard test parses that line."

    assert [_, src] = Regex.run(~r/^\s*BACKEND_PATHS_RE='([^']+)'\s*$/, line),
           "BACKEND_PATHS_RE in #{@rules_sh} must be a single-quoted value alone on its line: " <>
             "BACKEND_PATHS_RE='^(...)'  -- got: #{line}"

    src
  end

  defp compile!(src), do: Regex.compile!(src)

  # --- layer 3 helpers: the scan ---------------------------------------------------------

  defp tracked_files do
    {out, 0} = System.cmd("git", ["ls-files", "-z"])
    out |> String.split("\0", trim: true) |> Enum.sort()
  end

  defp scan_sources do
    (Path.wildcard("test/**/*.exs") ++
       Path.wildcard("test/support/**/*") ++
       Path.wildcard("lib/mix/tasks/*.ex") ++
       ["mix.exs"])
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(&1 == "test/letflow/ci_backend_path_filter_test.exs"))
    |> Enum.uniq()
  end

  @path_literal Regex.compile!(
                  "^(?:(?:" <>
                    Enum.join(Enum.map(@root_dirs, &Regex.escape/1), "|") <>
                    ")/[^\\s\"]*|" <>
                    Enum.join(Enum.map(@root_files, &Regex.escape/1), "|") <> ")$"
                )

  # [{literal, source_file}] for every double-quoted single-line literal that looks like a
  # path under the roots. Interpolation becomes a `*` wildcard.
  defp path_literals do
    for src <- scan_sources(),
        [_, lit] <- Regex.scan(~r/"((?:[^"\\\n]|\\.)*)"/, File.read!(src)),
        # `Path.expand("../../../docs/roles.md", __DIR__)` style: drop the leading `../`.
        lit = lit |> String.replace(~r/^(?:\.\.\/)+/, ""),
        lit = Regex.replace(~r/#\{[^}]*\}/, lit, "*"),
        Regex.match?(@path_literal, lit),
        do: {lit, src}
  end

  defp implicit_literals,
    do: Enum.map(@implicit_reads, &{&1, "mix.exs alias step \"format --check-formatted\""})

  # Tracked files a literal resolves to: exact file, directory contents, or (for a partial
  # name) files sharing the prefix; a literal with `*` is a whole-path glob.
  defp resolve(lit, tracked) do
    if String.contains?(lit, "*") do
      re =
        lit
        |> Regex.escape()
        |> String.replace("\\*\\*", ".*")
        |> String.replace("\\*", "[^/]*")
        |> then(&Regex.compile!("^" <> &1 <> "$"))

      Enum.filter(tracked, &Regex.match?(re, &1))
    else
      dir = String.trim_trailing(lit, "/")

      Enum.filter(tracked, fn f ->
        f == lit or String.starts_with?(f, dir <> "/") or String.starts_with?(f, lit)
      end)
    end
  end

  # How a literal is checked:
  #   * exact tracked file or `*` glob  -> EVERY resolved file must match the filter
  #     (the literal names precisely what is read);
  #   * directory or partial-name prefix -> AT LEAST ONE resolved file must match the filter.
  #     A directory is listed and filtered by the reader (e.g. `docs/issues` -> `*.yaml`
  #     only), so most of its files are not inputs; but a directory the filter does not
  #     reach at all is a gap.
  defp strictness(lit, tracked) do
    if String.contains?(lit, "*") or lit in tracked, do: :every, else: :any
  end

  # [{subject, [literal sources]}]: subject is a file (strict) or a directory literal
  # (lenient) that the regex does not cover and that is not allowlisted.
  defp violations(re) do
    tracked = tracked_files()

    (path_literals() ++ implicit_literals())
    |> Enum.flat_map(fn {lit, src} ->
      files = resolve(lit, tracked)
      who = "#{src}: \"#{lit}\""

      cond do
        files == [] ->
          []

        strictness(lit, tracked) == :every ->
          for f <- files, not Regex.match?(re, f), do: {f, who}

        Enum.any?(files, &Regex.match?(re, &1)) ->
          []

        true ->
          [{lit, who}]
      end
    end)
    |> Enum.reject(fn {subject, _} -> Map.has_key?(@not_read_allowlist, subject) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {s, who} -> {s, who |> Enum.uniq() |> Enum.sort()} end)
    |> Enum.sort()
  end

  defp table_violations(re) do
    for {path, expected, _exists} <- @decision_table,
        Regex.match?(re, path) != expected,
        do: {path, expected}
  end

  defp format_violations(vs) do
    Enum.map_join(vs, "\n", fn {f, who} ->
      "  #{f}\n      read via: #{Enum.take(who, 3) |> Enum.join("; ")}"
    end)
  end

  # Returns the regex source with the single alternative `alt` removed (must be present).
  defp drop_alternative(src, alt) do
    assert String.contains?(src, alt <> "|"),
           "mutation precondition: alternative #{inspect(alt)} not found followed by `|` in the filter"

    String.replace(src, alt <> "|", "", global: false)
  end

  # --- tests -----------------------------------------------------------------------------

  describe "layer 1: the filter in scripts/ci_changed_paths.sh" do
    test "is one single-quoted assignment line and compiles as a regex" do
      src = regex_source()
      assert String.starts_with?(src, "^(") and String.ends_with?(src, ")")
      assert %Regex{} = compile!(src)
    end

    test "uses only constructs shared by POSIX ERE (grep -E) and PCRE" do
      src = regex_source()

      # No PCRE-only escapes (\\d \\w \\s \\b), lookarounds, lazy/possessive quantifiers or
      # non-capturing groups: grep -E would read those differently or reject them.
      refute Regex.match?(~r/\\[dDwWsSbB]/, src), "PCRE-only class escape in filter"
      refute src =~ "(?", "PCRE-only group/lookaround syntax in filter"
      refute Regex.match?(~r/[*+?}]\?/, src), "lazy quantifier in filter"
    end

    test "the script feeds the changed-file list to that variable via grep -qE and a here-string" do
      assert File.read!(@rules_sh) =~ ~S|grep -qE "$BACKEND_PATHS_RE" <<<"$CHANGED"|
    end

    # Q-1110 / GH #2492: `echo "$CHANGED" | grep -q` under `set -o pipefail` is SIGPIPE-unsafe on a
    # large list (grep -q exits at the first match, echo gets SIGPIPE, the pipeline is 141, the
    # `if` is false, the gate is skipped). Each of the three filters must use a here-string.
    # GH #2622: scanned in all four files of the CI/CD path and decision logic.
    test "no file pipes into grep -q (SIGPIPE under pipefail)" do
      offenders =
        for {file, _} <- @here_string_files,
            {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            not String.starts_with?(String.trim_leading(line), "#"),
            Regex.match?(~r/\|\s*grep\s[^\n]*(\s-[A-Za-z]*q|--quiet|--silent)/, line),
            do: {file, n, line}

      assert offenders == [],
             "pipe into `grep -q` found (use `grep -qE <re> <<<\"$CHANGED\"`): #{inspect(offenders)}"
    end

    test "the three path filters use a here-string, all in the script and nowhere else" do
      counts =
        Map.new(@here_string_files, fn {file, _} ->
          {file, length(Regex.scan(~r/grep -qE [^\n]*<<<"\$CHANGED"/, File.read!(file)))}
        end)

      assert counts == @here_string_files
    end

    test "the here-string form matches on a 20k-line list (control; the piped form is unsafe)" do
      script = """
      set -uo pipefail
      C=$( { echo lib/a.ex; i=0; while [ $i -lt 20000 ]; do echo "docs/generated/some/long/path/segment/file-$i.md"; i=$((i+1)); done; } )
      for n in 1 2 3 4 5; do
        if grep -qE '^(lib/)' <<<"$C"; then printf t; else printf f; fi
      done
      """

      case System.find_executable("bash") do
        nil ->
          :ok

        bash ->
          {out, 0} = System.cmd(bash, ["-c", script])
          assert out == "ttttt"
      end
    end
  end

  describe "layer 2: decision table" do
    test "every row classifies as expected" do
      re = compile!(regex_source())
      assert [] = table_violations(re)
    end

    test "table is not vacuous and has both polarities" do
      assert length(@decision_table) >= 40
      assert Enum.count(@decision_table, &elem(&1, 1)) >= 25
      assert Enum.count(@decision_table, &(not elem(&1, 1))) >= 8
    end

    test "rows marked as tracked files exist, so the table cannot rot" do
      tracked = MapSet.new(tracked_files())

      missing =
        for {path, _expected, true} <- @decision_table,
            not MapSet.member?(tracked, path),
            do: path

      assert missing == [], "decision-table paths no longer tracked: #{inspect(missing)}"
    end
  end

  describe "layer 3: every path the gate reads is covered" do
    test "scan is not vacuous" do
      lits = path_literals()
      tracked = tracked_files()

      resolved =
        lits
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.filter(&(resolve(&1, tracked) != []))

      assert length(lits) >= 80, "scan found only #{length(lits)} path literals"
      assert length(resolved) >= 40, "only #{length(resolved)} literals resolve to tracked files"

      roots_seen =
        resolved
        |> Enum.map(&(&1 |> String.split("/") |> hd()))
        |> Enum.uniq()

      for r <- ~w(docs handoffs priv web), do: assert(r in roots_seen, "no literal under #{r}/")
    end

    test "every tracked path named by a gate-read literal matches the filter or is allowlisted" do
      re = compile!(regex_source())

      vs = violations(re)

      assert vs == [],
             "paths the backend gate reads are missing from BACKEND_PATHS_RE in #{@rules_sh} " <>
               "(a change confined to them would skip the backend job). Add them to the " <>
               "filter, or -- only if they are not read as input -- to @not_read_allowlist " <>
               "with a reason:\n" <> format_violations(vs)
    end

    test "implicit reads are real: the command that reads them is still declared" do
      assert File.read!("mix.exs") =~ ~S|"format --check-formatted"|
      tracked = tracked_files()
      for f <- @implicit_reads, do: assert(f in tracked, "#{f} is not tracked")
    end

    test "allowlist entries are all still needed and still exist" do
      re = compile!(regex_source())
      tracked = tracked_files()
      literals = path_literals() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      for {entry, reason} <- @not_read_allowlist do
        assert is_binary(reason) and reason != ""
        assert entry in tracked, "allowlist entry #{entry} is not a tracked file"

        assert MapSet.member?(literals, entry),
               "allowlist entry #{entry} is no longer a string literal in any scanned source"

        refute Regex.match?(re, entry),
               "allowlist entry #{entry} now matches the filter; remove it"
      end
    end
  end

  describe "in-memory mutations: the guard detects a gap" do
    test "dropping the .formatter.exs alternative is reported by table and scan" do
      src = regex_source() |> drop_alternative(~S{\.formatter\.exs$})
      re = compile!(src)

      assert {".formatter.exs", true} in table_violations(re)
      assert ".formatter.exs" in Enum.map(violations(re), &elem(&1, 0))
    end

    test "dropping the docs/roles.md alternative is reported by table and scan" do
      src = regex_source() |> drop_alternative(~S{docs/roles\.md$})
      re = compile!(src)

      assert {"docs/roles.md", true} in table_violations(re)
      assert "docs/roles.md" in Enum.map(violations(re), &elem(&1, 0))
    end

    test "dropping the handoffs/registry.json alternative is reported" do
      src = regex_source() |> drop_alternative(~S{handoffs/registry\.json$})
      re = compile!(src)

      assert {"handoffs/registry.json", true} in table_violations(re)
    end

    test "dropping the docs/requirements.yaml alternative is reported" do
      src = regex_source() |> drop_alternative(~S{docs/requirements\.yaml$})
      re = compile!(src)

      assert {"docs/requirements.yaml", true} in table_violations(re)
      assert "docs/requirements.yaml" in Enum.map(violations(re), &elem(&1, 0))
    end

    test "the unmutated filter reports nothing (control for the mutation tests)" do
      re = compile!(regex_source())
      assert table_violations(re) == []
      assert violations(re) == []
    end
  end
end
