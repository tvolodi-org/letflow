defmodule Letflow.Scripts.BpInventoryTest do
  @moduledoc """
  T-2474 (D-168/D-169): `scripts/uat/bp_inventory.py` lists the inventory of the business-process map
  mechanically. Every test runs the real script on a small fake checkout built in `tmp_dir` (no network,
  no database), plus one smoke run on this repository.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/uat/bp_inventory.py")

  @router_ex """
  defmodule Letflow.Modules.Stock.Router do
    use Letflow.Api.AuthorizedRouter

    authz_get "/balances", :StockRead do
      ok(conn)
    end

    authz_post "/documents", :StockWrite,
      scope: :tenant_wide do
      ok(conn)
    end

    # authz_get "/commented", :StockRead do
    authz_post "/documents/:id/issue", :StockWrite do
      ok(conn)
    end
  end
  """

  @declare_ex """
  defmodule Letflow.Modules.Stock.LedgerPolicy do
    def declare(:receipt, cmd), do: {:ok, cmd}
    def declare(:issue, cmd), do: {:ok, cmd}

    def validate(cmd), do: cmd

    defp hidden(cmd), do: cmd
  end
  """

  @stock_ex """
  defmodule Letflow.Modules.Stock do
    def manifest do
      [
        %Letflow.Modules.WriteHandlerSpec{
          name: "post_document",
          function: {Letflow.Modules.Stock.Handlers, :post_document}
        }
      ]
    end
  end
  """

  @routes_tsx """
  export const stockRouteObjects = [
    {
      path: 'admin/stock/documents',
      element: (
        <RequirePermission permission={STOCK_READ}>
          <DocumentsPage />
        </RequirePermission>
      ),
    },
    ...['admin/stock/counts', 'admin/stock/counts/:id'].map((path) => ({
      path,
      element: <CountsPage />,
    })),
  ]
  """

  @router_tsx """
  export const router = [
    { path: '/login', element: <LoginPage /> },
    {
      path: '/',
      element: <AppShell />,
      children: [
        { path: 'definitions', element: <DefinitionListPage /> },
        { path: 'admin/tenants', element: platformPage(P.TenantsManage, <TenantsPage />) },
        { path: 'admin/users', element: <RequirePermission permission={P.X}><UsersPage /></RequirePermission> },
        { path: 'mystery/page', element: <MysteryPage /> },
        { path: '*', element: <NotFoundPage /> },
      ],
    },
  ]
  """

  @tenants_ex """
  defmodule Letflow.Routers.Tenants do
    use Letflow.Api.AuthorizedRouter

    authz_get "/", :TenantsManage do
      ok(conn)
    end

    authz_post "/:id/suspend", :TenantsManage do
      ok(conn)
    end
  end
  """

  @pipeline_ex """
  defmodule Letflow.Plugs.ApiPipeline do
    forward("/tenants", to: Letflow.Routers.Tenants)
  end
  """

  defp pack_json do
    node = fn id, type, extra -> Map.merge(%{"id" => id, "node_type" => type}, extra) end

    Jason.encode!(
      %{
        "definitions" => [
          %{
            "process_key" => "stock_receipt",
            "graph" => %{
              "nodes" => [
                node.("start", "START", %{}),
                node.("post", "HUMAN_TASK", %{"attributes" => %{"role" => "TENANT_ADMIN"}}),
                node.("calc", "SCRIPT_TASK", %{}),
                node.("end", "END", %{})
              ],
              "edges" => [%{"id" => "e1", "source" => "start", "target" => "post"}]
            }
          }
        ]
      },
      pretty: true
    )
  end

  defp build(dir) do
    files = %{
      "lib/letflow/modules/stock/router.ex" => @router_ex,
      "lib/letflow/modules/stock/ledger_policy/declare.ex" => @declare_ex,
      "lib/letflow/modules/stock/stock.ex" => @stock_ex,
      "priv/modules/stock/pack.json" => pack_json(),
      "web/src/modules/stock/stockRoutes.tsx" => @routes_tsx,
      "web/src/router.tsx" => @router_tsx,
      "lib/letflow/routers/tenants.ex" => @tenants_ex,
      "lib/letflow/plugs/api_pipeline.ex" => @pipeline_ex
    }

    for {path, content} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    dir
  end

  defp run(args), do: System.cmd("python3", ["-I", "-B", @script | args], stderr_to_stdout: true)

  defp inventory(dir, area) do
    {out, code} = run([area, "--root", dir])
    assert code == 0, out
    Jason.decode!(out)
  end

  defp by_name(items, name), do: Enum.find(items, &(&1["name"] == name))

  test "routes: full mounted path, permission, commented line skipped, multi-line macro", %{
    tmp_dir: dir
  } do
    items = build(dir) |> inventory("stock")
    routes = Enum.filter(items, &(&1["kind"] == "route"))

    assert Enum.map(routes, & &1["name"]) == [
             "GET /api/v1/modules/stock/balances",
             "POST /api/v1/modules/stock/documents",
             "POST /api/v1/modules/stock/documents/:id/issue"
           ]

    assert by_name(routes, "POST /api/v1/modules/stock/documents")["permission"] == "StockWrite"
    assert by_name(routes, "POST /api/v1/modules/stock/documents")["line"] == 8

    # `end` is the line before the next item of the file; the last item reaches the end of the file
    assert by_name(routes, "POST /api/v1/modules/stock/documents")["end"] == 13
    assert by_name(routes, "POST /api/v1/modules/stock/documents/:id/issue")["end"] == 17
  end

  test "core router: the mount comes from the forward line, '/' is the mount itself", %{
    tmp_dir: dir
  } do
    items = build(dir) |> inventory("platform")
    names = for %{"kind" => "route", "name" => n} <- items, do: n
    assert names == ["GET /api/v1/tenants", "POST /api/v1/tenants/:id/suspend"]
  end

  test "pack nodes skip START/END, SCRIPT_TASK is a script, the handler is found by name", %{
    tmp_dir: dir
  } do
    items = build(dir) |> inventory("stock")

    assert %{"kind" => "pack_node", "path" => "priv/modules/stock/pack.json", "line" => line} =
             by_name(items, "stock_receipt/post")

    assert File.read!(Path.join(dir, "priv/modules/stock/pack.json"))
           |> String.split("\n")
           |> Enum.at(line - 1) =~ ~s("id": "post")

    assert %{"kind" => "script"} = by_name(items, "stock_receipt/calc")
    assert by_name(items, "stock_receipt/start") == nil
    assert by_name(items, "stock_receipt/end") == nil

    assert %{"kind" => "handler", "line" => 4, "aliases" => ["stock:post_document"]} =
             by_name(items, "stock.post_document")
  end

  test "rules are the public defs of a ledger_policy file, one per name", %{tmp_dir: dir} do
    items = build(dir) |> inventory("stock")
    rules = for %{"kind" => "rule"} = r <- items, do: {r["name"], r["line"]}

    assert rules == [
             {"Letflow.Modules.Stock.LedgerPolicy.declare", 2},
             {"Letflow.Modules.Stock.LedgerPolicy.validate", 5}
           ]
  end

  test "screens: component of the path, the map form gives both paths, areas split the core routes",
       %{tmp_dir: dir} do
    build(dir)
    stock = inventory(dir, "stock") |> Enum.filter(&(&1["kind"] == "screen"))

    assert Enum.map(stock, & &1["name"]) == [
             "admin/stock/documents -> DocumentsPage",
             "admin/stock/counts -> CountsPage",
             "admin/stock/counts/:id -> CountsPage"
           ]

    assert "admin/stock/documents" in hd(stock)["aliases"]

    names = fn area -> for %{"kind" => "screen", "name" => n} <- inventory(dir, area), do: n end
    assert names.("platform") == ["admin/tenants -> TenantsPage"]
    assert names.("tenant-admin") == ["/login -> LoginPage", "admin/users -> UsersPage"]
    assert names.("designer") == ["definitions -> DefinitionListPage"]
  end

  test "ids are unique and stable; `all` tags each item with its area", %{tmp_dir: dir} do
    build(dir)
    items = inventory(dir, "all")
    ids = Enum.map(items, & &1["id"])
    assert ids == Enum.uniq(ids)
    assert Enum.all?(items, &(&1["area"] in ["stock", "platform", "designer", "tenant-admin"]))
    assert inventory(dir, "stock") == inventory(dir, "stock")
  end

  test "--unassigned names a router and a screen that no area owns", %{tmp_dir: dir} do
    build(dir)

    File.write!(
      Path.join(dir, "lib/letflow/routers/brand_new.ex"),
      "defmodule Letflow.Routers.BrandNew do\nend\n"
    )

    {out, 0} = run(["--unassigned", "--root", dir])
    assert out =~ "router lib/letflow/routers/brand_new.ex"
    assert out =~ "screen mystery/page"
    refute out =~ "tenants.ex"
  end

  test "an unknown area is a usage error (exit 2)", %{tmp_dir: dir} do
    {out, code} = run(["no-such-area", "--root", dir])
    assert code == 2
    assert out =~ "area must be one of"
  end

  test "smoke: the real repository has every kind in the stock area and no duplicate ids" do
    {out, 0} = run(["stock"])
    items = Jason.decode!(out)
    kinds = items |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort()
    assert kinds == ["handler", "pack_node", "route", "rule", "screen"]
    ids = Enum.map(items, & &1["id"])
    assert ids == Enum.uniq(ids)

    for i <- items do
      assert File.regular?(Path.join(@root, i["path"])), i["path"]
      assert i["line"] >= 1 and i["end"] >= i["line"]
    end
  end
end
