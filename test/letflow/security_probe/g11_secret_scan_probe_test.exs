defmodule Letflow.SecurityProbe.G11SecretScanProbeTest do
  @moduledoc """
  G-11, part 2: the general secret scan must run on the REAL tree.

  The coverage map (team repository, `docs/security-coverage.md`, G-11) found that
  `scripts/oss_audit/` had no CI invocation at all: the scanner's own tests run, but no scan of
  the real tree ever did. A secret scanner that is only tested on fixtures proves nothing about the
  tree it guards.

  This probe runs the scanner's tree scope on the repository it lives in and fails when:

    * the scan is not COMPLETE (PARTIAL or INCOMPLETE coverage is a failure), or it has not read
      the tracked tree;
    * the scan reports a secret-class finding the reviewed triage list does not carry, or a listed
      finding that occurs more often than it did when it was reviewed;
    * the scanner holds a secret rule that the probe does not gate: the gated set is derived from
      the scanner's own rule table, so a rule added there cannot pass unnoticed.

  The non-vacuity cases are seeded: a tracked file holding a credential-shaped value must be
  caught, and a finding the triage list does not carry must be a failure. The fake value is built
  by concatenation at run time, so no secret-shaped literal sits in this file (the repository's own
  secret scan reads it).

  This is the expensive half of G-11: the scan of the tracked tree takes about 46 s on this host
  (35 s on an idle one), which is more than the share of the operator's per-probe budget, so it runs
  in the CI backend gate and in the nightly job rather than in the checks step (PM rule 2 of
  2026-11-22). The route half of G-11 is
  `test/letflow/security_probe/g11_route_inventory_probe_test.exs`; both halves are mandatory
  tests of the CI backend gate.

  Pure (no model, no database, no network, no clock).
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag probe_cost_s: 90
  @moduletag :tmp_dir
  # The secret scan of the tracked tree takes 35-70 s on this host and more on a loaded one: above
  # the ExUnit default of 60 s per test the probe would be killed by the timeout (a first run of
  # the tagged set failed exactly there, on a loaded host).
  @moduletag timeout: 300_000

  @root Path.expand("../../..", __DIR__)
  @secret_scan Path.join(@root, "scripts/oss_audit/oss_audit.sh")
  @rules_path Path.join(@root, "scripts/oss_audit/rules.py")
  @triage Path.join([@root, "test", "fixtures", "security_probes", "g11_secret_scan_triage.txt"])

  # The credential-shaped rules of the scanner (scripts/oss_audit/rules.py): a private key, a
  # cloud-provider key, a provider token, a JWT, a connection string with a password. They are
  # gated over the whole tracked tree.
  @credential_rules ~w(S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12)

  # The password-assignment rule fires on fixture values all over the test tree, so it is gated
  # everywhere except the two directories that hold such values by design.
  @assignment_rule "S13"
  @assignment_free_prefixes ["test/", "handoffs/"]

  # A secret rule of the scanner that the probe deliberately does NOT gate, with the reason.
  # It is empty today: every secret rule the scanner can emit without --include-noise is gated.
  # The rule set below is derived from the scanner's own table (SECRET_RULE_IDS in
  # scripts/oss_audit/rules.py), so a rule added there and not gated here fails the probe
  # instead of passing unnoticed.
  @ungated_rules %{}

  # ------------------------------------------------------------------ the tool on the real tree

  test "G11: the real tree passes the general secret scan and the scan is complete" do
    {out, code} = run_secret_scan(@root)

    assert code == 0,
           "the secret scan did not finish cleanly (exit #{code}): " <>
             "3 = PARTIAL, 4 = INCOMPLETE coverage"

    coverage = scan_coverage(out)
    findings = gated_findings(out)

    assert coverage.status == "COMPLETE",
           "the secret scan coverage is #{coverage.status}, not COMPLETE"

    assert coverage.tree_files > 0, "the secret scan read no file"

    tracked = tracked_file_count()

    assert coverage.tree_files * 100 >= tracked * 99,
           "the secret scan read #{coverage.tree_files} of #{tracked} tracked files"

    failures = secret_failures(findings, triage_entries())

    assert failures == [],
           "the tree holds a secret-class finding the triage list does not carry:\n" <>
             Enum.join(failures, "\n")
  end

  test "G11: the triage list is not empty and every entry names a triaged finding" do
    entries = triage_entries()

    assert map_size(entries) > 0, "the triage list is empty: every finding would be new"

    for {{rule, path}, count} <- entries do
      assert rule in @credential_rules or rule == @assignment_rule,
             "#{path}: #{rule} is not a gated rule"

      assert count > 0, "#{path}: the triaged count must be positive"
    end
  end

  # ------------------------------------------------------------------------- the seeded failures

  test "G11: every secret rule of the scanner is gated by the probe" do
    ids = scanner_secret_rule_ids()

    assert ids != [], "the scanner's rule table holds no secret rule: the derivation is broken"

    for id <- ids do
      gated = id in @credential_rules or id == @assignment_rule
      documented = Map.has_key?(@ungated_rules, id)

      assert gated or documented,
             "#{id} is a secret rule of scripts/oss_audit/rules.py that the probe neither " <>
               "gates nor documents as deliberately ungated"
    end

    for {id, reason} <- @ungated_rules do
      assert id in ids, "#{id} is documented as ungated but is not a secret rule of the scanner"
      assert reason != "", "#{id} is documented as ungated without a reason"
    end
  end

  test "G11: a tracked file with a credential-shaped value fails the secret scan", %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "conf"))

    File.write!(Path.join(repo, "conf/credentials.txt"), "key " <> fake_aws_key() <> "\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "seeded"])

    {out, code} = run_secret_scan(repo)

    # The scanner's own output carries masked hints (partial secrets, scripts/oss_audit/README.md),
    # so it never goes into an assertion message: the exit code and the coverage status are
    # enough to diagnose the run.
    assert code == 0, "the scan of the seeded tree did not finish (exit #{code})"
    assert scan_coverage(out).status == "COMPLETE"

    failures = secret_failures(gated_findings(out), triage_entries())

    assert Enum.any?(failures, &String.starts_with?(&1, "S02 conf/credentials.txt")),
           "the seeded credential was not caught: " <> inspect(failures)
  end

  test "G11: a finding the triage list does not carry is a failure" do
    entries = triage_entries()

    failures = secret_failures(%{{"S02", "lib/letflow/example.ex"} => 1}, entries)

    assert failures == ["S02 lib/letflow/example.ex (1 occurrence, the triage list carries 0)"]
  end

  # ------------------------------------------------------------------------------- the helpers

  defp run_secret_scan(root) do
    System.cmd("bash", [@secret_scan, "--tree", "--format", "json", "--repo", root],
      stderr_to_stdout: false,
      cd: @root
    )
  end

  # The scanner's canonical set of secret rules, read from its own rule table
  # (scripts/oss_audit/rules.py, SECRET_RULE_IDS: the secret-class rules that are not
  # noise-only). The module is loaded by path, so the probe does not depend on the scanner's
  # directory being on the interpreter's path.
  defp scanner_secret_rule_ids do
    program = """
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("oss_audit_rules", sys.argv[1])
    rules = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rules)
    print(",".join(sorted(rules.SECRET_RULE_IDS)))
    """

    {out, code} =
      System.cmd("python3", ["-I", "-B", "-c", program, @rules_path],
        cd: @root,
        stderr_to_stdout: false
      )

    assert code == 0, "the scanner's rule table could not be read (exit #{code})"

    out
    |> String.trim()
    |> String.split(",")
    |> Enum.reject(&(&1 == ""))
  end

  defp git!(dir, args) do
    {out, code} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@t.invalid", "-c", "commit.gpgsign=false"] ++
          args,
        cd: dir,
        stderr_to_stdout: false
      )

    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
  end

  # The scanner answers with one JSON line per finding and two coverage lines (the status and
  # the counters). The status is the one without the counters.
  defp scan_coverage(out) do
    lines = String.split(out, "\n")

    status =
      Enum.find(lines, fn line ->
        String.starts_with?(line, "# coverage\t") and not String.contains?(line, "head=")
      end)

    counters =
      Enum.find(lines, fn line -> String.starts_with?(line, "# coverage\thead=") end)

    tree_files =
      case Regex.run(~r/tree_files=(\d+)/, counters || "") do
        [_, count] -> String.to_integer(count)
        _ -> 0
      end

    %{
      status:
        (status || "# coverage\tMISSING")
        |> String.replace_prefix("# coverage\t", "")
        |> String.trim(),
      tree_files: tree_files
    }
  end

  defp gated_findings(out) do
    out
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&gated?/1)
    |> Enum.group_by(fn row -> {row["rule"], row["path"]} end)
    |> Map.new(fn {{rule, path}, rows} ->
      {{rule, path}, rows |> Enum.map(& &1["seen_in"]) |> Enum.sum()}
    end)
  end

  defp gated?(row) do
    rule = row["rule"]
    path = row["path"]

    cond do
      rule in @credential_rules ->
        true

      rule == @assignment_rule ->
        not Enum.any?(@assignment_free_prefixes, &String.starts_with?(path, &1))

      true ->
        false
    end
  end

  defp triage_entries do
    @triage
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Map.new(fn line ->
      case String.split(line, "\t") do
        [rule, path, count] -> {{rule, path}, String.to_integer(count)}
        _ -> raise "the triage list has a malformed line: #{inspect(line)}"
      end
    end)
  end

  # A finding the triage list does not carry is a new secret. A finding that is there but grew
  # is one too (the list carries the number of occurrences it was reviewed with).
  defp secret_failures(findings, entries) do
    findings
    |> Enum.sort_by(fn {{rule, path}, _count} -> {rule, path} end)
    |> Enum.flat_map(fn {{rule, path}, count} ->
      carried = Map.get(entries, {rule, path}, 0)

      if count > carried do
        [
          "#{rule} #{path} (#{count} occurrence#{if count == 1, do: "", else: "s"}, " <>
            "the triage list carries #{carried})"
        ]
      else
        []
      end
    end)
  end

  defp tracked_file_count do
    {out, 0} = System.cmd("git", ["ls-files"], cd: @root, stderr_to_stdout: false)
    out |> String.split("\n") |> Enum.count(&(&1 != ""))
  end

  # A fake value built at run time: no credential-shaped literal sits in this file.
  defp fake_aws_key, do: "AKIA" <> "Q7ZX2MWBN4HD5TRK"
end
