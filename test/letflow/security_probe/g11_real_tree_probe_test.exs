defmodule Letflow.SecurityProbe.G11RealTreeProbeTest do
  @moduledoc """
  G-11: the mechanical route inventory and the general secret scanner must run on the REAL tree.

  The coverage map (team repository, `docs/security-coverage.md`, G-11) found the gap between a
  tested tool and an enforced real-tree check: `scripts/uat/check_routes.py` was exercised only on
  fake checkouts built by `test/scripts/check_routes_test.exs`, and `scripts/oss_audit/` had no CI
  job at all. A tool that is only tested on fixtures proves nothing about the tree it guards.

  This probe runs both tools on the repository it lives in and fails when either of them reports
  a problem:

    * the route inventory must be complete and clean (`ok`), and its route count must cover every
      route declaration of the router sources (an empty or truncated inventory is a failure, not
      a pass);
    * the secret scan must be COMPLETE (not PARTIAL and not INCOMPLETE), must have read the
      tracked tree, and must not report a secret-class finding that the reviewed triage list does
      not already carry.

  The non-vacuity cases are seeded: a tree with an undeclared route, a tracked file holding a
  credential-shaped value and a finding the triage list does not have must all be caught. The
  fake values are built by concatenation at run time, so no secret-shaped literal sits in this
  file (the repository's own secret scan reads it).

  Pure (no model, no database, no network): about one minute, most of it the secret scan of the
  tracked tree.
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag probe_cost_s: 90
  @moduletag :tmp_dir
  # The secret scan of the tracked tree takes 25-45 s on an idle host and more on a loaded one:
  # above the ExUnit default of 60 s per test the probe would be killed by the timeout (a first
  # run of the tagged set failed exactly there, on a loaded host).
  @moduletag timeout: 300_000

  @root Path.expand("../../..", __DIR__)
  @route_check Path.join(@root, "scripts/uat/check_routes.py")
  @secret_scan Path.join(@root, "scripts/oss_audit/oss_audit.sh")
  @triage Path.join([@root, "test", "fixtures", "security_probes", "g11_secret_scan_triage.txt"])

  # The credential-shaped rules of the scanner (scripts/oss_audit/rules.py): a private key, a
  # cloud-provider key, a provider token, a JWT, a connection string with a password. They are
  # gated over the whole tracked tree.
  @credential_rules ~w(S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12)

  # The password-assignment rule fires on fixture values all over the test tree, so it is gated
  # everywhere except the two directories that hold such values by design.
  @assignment_rule "S13"
  @assignment_free_prefixes ["test/", "handoffs/"]

  # The route macro of the inventory tool (scripts/uat/bp_inventory.py, ROUTE_RE). The probe
  # counts the declarations itself: the inventory may not be smaller than the declarations.
  @route_declaration ~r/^\s*(?:authz_)?(?:get|post|put|patch|delete)\s*\(?\s*"/

  # ------------------------------------------------------------------ the tools on the real tree

  test "G11: the real tree passes the mechanical route inventory" do
    {out, code} = run_route_check(@root)

    assert code == 0, out
    assert route_failures(out) == [], out
  end

  test "G11: the route inventory of the real tree is not empty and covers every declaration" do
    {out, code} = run_route_check(@root)
    assert code == 0, out

    routes = route_count(out)
    declarations = count_route_declarations(@root)

    assert routes > 0, "the route inventory is empty: nothing was scanned"
    assert declarations > 0, "the router sources hold no route declaration: the tree changed"

    assert routes >= declarations,
           "the inventory found #{routes} routes but the router sources declare #{declarations}"
  end

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

  test "G11: a tree with an undeclared route fails the route inventory", %{tmp_dir: dir} do
    copy = copy_route_inputs(@root, Path.join(dir, "tree"))

    {clean, clean_code} = run_route_check(copy)
    assert clean_code == 0, "the copied tree must pass before the mutation: " <> clean

    router = Path.join(copy, "lib/letflow/routers/tasks.ex")
    File.write!(router, File.read!(router) <> "\n  get \"/g11-seeded-route\"\n")

    {broken, broken_code} = run_route_check(copy)

    assert broken_code == 1, "the seeded route was not caught: " <> broken

    json = Jason.decode!(broken)

    assert json["ok"] == false
    assert route_failures(broken) != []

    gap =
      Enum.find(json["gaps"], fn entry ->
        entry["name"] == "GET /api/v1/tasks/g11-seeded-route"
      end)

    assert gap, "the seeded route is not among the gaps: " <> broken
    assert "no permission (plain route, no declared exemption)" in gap["problems"]
  end

  test "G11: a tracked file with a credential-shaped value fails the secret scan", %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "conf"))

    File.write!(Path.join(repo, "conf/credentials.txt"), "key " <> fake_aws_key() <> "\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "seeded"])

    {out, code} = run_secret_scan(repo)

    assert code == 0, "the scan of the seeded tree did not finish: " <> out
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

  defp run_route_check(root) do
    System.cmd("python3", ["-I", "-B", @route_check, "--json", "--root", root],
      stderr_to_stdout: false,
      cd: @root
    )
  end

  defp run_secret_scan(root) do
    System.cmd("bash", [@secret_scan, "--tree", "--format", "json", "--repo", root],
      stderr_to_stdout: false,
      cd: @root
    )
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

  # The inventory answers with JSON; every problem it found is one of the four lists.
  defp route_failures(out) do
    json = Jason.decode!(out)

    problems =
      Enum.map(
        [
          {"gaps", json["gaps"]},
          {"uncovered", json["uncovered"]},
          {"errors", json["errors"]},
          {"write targets", json["write_targets"]}
        ],
        fn {name, list} -> "#{name}: #{inspect(list)}" end
      )

    if json["ok"] == true, do: [], else: problems
  end

  defp route_count(out), do: Jason.decode!(out)["routes"]

  # The router sources the inventory reads (its own docstring names them).
  defp router_sources(root) do
    top = Path.join(root, "lib/letflow/router.ex")
    routers = Path.wildcard(Path.join(root, "lib/letflow/routers/*.ex"))
    modules = Path.wildcard(Path.join(root, "lib/letflow/modules/*/router.ex"))

    [top | routers] ++ modules
  end

  defp count_route_declarations(root) do
    Enum.reduce(router_sources(root), 0, fn file, acc ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.count(fn line ->
        trimmed = String.trim_leading(line)
        not String.starts_with?(trimmed, "#") and Regex.match?(@route_declaration, line)
      end)
      |> Kernel.+(acc)
    end)
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

  # The files the inventory reads: the router sources, the pipeline that mounts them, the
  # business-process documents and the module packs.

  # segments, not a literal path: a literal makes the CI path filters treat this fake checkout
  # as a repo read (the same reason test/scripts/check_routes_test.exs builds its paths). It also
  # keeps the file out of the docs-only test list (scripts/ci_docs_only.sh reads the name of a
  # docs directory as a literal).
  defp bp_path, do: Path.join(~w(docs bp))
  defp docs_dir, do: Path.join(~w(docs))

  defp copy_route_inputs(source, target) do
    File.mkdir_p!(Path.join(target, "lib/letflow/plugs"))
    File.mkdir_p!(Path.join(target, "lib/letflow/routers"))
    File.mkdir_p!(Path.join(target, docs_dir()))

    File.cp!(
      Path.join(source, "lib/letflow/router.ex"),
      Path.join(target, "lib/letflow/router.ex")
    )

    File.cp!(
      Path.join(source, "lib/letflow/plugs/api_pipeline.ex"),
      Path.join(target, "lib/letflow/plugs/api_pipeline.ex")
    )

    for file <- Path.wildcard(Path.join(source, "lib/letflow/routers/*.ex")) do
      File.cp!(file, Path.join(target, "lib/letflow/routers/#{Path.basename(file)}"))
    end

    for file <- Path.wildcard(Path.join(source, "lib/letflow/modules/*/router.ex")) do
      destination = Path.join(target, Path.relative_to(file, source))
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(file, destination)
    end

    File.cp_r!(Path.join(source, bp_path()), Path.join(target, bp_path()))

    for file <- Path.wildcard(Path.join(source, "priv/modules/*/pack.json")) do
      destination = Path.join(target, Path.relative_to(file, source))
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(file, destination)
    end

    target
  end

  # A fake value built at run time: no credential-shaped literal sits in this file.
  defp fake_aws_key, do: "AKIA" <> "Q7ZX2MWBN4HD5TRK"
end
