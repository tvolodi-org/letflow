defmodule Letflow.Scripts.CheckCatalogTest do
  @moduledoc """
  T-2474 (D-168/D-169): `scripts/uat/check_catalog.py` validates the catalog file of the area and the orphan files
  and computes COVERAGE against the inventory. Every test runs the real script on a small fake checkout built
  in `tmp_dir` (one stock module: two routes, one screen, one rule), so coverage is exact: 4 items.

  T-2586 (D-175): the same script validates the optional `executed_by` of an entry (`direct` or
  `definition:<process_key>`; a missing field means `direct`) and counts the two forms in its report.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/uat/check_catalog.py")

  @router_ex """
  defmodule Letflow.Modules.Stock.Router do
    use Letflow.Api.AuthorizedRouter

    authz_get "/balances", :StockRead do
      ok(conn)
    end

    authz_post "/documents", :StockWrite do
      ok(conn)
    end
  end
  """

  @declare_ex """
  defmodule Letflow.Modules.Stock.LedgerPolicy do
    def declare(cmd), do: {:ok, cmd}
  end
  """

  @routes_tsx """
  export const stockRouteObjects = [
    { path: 'admin/stock/documents', element: <DocumentsPage /> },
  ]
  """

  @orphan_header "| function | file:line | what it does | history | why it exists | proposed action |\n|---|---|---|---|---|---|\n"

  defp build(dir) do
    files = %{
      "lib/letflow/modules/stock/router.ex" => @router_ex,
      "lib/letflow/modules/stock/ledger_policy/declare.ex" => @declare_ex,
      Path.join(["web", "src", "modules", "stock", "stockRoutes.tsx"]) => @routes_tsx,
      "test/uat/processes/BP-STOCK-01.json" => "{}"
    }

    for {path, content} <- files, do: write(dir, path, content)
    dir
  end

  # segments, not a literal path: a literal makes the CI path filters treat this fake checkout as a repo read
  defp bp_path(name), do: Path.join(~w(docs bp) ++ [name])

  defp write(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp task(overrides) do
    Map.merge(
      %{
        "actor" => "STOREKEEPER",
        "forms" => [],
        "functions" => [],
        "route" => nil,
        "code_refs" => ["lib/letflow/modules/stock/router.ex:9"],
        "result" => "a draft"
      },
      overrides
    )
  end

  # covers: POST /documents (route), GET /balances (code_ref inside its span), the rule (functions), the screen (forms)
  defp full_tasks do
    [
      task(%{
        "route" => "post /api/v1/modules/stock/documents/",
        "forms" => ["admin/stock/documents"]
      }),
      task(%{
        "code_refs" => ["lib/letflow/modules/stock/router.ex:5"],
        "functions" => ["Letflow.Modules.Stock.LedgerPolicy.declare"]
      })
    ]
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "BP-STOCK-01",
        "area" => "stock",
        "title" => "Receive goods",
        "description" => "The storekeeper receives goods.",
        "actors" => [%{"role" => "STOREKEEPER", "permission" => "StockWrite"}],
        "preconditions" => ["module installed"],
        "tasks" => full_tasks(),
        "inputs" => ["item"],
        "outputs" => ["doc_id"],
        "refusals" => ["403 without StockWrite"],
        "scenario" => nil,
        "status" => "implemented"
      },
      overrides
    )
  end

  defp catalog(dir, entries, area \\ "stock") do
    write(dir, bp_path("#{area}.json"), Jason.encode!(entries))
  end

  defp run(dir, args \\ []),
    do:
      System.cmd("python3", ["-I", "-B", @script, "--root", dir] ++ args, stderr_to_stdout: true)

  test "full coverage by route, code_ref, forms and functions: 100% and exit 0", %{tmp_dir: dir} do
    build(dir)
    catalog(dir, [entry()])
    {out, code} = run(dir)
    assert code == 0, out
    assert out =~ "COVERAGE stock: 4/4 = 100.0%"
    assert out =~ "check_catalog: PASS"
  end

  test "below 100%: the uncovered item is listed and the exit code is 1", %{tmp_dir: dir} do
    build(dir)
    catalog(dir, [entry(%{"tasks" => [hd(full_tasks())]})])
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "COVERAGE stock: 2/4 = 50.0%"
    assert out =~ "uncovered GET /api/v1/modules/stock/balances"
    assert out =~ "uncovered Letflow.Modules.Stock.LedgerPolicy.declare"
    assert out =~ "check_catalog: FAIL"
  end

  test "a bad code_ref (missing file, line past the end, no line) is an error", %{tmp_dir: dir} do
    build(dir)

    refs = [
      "lib/letflow/modules/stock/nope.ex:1",
      "lib/letflow/modules/stock/router.ex:999",
      "lib/letflow/modules/stock/router.ex"
    ]

    catalog(dir, [entry(%{"tasks" => full_tasks() ++ [task(%{"code_refs" => refs})]})])
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "nope.ex:1': file does not exist"
    assert out =~ "router.ex:999': line outside the file (11 lines)"
    assert out =~ "'lib/letflow/modules/stock/router.ex' is not path:line"
  end

  test "an orphan row counts as covered", %{tmp_dir: dir} do
    build(dir)
    catalog(dir, [entry(%{"tasks" => [hd(full_tasks())]})])

    rows =
      "| GET /balances | lib/letflow/modules/stock/router.ex:4 | reads balances | REQ-1 | the read model | keep as a platform function |\n" <>
        "| declare | lib/letflow/modules/stock/ledger_policy/declare.ex:2 | declares postings | git log -S declare | posting core | give a process |\n"

    write(dir, bp_path("orphans-stock.md"), "# Orphans\n\n" <> @orphan_header <> rows)
    {out, code} = run(dir)
    assert code == 0, out
    assert out =~ "COVERAGE stock: 4/4 = 100.0%"
  end

  test "orphan rows: empty column, unknown action, unresolved ref and a stale row are errors", %{
    tmp_dir: dir
  } do
    build(dir)
    catalog(dir, [entry()])

    rows =
      "| a | lib/letflow/modules/stock/router.ex:4 |  | h | w | remove |\n" <>
        "| b | lib/letflow/modules/stock/router.ex:4 | x | h | w | delete it |\n" <>
        "| c | lib/letflow/modules/stock/gone.ex:4 | x | h | w | remove |\n" <>
        "| d | lib/letflow/modules/stock/router.ex:2 | x | h | w | remove |\n"

    write(dir, bp_path("orphans-stock.md"), @orphan_header <> rows)
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "orphan a: column 'what it does' is empty"
    assert out =~ "orphan b: proposed action must be one of"
    assert out =~ "orphan c: code_ref 'lib/letflow/modules/stock/gone.ex:4': file does not exist"
    assert out =~ "orphan d (lib/letflow/modules/stock/router.ex:2) matches no inventory item"
  end

  test "an orphan file with a wrong header is an error", %{tmp_dir: dir} do
    build(dir)
    catalog(dir, [entry()])
    write(dir, bp_path("orphans-stock.md"), "| function | file |\n|---|---|\n| a | b |\n")
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "the table header must be | function | file:line"
  end

  test "entry fields: duplicate id, wrong area id, bad status, planned without requirement, missing scenario",
       %{tmp_dir: dir} do
    build(dir)

    catalog(dir, [
      entry(),
      entry(%{"title" => "again"}),
      entry(%{"id" => "BP-ASSETS-01"}),
      entry(%{"id" => "BP-STOCK-02", "status" => "done"}),
      entry(%{"id" => "BP-STOCK-03", "status" => "planned", "tasks" => []}),
      entry(%{"id" => "BP-STOCK-04", "scenario" => "test/uat/processes/missing.json"})
    ])

    {out, code} = run(dir)
    assert code == 1
    assert out =~ "id BP-STOCK-01 is already used"
    assert out =~ "BP-ASSETS-01: id must be BP-STOCK-nn"
    assert out =~ "BP-STOCK-02: status 'done' is not one of implemented, partial, planned"
    assert out =~ "BP-STOCK-03: a planned process names its `requirement`"
    assert out =~ "BP-STOCK-04: scenario 'test/uat/processes/missing.json' does not exist"
  end

  test "a planned entry with a requirement and no tasks is valid; an existing scenario is accepted",
       %{tmp_dir: dir} do
    build(dir)

    catalog(dir, [
      entry(%{"scenario" => "test/uat/processes/BP-STOCK-01.json"}),
      entry(%{
        "id" => "BP-STOCK-02",
        "status" => "planned",
        "requirement" => "REQ-900",
        "tasks" => []
      })
    ])

    {out, code} = run(dir)
    assert code == 0, out
  end

  test "missing fields and wrong types are named; an implemented task needs code_refs", %{
    tmp_dir: dir
  } do
    build(dir)
    bad_task = %{"actor" => "A", "forms" => "x", "result" => "r", "functions" => [], "route" => 5}

    catalog(dir, [
      Map.drop(entry(), ["refusals", "outputs"]),
      entry(%{
        "id" => "BP-STOCK-02",
        "actors" => [],
        "tasks" => [bad_task, task(%{"code_refs" => []})]
      })
    ])

    {out, code} = run(dir)
    assert code == 1
    assert out =~ "BP-STOCK-01: missing field 'refusals'"
    assert out =~ "BP-STOCK-01: missing field 'outputs'"
    assert out =~ "BP-STOCK-02: actors must be a non-empty list"
    assert out =~ "BP-STOCK-02 task 1: missing field 'code_refs'"
    assert out =~ "task 1: forms must be a list of texts"
    assert out =~ "task 1: route must be a text"
    assert out =~ "task 2: an implemented process names code_refs"
  end

  test "invalid JSON and a non-list file are errors", %{tmp_dir: dir} do
    build(dir)
    write(dir, bp_path("stock.json"), "{not json")
    {out, code} = run(dir)
    assert code == 1
    assert out =~ bp_path("stock.json") <> ": invalid JSON"

    write(dir, bp_path("stock.json"), "{}")
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "the file must be a JSON list of entries"
  end

  test "an area is named explicitly; `all` covers empty inventories at 100%; no files at all fails",
       %{tmp_dir: dir} do
    build(dir)
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "no catalog files"

    {out, code} = run(dir, ["stock"])
    assert code == 1
    assert out =~ "COVERAGE stock: 0/4 = 0.0%"

    catalog(dir, [entry()])
    {out, code} = run(dir, ["all"])
    assert code == 0, out
    assert out =~ "COVERAGE stock: 4/4 = 100.0%"
    assert out =~ "COVERAGE assets: 0/0 = 100.0%"
    assert out =~ "COVERAGE mes: 0/0 = 100.0%"

    {out, code} = run(dir, ["nonsense"])
    assert code == 2
    assert out =~ "unknown area nonsense"
  end

  test "documented non-area files are skipped; unknown JSON fails and areas are still checked", %{
    tmp_dir: dir
  } do
    build(dir)
    catalog(dir, [entry()])

    for name <- [
          "public-routes.json",
          "dead-code.json",
          "dead-code-allow.json",
          "dead-code-baseline.json"
        ] do
      write(dir, bp_path(name), "{}")
    end

    for name <- ["route-gaps.md", "route-gaps-extra.md"],
        do: write(dir, bp_path(name), "# Notes\n")

    {out, code} = run(dir)
    assert code == 0, out
    refute out =~ "not an area catalog"

    write(dir, bp_path("other.json"), "[]")
    {out, code} = run(dir)
    assert code == 1
    assert out =~ bp_path("other.json") <> ": not an area catalog"

    File.rm!(Path.join(dir, bp_path("other.json")))
    write(dir, bp_path("stock.json"), "{}")
    {out, code} = run(dir)
    assert code == 1
    assert out =~ bp_path("stock.json") <> ": the file must be a JSON list of entries"
  end

  test "--json prints the missing items", %{tmp_dir: dir} do
    build(dir)
    catalog(dir, [entry(%{"tasks" => [hd(full_tasks())]})])
    {out, 1} = run(dir, ["--json"])
    result = Jason.decode!(out)
    assert result["ok"] == false

    assert [
             %{
               "area" => "stock",
               "items" => 4,
               "covered" => 2,
               "percent" => 50.0,
               "missing" => missing
             }
           ] = result["areas"]

    assert length(missing) == 2
  end

  test "executed_by: direct, definition:<key> and a missing field are valid", %{tmp_dir: dir} do
    build(dir)

    catalog(dir, [
      entry(%{"executed_by" => "direct"}),
      entry(%{"id" => "BP-STOCK-02", "executed_by" => "definition:platform.register_tenant"}),
      entry(%{"id" => "BP-STOCK-03"})
    ])

    {out, code} = run(dir)
    assert code == 0, out
  end

  test "a wrong executed_by form is an error and is named", %{tmp_dir: dir} do
    build(dir)

    catalog(dir, [
      entry(%{"executed_by" => "engine"}),
      entry(%{"id" => "BP-STOCK-02", "executed_by" => "definition:"}),
      entry(%{"id" => "BP-STOCK-03", "executed_by" => "definition:two words"}),
      entry(%{"id" => "BP-STOCK-04", "executed_by" => 7})
    ])

    {out, code} = run(dir)
    assert code == 1

    assert out =~
             "BP-STOCK-01: executed_by 'engine' must be 'direct', 'n/a' or 'definition:<process_key>'"

    assert out =~ "BP-STOCK-02: executed_by 'definition:' must name a process key"
    assert out =~ "BP-STOCK-03: executed_by 'definition:two words' must name a process key"
    assert out =~ "BP-STOCK-04: executed_by must be a text"
  end

  test "executed_by n/a is a valid third kind, counted apart", %{tmp_dir: dir} do
    build(dir)
    catalog(dir, [entry(%{"executed_by" => "n/a"}), entry(%{"id" => "BP-STOCK-02"})])
    {out, code} = run(dir)
    assert code == 0, out
    assert out =~ "EXECUTED BY total: 1 direct, 0 definition, 1 n/a"
  end

  test "the report counts the direct and the definition processes", %{tmp_dir: dir} do
    build(dir)

    catalog(dir, [
      entry(%{"executed_by" => "direct"}),
      entry(%{"id" => "BP-STOCK-02", "executed_by" => "definition:platform.register_tenant"}),
      entry(%{"id" => "BP-STOCK-03"})
    ])

    {out, code} = run(dir)
    assert code == 0, out
    assert out =~ "EXECUTED BY stock: 2 direct, 1 definition"
    assert out =~ "EXECUTED BY total: 2 direct, 1 definition"

    {out, 0} = run(dir, ["--json"])
    result = Jason.decode!(out)
    assert result["executed_by"] == %{"direct" => 2, "definition" => 1, "n/a" => 0}
    assert [%{"executed_by" => %{"direct" => 2, "definition" => 1, "n/a" => 0}}] = result["areas"]
  end

  # T-2543: chain coverage. Every SEC file is listed in exactly one of the two release-candidate chains.
  defp chain_fixture(dir, chains) do
    build(dir)
    catalog(dir, [entry()])
    write(dir, "test/uat/processes/SEC-AAA-01-one.json", "{}")
    write(dir, "test/uat/processes/SEC-AAA-02-two.json", "{}")

    for {name, entries} <- chains do
      write(
        dir,
        "test/uat/chains/#{name}.json",
        Jason.encode!(%{"id" => name, "processes" => entries})
      )
    end
  end

  test "chain coverage: every SEC file in exactly one chain (string and object entries) passes",
       %{tmp_dir: dir} do
    chain_fixture(dir, %{
      "rc-sss" => ["SEC-AAA-01"],
      "rc-sec" => [%{"process" => "SEC-AAA-02", "dry_run" => true}]
    })

    {out, code} = run(dir)
    assert code == 0, out
    assert out =~ "check_catalog: PASS"
  end

  test "chain coverage: a SEC file in no chain fails and is named", %{tmp_dir: dir} do
    chain_fixture(dir, %{"rc-sss" => ["SEC-AAA-01"], "rc-sec" => []})
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "SEC-AAA-02-two.json: listed in none of rc-sss, rc-sec"
  end

  test "chain coverage: a SEC file in both chains fails and is named", %{tmp_dir: dir} do
    chain_fixture(dir, %{
      "rc-sss" => ["SEC-AAA-01", "SEC-AAA-02"],
      "rc-sec" => [%{"process" => "SEC-AAA-02"}]
    })

    {out, code} = run(dir)
    assert code == 1
    assert out =~ "SEC-AAA-02-two.json: listed in more than one chain (rc-sss, rc-sec)"
  end

  test "chain coverage: an entry naming a missing file fails", %{tmp_dir: dir} do
    chain_fixture(dir, %{"rc-sss" => ["SEC-AAA-01", "SEC-ZZZ-09"], "rc-sec" => ["SEC-AAA-02"]})
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "entry SEC-ZZZ-09 names no file in test/uat/processes"
  end
end
