defmodule Letflow.SecurityProbe.G11RouteInventoryProbeTest do
  @moduledoc """
  G-11, part 1: the mechanical route inventory must run on the REAL tree.

  The coverage map (team repository, `docs/security-coverage.md`, G-11) found the gap between a
  tested tool and an enforced real-tree check: `scripts/uat/check_routes.py` was exercised only on
  fake checkouts built by `test/scripts/check_routes_test.exs`. A tool that is only tested on
  fixtures proves nothing about the tree it guards.

  This probe runs the inventory on the repository it lives in and fails when the inventory reports
  a problem: a route without a declaration, a route no business process and no orphan row names, a
  read error or a write-target violation. It also fails when the inventory is empty or holds fewer
  routes than the router sources declare (an empty or truncated inventory is a failure, not a pass).

  The non-vacuity case is seeded: a tree with an undeclared route must be caught. The copy of the
  route inputs is proven to pass before the seeded route is added, so the failure is caused by the
  seeded route and not by the copy.

  This is the cheap half of G-11 (the route inventory takes about 1.5 s on the real tree), so it
  fits the share of the operator's per-probe budget and runs in the checks step of every backend
  change. The secret scan is the other half and lives in
  `test/letflow/security_probe/g11_secret_scan_probe_test.exs`; both halves are mandatory tests of
  the CI backend gate.

  Pure (no model, no database, no network, no clock).
  """

  use ExUnit.Case, async: true

  @moduletag :security_probe
  @moduletag probe_cost_s: 10
  @moduletag :tmp_dir
  # The inventory reads the router sources, the pipeline and the business-process documents; on a
  # loaded host that is a few seconds, well inside the ExUnit default of 60 s per test.
  @moduletag timeout: 120_000

  @root Path.expand("../../..", __DIR__)
  @route_check Path.join(@root, "scripts/uat/check_routes.py")

  # The route macro of the inventory tool (scripts/uat/bp_inventory.py, ROUTE_RE). The probe
  # counts the declarations itself: the inventory may not be smaller than the declarations.
  @route_declaration ~r/^\s*(?:authz_)?(?:get|post|put|patch|delete)\s*\(?\s*"/

  # ------------------------------------------------------------------ the tool on the real tree

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

  # ------------------------------------------------------------------------- the seeded failure

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

  # ------------------------------------------------------------------------------- the helpers

  defp run_route_check(root) do
    System.cmd("python3", ["-I", "-B", @route_check, "--json", "--root", root],
      stderr_to_stdout: false,
      cd: @root
    )
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
end
