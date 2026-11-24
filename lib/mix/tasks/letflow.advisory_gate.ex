defmodule Mix.Tasks.Letflow.AdvisoryGate do
  @moduledoc """
  G-12: the PR-blocking dependency advisory gate and the SAST scan of the Elixir tree.

  Gap **G-12** of the team repository's `docs/security-coverage.md` §4:

  > PR-blocking dependency advisory gate plus Sobelow (or justified equivalent) and a real
  > Dart advisory source.

  The coverage map found the dependency audit **report-only**: `.github/workflows/dependency-audit.yml`
  runs `mix hex.audit` and `npm audit` weekly, every step `continue-on-error`, with no
  `pull_request` trigger. `flutter pub outdated` is version freshness, not an advisory check, and
  no SAST scanner was configured at all.

  This task is the gate. It has two halves that share one decision function:

  * the **advisory half** reads the three real advisory sources (Hex via `mix hex.audit --format
    sarif`, npm via `npm audit --omit=dev`, Dart via the OSV `Pub` ecosystem), keeps the advisories
    that hit a **production** dependency at **medium** severity or above, and fails unless every one
    of them is covered by an entry of `priv/security/advisory-allow.json` that has not expired;
  * the **SAST half** scans `lib/` and the migrations with the rules of `sast_findings/1` and fails
    on a finding that `priv/security/sast-allow.json` does not accept.

  Every source is read through a function that can be replaced by a recorded answer
  (`collect_hex/3`, `collect_npm/3`, `collect_pub/3`), so the probe can drive the SOURCE with the
  answer the real tool produced, and not only the decision that reads its result.

  The two lists are the same shape on purpose: `id`, `package`, `reason`, `owner`, `expires`. An
  expired entry fails the gate (an exception must be re-reviewed, not inherited); an entry for an
  advisory that no longer exists is reported (a stale entry is noise, not a hole).

  ## Why the SAST half is not Sobelow

  Sobelow is a Hex dependency, and this repository's dependencies are pinned in `mix.lock`: adding
  one changes the lock of **every** worktree, while the operator's setup step only fetches
  dependencies when `deps/` is missing (`project/scripts/lf.sh`, `setup`). A tree whose `deps/`
  already exists would fail to compile with "sobelow is not available" until someone re-ran
  `mix deps.get` by hand — a landmine under every other task in flight.

  So the SAST half is the **justified equivalent** the gap list allows: the same rule classes
  Sobelow covers for an Elixir/OTP tree, implemented as AST rules over this repository's own
  source. `docs/security-probes/G-12.md` carries the parity table: which Sobelow check each rule
  replaces, and which Sobelow checks do not apply to this codebase (Erlang, WASM and Lua runtime
  internals, Phoenix-specific rules, GitHub Actions rules).

  The id of a SAST finding is the rule, the file and a **hash of the offending call**, never the
  line number: an id that carries the line moves whenever anything is inserted above the site,
  and an accepted site that changed its line would become a new finding and block every pull
  request that touches the file for an unrelated reason. A change OF the call is a new site (it
  has to be read again); a change AROUND it is not.

  ## What is NOT here

  The gate reads the advisories of the **locked** versions only, and it never changes a
  dependency. A finding is a finding: the gate reports it and fails; the fix is a version bump or
  a dated allow-list entry, decided by a human.

  ## Usage

      mix letflow.advisory_gate                     # the live gate (network)
      mix letflow.advisory_gate --feed FILE         # the same decision on a recorded feed
      mix letflow.advisory_gate --sast-only         # the SAST half only (no network)
      mix letflow.advisory_gate --severity high     # a stricter threshold
      mix letflow.advisory_gate --allow-list FILE   # another allow-list

  Exit code 0 = pass, 1 = fail (a blocking finding, an expired entry, or a collector that could
  not be read — the gate fails closed), 2 = a usage error.
  """

  use Mix.Task

  @shortdoc "Fails on a medium+ advisory in a production dependency"

  @default_allow_list "priv/security/advisory-allow.json"
  @default_sast_allow_list "priv/security/sast-allow.json"
  @default_severity "medium"

  # The severity order the policy compares on. npm spells the middle band "moderate", OSV and
  # GitHub spell it "medium"; both map to the same rank.
  @severity_rank %{"low" => 1, "medium" => 2, "moderate" => 2, "high" => 3, "critical" => 4}

  @shells ~w(sh bash zsh dash ksh cmd cmd.exe powershell powershell.exe pwsh)

  # ── the Mix task ───────────────────────────────────────────────────────────────

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          feed: :string,
          allow_list: :string,
          sast_allow_list: :string,
          severity: :string,
          root: :string,
          sast_only: :boolean,
          json: :boolean
        ]
      )

    root = opts[:root] || File.cwd!()
    threshold = opts[:severity] || @default_severity
    allow_path = opts[:allow_list] || Path.join(root, @default_allow_list)
    sast_allow_path = opts[:sast_allow_list] || Path.join(root, @default_sast_allow_list)

    if opts[:sast_only] do
      allow = read_allow_list!(sast_allow_path)
      sast = evaluate_sast(sast_findings(root), allow)
      report_sast(sast, opts[:json] == true)

      if sast.status == :fail do
        Mix.raise("advisory gate: the SAST scan found a blocking finding (see the report above)")
      end

      :ok
    else
      allow = read_allow_list!(allow_path)
      packages = production_packages(root)

      advisories =
        case opts[:feed] do
          nil -> collect_advisories(root, packages)
          feed -> read_feed!(feed)
        end

      verdict = evaluate(advisories, allow, packages, threshold: threshold)
      report(verdict, opts[:json] == true)

      if verdict.status == :fail do
        Mix.raise(
          "advisory gate: #{length(verdict.blocking)} blocking finding(s) and " <>
            "#{length(verdict.expired)} expired allow-list entry/entries"
        )
      end

      :ok
    end
  end

  # ── the decision function (pure) ───────────────────────────────────────────────

  @doc """
  The advisory decision. Pure: no file, no network.

  The clock enters through `opts[:today]` (a `Date`; the default is `Date.utc_today()`):
  the expiry of an allow-list entry is what makes an un-re-reviewed exception visible, and
  a decision that cannot be replayed cannot be tested.

  `advisories` is a list of maps with the keys `:id`, `:aliases`, `:ecosystem` (`:hex`,
  `:npm` or `:pub`), `:package`, `:version`, `:severity` and `:title`. `allow_entries` is the
  list the allow-list file carries. `packages` is the production inventory from
  `production_packages/1`.

  Returns a map with `:status` (`:pass` or `:fail`), the `:blocking` findings, the `:accepted`
  findings (covered by a live allow-list entry), the `:expired` entries, the `:stale` entries
  (an accepted advisory that no longer exists) and the `:informational` rows (below the threshold
  or outside the production inventory).
  """
  def evaluate(advisories, allow_entries, packages, opts \\ []) do
    threshold = opts[:threshold] || opts[:severity] || @default_severity
    threshold_rank = Map.get(@severity_rank, String.downcase(to_string(threshold)), 2)
    today = opts[:today] || Date.utc_today()

    {blocking, accepted, informational} =
      Enum.reduce(advisories, {[], [], []}, fn advisory, {b, a, i} ->
        cond do
          not in_production?(advisory, packages) ->
            {b, a, [{:out_of_production, advisory} | i]}

          severity_rank(advisory) < threshold_rank ->
            {b, a, [{:below_threshold, advisory} | i]}

          true ->
            case live_entry(allow_entries, advisory, today) do
              {:ok, entry} -> {b, [{advisory, entry} | a], i}
              :expired -> {[{advisory, :expired} | b], a, i}
              :none -> {[{advisory, :not_accepted} | b], a, i}
            end
        end
      end)

    # An expired entry fails the gate even when the advisory it accepted is gone: an exception
    # that nobody re-reviewed must not sit in the tree forever.
    expired =
      allow_entries
      |> Enum.filter(&expired?(&1, today))
      |> Enum.map(&{&1, :expired})

    stale =
      allow_entries
      |> Enum.reject(&expired?(&1, today))
      |> Enum.filter(fn entry -> not Enum.any?(advisories, &entry_covers?(entry, &1)) end)
      |> Enum.map(&{&1, :stale})

    status = if blocking == [] and expired == [], do: :pass, else: :fail

    %{
      status: status,
      threshold: threshold,
      blocking: Enum.reverse(blocking),
      accepted: Enum.reverse(accepted),
      expired: expired,
      stale: stale,
      informational: Enum.reverse(informational)
    }
  end

  @doc """
  The production dependency inventory: `%{hex: %{name => version}, npm: ..., pub: ...}`.

  A dependency is **production** when it is reachable from a direct dependency that is not
  restricted to `:dev`/`:test` in `mix.exs`, when npm does not mark it `dev` in the lock file, or
  when pub does not mark it `direct dev`. The inventory is what makes the gate a gate: an
  advisory on a test-only dependency is not a production finding.
  """
  def production_packages(root) do
    %{
      hex: hex_packages(root),
      npm: npm_packages(root),
      pub: pub_packages(root)
    }
  end

  @doc """
  The allow-list entries of a file. Raises when the file is missing or malformed: a gate that
  cannot read its own exceptions fails closed.
  """
  def read_allow_list!(path) do
    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"entries" => entries}} when is_list(entries) ->
            Enum.map(entries, &normalise_entry!/1)

          {:ok, _other} ->
            raise ArgumentError, "#{path}: an allow-list file has an \"entries\" list"

          {:error, reason} ->
            raise ArgumentError, "#{path}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise ArgumentError, "#{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Reads a recorded advisory feed (the JSON the collectors write, and the seeded fixture the
  probe drives the gate with).
  """
  def read_feed!(path) do
    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"advisories" => advisories}} when is_list(advisories) ->
            Enum.map(advisories, &normalise_advisory!/1)

          {:ok, _other} ->
            raise ArgumentError, "#{path}: a feed file has an \"advisories\" list"

          {:error, reason} ->
            raise ArgumentError, "#{path}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise ArgumentError, "#{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Collects the advisories of the three real sources. Network: hex.pm, the npm registry and
  osv.dev. A source that cannot be read raises: the gate fails closed rather than passes a
  tree it could not audit.

  `opts` may replace a source with a recorded answer (`:hex_audit`, `:npm_audit`,
  `:http`); see the collectors.
  """
  def collect_advisories(root, packages, opts \\ []) do
    Enum.concat([
      collect_hex(root, packages, opts),
      collect_npm(root, packages, opts),
      collect_pub(root, packages, opts)
    ])
  end

  # ── the SAST half ──────────────────────────────────────────────────────────────

  @doc """
  The SAST rules over the Elixir tree. The rules are the Sobelow checks that apply to this
  codebase (the parity table is in `docs/security-probes/G-12.md`).

  The scan covers the library (`lib/**/*.ex`) AND the migrations
  (`priv/repo/migrations/**/*.exs`): INV-7 names "every migration and any hand-written
  analytics query" next to the queries of the library, and a migration that interpolates
  a value is the same finding as a library module that does.

  The file of a finding is relative to the scanned ROOT, never to the working directory: a
  scan of the same tree must produce the same findings from any working directory.

  Returns a list of findings: `%{id:, rule:, file:, line:, detail:}`.
  """
  def sast_findings(root) do
    root = Path.expand(root)

    findings =
      [Path.join(root, "lib/**/*.ex"), Path.join(root, "priv/repo/migrations/**/*.exs")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(&scan_file(&1, root))
      |> Enum.sort_by(&{&1.file, &1.line, &1.rule})

    number_identical(findings)
  end

  # Two sites with the SAME call text in one file would share one id, and a third site with
  # that text would then be accepted by the entry of the first two without being read. The
  # ordinal of the identical call inside the file tells them apart: the first carries the bare
  # id, the second ":2", the third ":3".
  defp number_identical(findings) do
    {_, numbered} =
      Enum.reduce(findings, {%{}, []}, fn finding, {counts, acc} ->
        count = Map.get(counts, finding.id, 0) + 1
        id = if count == 1, do: finding.id, else: "#{finding.id}:#{count}"

        {Map.put(counts, finding.id, count), [%{finding | id: id} | acc]}
      end)

    Enum.reverse(numbered)
  end

  @doc """
  The SAST decision. Pure: findings, allow-list entries and the threshold-free "accepted" set.
  An expired entry fails the gate; an entry for a finding that no longer exists is reported.
  """
  def evaluate_sast(findings, allow_entries, opts \\ []) do
    today = opts[:today] || Date.utc_today()

    {blocking, accepted} =
      Enum.reduce(findings, {[], []}, fn finding, {b, a} ->
        case live_entry(allow_entries, finding, today) do
          {:ok, entry} -> {b, [{finding, entry} | a]}
          :expired -> {[{finding, :expired} | b], a}
          :none -> {[{finding, :not_accepted} | b], a}
        end
      end)

    expired =
      allow_entries
      |> Enum.filter(&expired?(&1, today))
      |> Enum.map(&{&1, :expired})

    stale =
      allow_entries
      |> Enum.reject(&expired?(&1, today))
      |> Enum.filter(fn entry -> not Enum.any?(findings, &entry_covers?(entry, &1)) end)
      |> Enum.map(&{&1, :stale})

    status = if blocking == [] and expired == [], do: :pass, else: :fail

    %{
      status: status,
      blocking: Enum.reverse(blocking),
      accepted: Enum.reverse(accepted),
      expired: expired,
      stale: stale
    }
  end

  # ── the report ─────────────────────────────────────────────────────────────────

  defp report(verdict, json?) do
    if json? do
      IO.puts(Jason.encode!(%{status: to_string(verdict.status), verdict: json_safe(verdict)}))
    else
      IO.puts(
        "advisory gate: #{String.upcase(to_string(verdict.status))} (threshold #{verdict.threshold})"
      )

      for {advisory, why} <- verdict.blocking do
        IO.puts(
          "  BLOCKING #{advisory.ecosystem}/#{advisory.package} #{advisory.version} " <>
            "#{advisory.id} severity=#{advisory.severity} (#{why})"
        )
      end

      for {advisory, entry} <- verdict.accepted do
        IO.puts(
          "  accepted #{advisory.ecosystem}/#{advisory.package} #{advisory.id} (#{entry.reason})"
        )
      end

      for {entry, _why} <- verdict.expired do
        IO.puts("  EXPIRED allow-list entry #{entry.id} (expired #{entry.expires})")
      end

      for {entry, _why} <- verdict.stale do
        IO.puts("  stale allow-list entry #{entry.id} (no such advisory any more)")
      end

      for {kind, advisory} <- verdict.informational do
        IO.puts("  #{kind} #{advisory.ecosystem}/#{advisory.package} #{advisory.id}")
      end
    end
  end

  defp report_sast(verdict, json?) do
    if json? do
      IO.puts(Jason.encode!(%{status: to_string(verdict.status), sast: json_safe(verdict)}))
    else
      IO.puts("sast scan: #{String.upcase(to_string(verdict.status))}")

      for {finding, why} <- verdict.blocking do
        IO.puts("  BLOCKING #{finding.rule} #{finding.file}:#{finding.line} (#{why})")
      end

      for {finding, entry} <- verdict.accepted do
        IO.puts("  accepted #{finding.rule} #{finding.file}:#{finding.line} (#{entry.reason})")
      end

      for {entry, _why} <- verdict.expired do
        IO.puts("  EXPIRED allow-list entry #{entry.id} (expired #{entry.expires})")
      end

      for {entry, _why} <- verdict.stale do
        IO.puts("  stale allow-list entry #{entry.id} (no such finding any more)")
      end
    end
  end

  defp json_safe(map) do
    Map.new(map, fn {k, v} ->
      {k, json_safe_value(v)}
    end)
  end

  defp json_safe_value(value) when is_list(value) do
    Enum.map(value, fn
      {a, b} -> [json_safe_value(a), json_safe_value(b)]
      other -> json_safe_value(other)
    end)
  end

  defp json_safe_value(value) when is_map(value), do: json_safe(value)
  defp json_safe_value(value) when is_atom(value), do: to_string(value)
  defp json_safe_value(value), do: value

  # ── the collectors ─────────────────────────────────────────────────────────────
  #
  # Every collector takes its SOURCE from an injected function, so that the probe can
  # drive the source with a RECORDED answer and the source itself is tested, not only the
  # decision that reads its result:
  #
  #   * `:hex_audit` -- fn root -> {output, exit_status}   (the default runs `mix hex.audit`)
  #   * `:npm_audit` -- fn web_dir -> {output, exit_status} (the default runs `npm audit`)
  #   * `:http`      -- fn {method, url, body} -> {status, body} (the default is `query_osv/1`)
  #
  # A collector that cannot read its source RAISES: the gate fails closed rather than
  # passes a tree it could not audit.

  @doc """
  The advisories of the HEX source (`mix hex.audit --format sarif`).

  `opts[:hex_audit]` replaces the command with a recorded answer: `fn root -> {output,
  exit_status} end`.
  """
  def collect_hex(root, packages, opts \\ []) do
    case packages.hex do
      empty when empty == %{} ->
        []

      _ ->
        runner = opts[:hex_audit] || (&run_hex_audit/1)
        {out, status} = runner.(root)
        parse_hex_sarif(out, status)
    end
  end

  # `mix hex.audit` exits 0 on a clean tree and 1 when it found an advisory: the
  # non-zero exit IS the finding, so the answer is read whatever the status is. The
  # machine-readable SARIF report is asked for explicitly -- the human report is prose,
  # and a parser of prose silently finds nothing when the prose changes.
  defp run_hex_audit(root) do
    # stderr is NOT folded into stdout: the SARIF report is JSON, and one line of hex's
    # own summary in the middle of it would make the report unreadable.
    System.cmd("mix", ["hex.audit", "--format", "sarif"], cd: root)
  end

  defp parse_hex_sarif(out, status) do
    case Jason.decode(out) do
      {:ok, %{"runs" => runs}} when is_list(runs) ->
        rules = hex_rules(runs)

        runs
        |> Enum.flat_map(fn run -> hex_results(run, rules) end)

      {:ok, _other} ->
        raise "the hex advisory source answered something that is not a SARIF report"

      {:error, reason} ->
        raise "the hex advisory source could not be read (mix hex.audit exited #{status}): #{inspect(reason)}"
    end
  end

  defp hex_rules(runs) do
    rules =
      runs
      |> Enum.flat_map(fn run -> get_in(run, ["tool", "driver", "rules"]) || [] end)
      |> Enum.filter(&is_map/1)

    Map.new(rules, fn rule -> {rule["id"], rule} end)
  end

  # Only a result whose fingerprint says "advisory" is a security finding. A retired
  # package is a maintenance notice, not a vulnerability: it is never blocking.
  defp hex_results(run, rules) do
    run
    |> Map.get("results", [])
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn result -> String.starts_with?(hex_fingerprint(result), "advisory:") end)
    |> Enum.map(fn result -> hex_advisory(result, rules) end)
  end

  defp hex_fingerprint(result) do
    get_in(result, ["partialFingerprints", "hexAudit/v1"]) || ""
  end

  # The SARIF result names the advisory in three places, and every one of them is used:
  # the fingerprint ("advisory:hexpm/plug:EEF-CVE-2026-120287") names the package and the
  # id, the message arguments name the version, the aliases and the title, and the rule
  # table carries the severity.
  defp hex_advisory(result, rules) do
    fingerprint = hex_fingerprint(result)
    arguments = get_in(result, ["message", "arguments"]) || []

    {package, id} =
      case Regex.run(~r{\Aadvisory:[^/]+/([^:]+):(.+)\z}, fingerprint) do
        [_full, package, id] -> {package, id}
        _ -> {Enum.at(arguments, 0) || "", result["ruleId"] || ""}
      end

    %{
      id: id,
      aliases: hex_aliases(Enum.at(arguments, 2), id),
      ecosystem: :hex,
      package: package,
      version: Enum.at(arguments, 1) || "",
      severity: hex_severity(result, rules),
      title: Enum.at(arguments, 3) || ""
    }
  end

  # The aliases of a Hex advisory: the report names them as "EEF-CVE-2026-120287 (aka
  # CVE-2026-120287, GHSA-qj4r-jh2r-rw3f)". An allow-list entry may name the advisory by
  # any of them.
  defp hex_aliases(nil, _id), do: []

  defp hex_aliases(text, id) when is_binary(text) do
    case Regex.run(~r/\(aka\s+(.+)\)\s*\z/, text) do
      [_full, list] ->
        list
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or &1 == id))

      _ ->
        []
    end
  end

  # The severity of a Hex advisory is the CVSS score the SARIF rule carries
  # (`properties.security-severity`), mapped onto the CVSS v3 qualitative bands. A score
  # that is missing or unreadable is HIGH: the gate must not pass a finding it could not
  # classify.
  defp hex_severity(result, rules) do
    score =
      result["ruleId"]
      |> then(&Map.get(rules, &1))
      |> case do
        rule when is_map(rule) -> get_in(rule, ["properties", "security-severity"])
        _ -> nil
      end

    case score do
      score when is_binary(score) -> cvss_band(score)
      _ -> "high"
    end
  end

  defp cvss_band(score) do
    case Float.parse(score) do
      {value, _rest} when value >= 9.0 -> "critical"
      {value, _rest} when value >= 7.0 -> "high"
      {value, _rest} when value >= 4.0 -> "medium"
      {_value, _rest} -> "low"
      :error -> "high"
    end
  end

  @doc """
  The advisories of the NPM source (`npm audit --omit=dev --json`).

  `opts[:npm_audit]` replaces the command with a recorded answer: `fn web_dir -> {output,
  exit_status} end`.
  """
  def collect_npm(root, packages, opts \\ []) do
    web = Path.join(root, "web")

    if packages.npm == %{} or not File.dir?(web) do
      []
    else
      runner = opts[:npm_audit] || (&run_npm_audit/1)
      {out, status} = runner.(web)
      parse_npm_audit(out, status, packages)
    end
  end

  # `npm audit` exits 0 when the tree is clean and 1 when it found a vulnerability: the
  # non-zero exit IS the finding, so the report is read whatever the status is.
  defp run_npm_audit(web) do
    System.cmd("npm", ["audit", "--omit=dev", "--json"], cd: web)
  end

  defp parse_npm_audit(out, status, packages) do
    case Jason.decode(out) do
      {:ok, %{"vulnerabilities" => vulns}} when is_map(vulns) ->
        vulns
        |> Enum.flat_map(fn {package, vuln} -> npm_advisories(package, vuln, packages) end)

      {:ok, _other} ->
        raise "the npm advisory source answered something that is not an audit report"

      {:error, reason} ->
        raise "the npm advisory source could not be read (npm audit exited #{status}): #{inspect(reason)}"
    end
  end

  # A `via` entry that is a STRING names another package that depends on the vulnerable
  # one; only the map entries are advisories of their own.
  defp npm_advisories(package, vuln, packages) do
    vias = if is_map(vuln), do: vuln["via"] || [], else: []
    version = Map.get(Map.get(packages, :npm, %{}), package, "")

    vias
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn via ->
      %{
        id: npm_advisory_id(via, package),
        aliases: [],
        ecosystem: :npm,
        package: package,
        version: version,
        severity: normalise_band(via["severity"] || (is_map(vuln) && vuln["severity"])),
        title: via["title"] || ""
      }
    end)
  end

  # The id of an npm advisory is the GHSA id its URL carries. npm also prints a numeric
  # `source`, which is a database row number and NOT an id: an allow-list entry that names
  # it can never be written by a human, and the report would print a number the operator
  # cannot look up.
  defp npm_advisory_id(via, package) do
    url = via["url"] || ""

    case Regex.run(~r{/(GHSA-[0-9a-zA-Z\-]+)}, url) do
      [_full, id] -> id
      _ -> to_string(via["source"] || "#{package}:#{via["title"]}")
    end
  end

  # Dart has no `pub audit`; the real advisory source for the Pub ecosystem is OSV
  # (osv.dev), which the Dart team and the GitHub Advisory Database both publish into.
  @doc """
  The advisories of the DART source (the OSV `Pub` ecosystem).

  `opts[:http]` replaces the outbound request with a recorded answer: `fn {method, url,
  body} -> {status, body} end`.
  """
  def collect_pub(_root, packages, opts \\ []) do
    case packages.pub do
      empty when empty == %{} ->
        []

      _ ->
        http = opts[:http] || (&query_osv/1)

        # ONE sorted list feeds both the queries and the zip below: a map of more than 32
        # keys does not iterate in sorted order, so zipping the answers with the map
        # would attribute each advisory to the wrong package.
        sorted_pub = Enum.sort(packages.pub)

        queries =
          sorted_pub
          |> Enum.map(fn {package, version} ->
            %{
              package: %{"name" => package, "ecosystem" => "Pub"},
              version: version
            }
          end)

        {status, body} =
          http.(
            {:post, ~c"https://api.osv.dev/v1/querybatch", Jason.encode!(%{queries: queries})}
          )

        if status != 200 do
          raise "the OSV advisory source answered #{status}"
        end

        sorted_pub
        |> Enum.zip(osv_results(body))
        |> Enum.flat_map(fn {{package, version}, result} ->
          pub_advisories(package, version, result, http)
        end)
    end
  end

  defp osv_results(body) do
    case Jason.decode(body) do
      {:ok, %{"results" => results}} when is_list(results) ->
        results

      {:ok, _other} ->
        raise "the OSV advisory source answered something that is not a batch answer"

      {:error, reason} ->
        raise "the OSV advisory source could not be read: #{inspect(reason)}"
    end
  end

  # OSV answers an EMPTY MAP for a package that has no advisory: the result is not
  # missing, it is an answer. A parser that expects "vulns" in every result crashes on
  # the answer of a clean tree -- which is most trees, most of the time.
  defp pub_advisories(package, version, result, http) do
    vulns =
      case result do
        %{"vulns" => vulns} when is_list(vulns) -> vulns
        _ -> []
      end

    Enum.map(vulns, fn vuln ->
      id = vuln["id"] || ""
      detail = osv_detail(http, package, version, id)

      %{
        id: id,
        aliases: detail["aliases"] || [],
        ecosystem: :pub,
        package: package,
        version: version,
        severity: osv_severity(detail),
        title: detail["summary"] || ""
      }
    end)
  end

  # The batch answer carries the id of an advisory and nothing else: the severity and the
  # summary live in the full record, which OSV answers for the package and the version.
  # A detail answer that cannot be read leaves the severity at its fail-closed value: the
  # advisory exists, so it blocks; the operator reads its id in the report.
  defp osv_detail(http, package, version, id) do
    body =
      Jason.encode!(%{
        package: %{"name" => package, "ecosystem" => "Pub"},
        version: version
      })

    case http.({:post, ~c"https://api.osv.dev/v1/query", body}) do
      {200, detail} ->
        case Jason.decode(detail) do
          {:ok, %{"vulns" => vulns}} when is_list(vulns) ->
            Enum.find(vulns, %{}, fn vuln -> is_map(vuln) and vuln["id"] == id end)

          _ ->
            %{}
        end

      _other ->
        %{}
    end
  end

  # The ONE outbound request of the gate. The G-06 probe pins this file and this function
  # name as the platform's eighth outbound call site: the URL is the fixed service of the
  # platform operator (`:platform_config`), redirects are not followed, and the answer is
  # read as a binary.
  defp query_osv({method, url, body}) do
    request = {url, [{~c"content-type", ~c"application/json"}], ~c"application/json", body}

    http_options = [
      {:timeout, 30_000},
      {:connect_timeout, 10_000},
      {:autoredirect, false}
    ]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _phrase}, _headers, resp_body}} when is_binary(resp_body) ->
        {status, resp_body}

      {:ok, {{_version, status, _phrase}, _headers, _resp_body}} ->
        {status, ""}

      {:error, reason} ->
        raise "the OSV advisory source could not be read: #{inspect(reason)}"
    end
  end

  defp osv_severity(vuln) do
    case get_in(vuln, ["database_specific", "severity"]) do
      severity when is_binary(severity) -> normalise_band(severity)
      _ -> "high"
    end
  end

  # The severity bands of the three sources, in one place: npm spells the middle band
  # "moderate", OSV and GitHub spell it "medium"; both map to the same rank.
  defp normalise_band(severity) when is_binary(severity) do
    case String.downcase(severity) do
      "critical" -> "critical"
      "high" -> "high"
      "medium" -> "medium"
      "moderate" -> "medium"
      "low" -> "low"
      "none" -> "low"
      other -> other
    end
  end

  defp normalise_band(_severity), do: "high"

  # ── the inventories ────────────────────────────────────────────────────────────

  defp hex_packages(root) do
    lock_path = Path.join(root, "mix.lock")

    case Mix.Dep.Lock.read(lock_path) do
      lock when is_map(lock) and map_size(lock) > 0 ->
        lock = Map.new(lock, fn {name, tuple} -> {to_string(name), tuple} end)
        {_dev_only, prod_roots} = direct_deps(Path.join(root, "mix.exs"))

        prod_roots
        |> collect_closure(lock, MapSet.new())
        |> Map.new(fn name ->
          {:hex, _n, version, _inner, _managers, _deps, _repo, _outer} = lock[name]
          {name, version}
        end)

      _ ->
        %{}
    end
  end

  defp collect_closure(names, lock, seen) do
    Enum.reduce(names, seen, fn name, acc ->
      cond do
        MapSet.member?(acc, name) ->
          acc

        # A dependency the lock file does not pin (an optional one that was not fetched) is not
        # part of the tree.
        not Map.has_key?(lock, name) ->
          acc

        true ->
          acc = MapSet.put(acc, name)

          case lock[name] do
            {:hex, _n, _v, _inner, _m, deps, _r, _outer} when is_list(deps) ->
              dep_names = Enum.map(deps, fn {dep, _req, _opts} -> to_string(dep) end)
              collect_closure(dep_names, lock, acc)

            _ ->
              acc
          end
      end
    end)
  end

  # The direct dependencies of mix.exs, split into the production roots and the ones that only
  # exist for development (`only: :dev` / `only: :test`): an advisory on a test-only dependency
  # is not a production finding, so the `only:` option of mix.exs is the authority.
  defp direct_deps(path) do
    case File.read(path) do
      {:ok, text} ->
        Regex.scan(~r/\{:(\w+),\s*"[^"]*"(?:,\s*only:\s*(:\w+|\[[^\]]*\]))?/s, text)
        |> Enum.reduce({MapSet.new(), []}, fn match, {dev_only, prod} ->
          [_full, name | rest] = match
          only = List.first(rest) || ""

          if dev_only?(only) do
            {MapSet.put(dev_only, name), prod}
          else
            {dev_only, [name | prod]}
          end
        end)
        |> then(fn {dev_only, prod} -> {dev_only, Enum.reverse(prod)} end)

      {:error, _reason} ->
        {MapSet.new(), []}
    end
  end

  defp dev_only?(only), do: String.contains?(only, ":dev") or String.contains?(only, ":test")

  defp npm_packages(root) do
    path = Path.join(root, "web/package-lock.json")

    case File.read(path) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"packages" => packages}} when is_map(packages) ->
            packages
            |> Enum.filter(fn {key, value} ->
              key != "" and is_map(value) and value["dev"] != true
            end)
            |> Map.new(fn {key, value} ->
              name = key |> String.split("node_modules/") |> List.last()
              {name, value["version"] || ""}
            end)

          _ ->
            %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  defp pub_packages(root) do
    path = Path.join(root, "apps/mobile/pubspec.lock")

    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.reduce({%{}, nil, nil}, fn line, {acc, name, dev?} ->
          cond do
            String.starts_with?(line, "  ") and not String.starts_with?(line, "   ") and
                String.ends_with?(line, ":") ->
              # The name is the indented key of the lock file: the indentation is stripped, or
              # the inventory key would be "  http" and no advisory could ever match it.
              {acc, line |> String.trim() |> String.trim_trailing(":"), nil}

            String.starts_with?(line, "    dependency:") ->
              {acc, name, String.contains?(line, "dev")}

            String.starts_with?(line, "    version:") ->
              version =
                line
                |> String.split(":", parts: 2)
                |> List.last()
                |> String.trim()
                |> String.trim("\"")

              acc = if dev? == true, do: acc, else: Map.put(acc, name || "", version)
              {acc, name, dev?}

            true ->
              {acc, name, dev?}
          end
        end)
        |> elem(0)

      {:error, _reason} ->
        %{}
    end
  end

  # ── the SAST rules ─────────────────────────────────────────────────────────────

  defp scan_file(path, root) do
    relative = Path.relative_to(path, root)

    case File.read(path) do
      {:ok, text} ->
        case Code.string_to_quoted(text, columns: true) do
          {:ok, ast} ->
            ast
            |> collect_calls()
            |> Enum.flat_map(&rule_finding(relative, &1))

          {:error, _reason} ->
            []
        end

      {:error, _reason} ->
        []
    end
  end

  # Every call of the form `Module.function(args)` in the tree. The module of a call is an
  # alias node (`{:__aliases__, _, [:String]}`), not an atom, so it is resolved to its dotted
  # name here: a rule that only knew atoms would never see `String.to_atom/1`.
  #
  # The call node itself travels with the call: the id of a finding is derived from it, and a
  # rule that only knew the module and the arguments could not tell two sites apart.
  defp collect_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          {{:., _, [module, function]}, meta, args} when is_atom(function) and is_list(args) ->
            case module_name(module) do
              nil -> {node, acc}
              name -> {node, [{name, function, args, meta[:line] || 0, node} | acc]}
            end

          _ ->
            {node, acc}
        end
      end)

    calls
  end

  defp module_name({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &(is_atom(&1) or is_binary(&1))) do
      Enum.map_join(parts, ".", &to_string/1)
    else
      nil
    end
  end

  defp module_name(module) when is_atom(module), do: Atom.to_string(module)
  defp module_name(_module), do: nil

  # The module of a call is matched on its LAST name part, because a file that writes
  # `alias Letflow.Repo` calls `Repo.query!/2` and the alias node is `Letflow.Repo`.
  defp rule_finding(file, {module, function, args, line, node}) do
    short = module |> String.split(".") |> List.last()

    cond do
      short in ["String", "List"] and function == :to_atom ->
        atom_finding(file, line, args, node)

      short == "erlang" and function == :binary_to_atom ->
        atom_finding(file, line, args, node)

      short == "erlang" and function == :binary_to_term ->
        deserialization_finding(file, line, args, node)

      short == "System" and function == :shell ->
        command_finding(file, line, args, node)

      short == "System" and function == :cmd ->
        system_cmd_finding(file, line, args, node)

      short == "Repo" and function in [:query, :query!] ->
        sql_finding(file, line, args, node)

      # SQL.query(repo, sql, params): the SQL string is the SECOND argument.
      (module == "Ecto.Adapters.SQL" or short == "SQL") and function in [:query, :query!] ->
        sql_finding(file, line, Enum.drop(args, 1), node)

      short == "crypto" and function == :hash ->
        weak_hash_finding(file, line, args, node)

      true ->
        []
    end
  end

  # The id of a finding: the rule, the file and the HASH of the offending call.
  #
  # The id must not carry the line number: a line moves whenever anything is inserted above
  # the site, and an accepted site that changes its line would become a NEW finding and block
  # every pull request that touches the file for an unrelated reason. The hash is over the
  # canonical text of the call, so a change OF the call is a new site (it has to be read
  # again) and a change AROUND it is not.
  defp finding_id(rule, file, node) do
    "#{rule}:#{file}:#{site_hash(node)}"
  end

  defp site_hash(node) do
    text =
      try do
        Macro.to_string(node)
      rescue
        _error -> inspect(node, limit: :infinity, printable_limit: :infinity)
      end

    :sha256
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  defp atom_finding(file, line, args, node) do
    if args != [] and not Enum.all?(args, &literal?/1) do
      [
        %{
          id: finding_id("unsafe_atom", file, node),
          rule: "unsafe_atom",
          file: file,
          package: file,
          line: line,
          detail: "an atom is created from a value that is not a literal"
        }
      ]
    else
      []
    end
  end

  defp deserialization_finding(file, line, args, node) do
    safe? = Enum.any?(args, &safe_term_option?/1)

    if not safe? do
      [
        %{
          id: finding_id("unsafe_deserialization", file, node),
          rule: "unsafe_deserialization",
          file: file,
          package: file,
          line: line,
          detail: "binary_to_term/1 without the :safe option"
        }
      ]
    else
      []
    end
  end

  defp safe_term_option?(arg) do
    match?({:safe, _}, arg)
  end

  defp command_finding(file, line, args, node) do
    if args != [] and not Enum.all?(args, &literal?/1) do
      [
        %{
          id: finding_id("command_injection", file, node),
          rule: "command_injection",
          file: file,
          package: file,
          line: line,
          detail: "a shell command is built from a value that is not a literal"
        }
      ]
    else
      []
    end
  end

  defp system_cmd_finding(file, line, args, node) do
    case args do
      [command | rest] ->
        shell? = is_binary(command) and command in @shells
        dynamic? = Enum.any?(rest, &(not literal?(&1)))

        if shell? and dynamic? do
          [
            %{
              id: finding_id("command_injection", file, node),
              rule: "command_injection",
              file: file,
              package: file,
              line: line,
              detail: "a shell is called with an argument that is not a literal"
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp sql_finding(file, line, args, node) do
    case args do
      [sql | _rest] ->
        if interpolated?(sql) do
          [
            %{
              id: finding_id("sql_interpolation", file, node),
              rule: "sql_interpolation",
              file: file,
              package: file,
              line: line,
              detail: "a raw SQL string is built by interpolation"
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  defp weak_hash_finding(file, line, args, node) do
    case args do
      [algorithm | _rest] when is_atom(algorithm) ->
        if algorithm in [:md5, :sha] do
          [
            %{
              id: finding_id("weak_hash", file, node),
              rule: "weak_hash",
              file: file,
              package: file,
              line: line,
              detail: "a weak hash algorithm (#{algorithm})"
            }
          ]
        else
          []
        end

      _ ->
        []
    end
  end

  # A literal is a value the reader can see: a binary, a number, an atom, a list or a pair of
  # literals. A variable, a call, an interpolation and every AST node (a variable is the node
  # `{:value, meta, context}`) is NOT a literal -- a rule that called a variable literal would
  # never fire.
  defp literal?(arg) when is_binary(arg) or is_number(arg) or is_atom(arg), do: true
  defp literal?(arg) when is_list(arg), do: Enum.all?(arg, &literal?/1)

  defp literal?({left, right}) when is_tuple(left), do: literal?(left) and literal?(right)
  defp literal?(_arg), do: false

  # True when the string carries an interpolation (`"#{...}"`), in either the plain or the sigil
  # form (`~s|...|`).
  defp interpolated?({:<<>>, _meta, parts}), do: Enum.any?(parts, &(not is_binary(&1)))

  # The two metadata lists are DIFFERENT (the sigil carries its delimiter), so they must not
  # share a variable name: a repeated variable in a pattern has to bind the same value.
  defp interpolated?({:sigil_s, _sigil_meta, [{:<<>>, _bin_meta, parts}, _delim]}),
    do: Enum.any?(parts, &(not is_binary(&1)))

  defp interpolated?(_other), do: false

  # ── the shared decision helpers ────────────────────────────────────────────────

  defp in_production?(advisory, packages) do
    case Map.get(packages, advisory.ecosystem) do
      nil -> false
      versions -> Map.has_key?(versions, advisory.package)
    end
  end

  defp severity_rank(advisory) do
    Map.get(@severity_rank, String.downcase(to_string(advisory.severity)), 3)
  end

  defp live_entry(entries, subject, today) do
    entries
    |> Enum.filter(&entry_covers?(&1, subject))
    |> Enum.sort_by(& &1.expires)
    |> case do
      [] ->
        :none

      [entry | _] ->
        if expired?(entry, today), do: :expired, else: {:ok, entry}
    end
  end

  # An entry covers a subject when it names the same id; the package is checked too, so an
  # entry for one package cannot silence an advisory about another one.
  #
  # The ids are compared as STRINGS. An advisory id is a string everywhere it is
  # produced, and an allow-list entry carries a string in its JSON: an id that was a list
  # or a number could never be matched by an entry, so no exception could ever have been
  # accepted for two of the three ecosystems. An entry may also name the advisory by one
  # of its aliases (the CVE or the GHSA id of the same advisory).
  defp entry_covers?(entry, subject) do
    ids = [to_string(Map.get(subject, :id)) | subject_aliases(subject)]
    id_match? = to_string(entry.id) in ids
    package_match? = entry.package in [nil, "", Map.get(subject, :package)]

    id_match? and package_match?
  end

  defp subject_aliases(subject) do
    subject
    |> Map.get(:aliases, [])
    |> Enum.filter(&is_binary/1)
  end

  defp expired?(entry, today) do
    case Date.from_iso8601(entry.expires) do
      {:ok, date} -> Date.compare(date, today) == :lt
      {:error, _reason} -> true
    end
  end

  defp normalise_entry!(entry) when is_map(entry) do
    %{
      id: entry["id"] || "",
      package: entry["package"] || "",
      reason: entry["reason"] || "",
      owner: entry["owner"] || "",
      expires: entry["expires"] || ""
    }
  end

  defp normalise_advisory!(advisory) when is_map(advisory) do
    %{
      id: advisory["id"] || "",
      aliases: advisory["aliases"] || [],
      ecosystem: String.to_existing_atom(advisory["ecosystem"] || "hex"),
      package: advisory["package"] || "",
      version: advisory["version"] || "",
      severity: advisory["severity"] || "high",
      title: advisory["title"] || ""
    }
  end
end
