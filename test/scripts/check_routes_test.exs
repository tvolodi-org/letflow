defmodule Letflow.Scripts.CheckRoutesTest do
  @moduledoc """
  T-2494 (D-170): `scripts/uat/check_routes.py` is the mechanical route inventory: every route declares its
  authentication, tenant scope and permission, or the check fails; a `none-by-design` route needs an entry
  (reason + owner) in the allow-list; every route is referenced by a process task or an orphan row. Every
  test runs the real script on a small fake checkout built in `tmp_dir`.

  The `t2299_hole` tests run the pack half (WRITE-TARGETS) on the fixtures of the T-2299 hole.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/uat/check_routes.py")
  @fixtures Path.join([@root, "test", "fixtures", "t2299_hole"])

  @api_router """
  defmodule Letflow.Routers.Widgets do
    use Letflow.Api.AuthorizedRouter

    authz_get "/", :WidgetsRead do
      ok(conn)
    end

    post "/loose" do
      ok(conn)
    end
  end
  """

  @top_router """
  defmodule Letflow.Router do
    use Plug.Router

    forward("/api/v1", to: Letflow.Plugs.ApiPipeline)
    forward("/api/open", to: Letflow.Routers.Open)
  end
  """

  @pipeline """
  defmodule Letflow.Plugs.ApiPipeline do
    forward("/widgets", to: Letflow.Routers.Widgets)
  end
  """

  @open_router """
  defmodule Letflow.Routers.Open do
    use Plug.Router

    get "/ping" do
      send_resp(conn, 200, "ok")
    end
  end
  """

  @orphan_header "| function | file:line | what it does | history | why it exists | proposed action |\n|---|---|---|---|---|---|\n"

  # segments, not a literal path: a literal makes the CI path filters treat this fake checkout as a repo read
  defp bp_path(name), do: Path.join(~w(docs bp) ++ [name])

  defp write(dir, path, content) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp build(dir) do
    write(dir, "lib/letflow/router.ex", @top_router)
    write(dir, "lib/letflow/plugs/api_pipeline.ex", @pipeline)
    write(dir, "lib/letflow/routers/widgets.ex", @api_router)
    write(dir, "lib/letflow/routers/open.ex", @open_router)
    dir
  end

  defp allow(dir, entries), do: write(dir, bp_path("public-routes.json"), Jason.encode!(entries))

  defp declare_all(dir) do
    allow(dir, [
      %{
        "route" => "POST /api/v1/widgets/loose",
        "permission" => "exempt",
        "reason" => "any signed-in user may post a loose widget",
        "owner" => "PM"
      },
      %{
        "route" => "GET /api/open/ping",
        "authentication" => "none-by-design",
        "tenant_scope" => "none-by-design",
        "permission" => "exempt",
        "reason" => "liveness probe",
        "owner" => "platform"
      }
    ])
  end

  defp run(dir, args \\ []),
    do:
      System.cmd("python3", ["-I", "-B", @script, "--root", dir] ++ args, stderr_to_stdout: true)

  defp orphans(dir) do
    rows =
      "| GET /api/v1/widgets | lib/letflow/routers/widgets.ex:4 | lists | git log | read model | keep as a platform function |\n" <>
        "| POST loose | lib/letflow/routers/widgets.ex:8 | posts | git log | legacy | keep as a platform function |\n" <>
        "| ping | lib/letflow/routers/open.ex:4 | probe | git log | ops | keep as a platform function |\n"

    write(dir, bp_path("orphans-stock.md"), @orphan_header <> rows)
  end

  test "an undeclared route fails: no permission, no authentication, no scope are named", %{
    tmp_dir: dir
  } do
    build(dir)
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "ERROR POST /api/v1/widgets/loose"
    assert out =~ "no permission (plain route, no declared exemption)"
    assert out =~ "ERROR GET /api/open/ping"
    assert out =~ "no declared authentication"
    assert out =~ "no declared tenant scope"
    assert out =~ "unknown public route"
    refute out =~ "ERROR GET /api/v1/widgets "
    assert out =~ "check_routes: FAIL"
  end

  test "a declared exemption passes: all declared, all covered by orphan rows, exit 0", %{
    tmp_dir: dir
  } do
    build(dir)
    declare_all(dir)
    orphans(dir)
    {out, code} = run(dir)
    assert code == 0, out
    assert out =~ "ROUTES 3: 3 declared, 0 with a gap; 3 covered, 0 not"
    assert out =~ "check_routes: PASS"
  end

  test "an unknown public route fails although the other route is declared", %{tmp_dir: dir} do
    build(dir)

    allow(dir, [
      %{
        "route" => "POST /api/v1/widgets/loose",
        "permission" => "exempt",
        "reason" => "open to all",
        "owner" => "PM"
      }
    ])

    {out, code} = run(dir)
    assert code == 1
    assert out =~ "ERROR GET /api/open/ping"
    assert out =~ "unknown public route (outside /api/v1, not in the allow-list)"
    refute out =~ "ERROR POST /api/v1/widgets/loose"
  end

  test "none-by-design without reason and owner is an error", %{tmp_dir: dir} do
    build(dir)

    allow(dir, [
      %{
        "route" => "GET /api/open/ping",
        "authentication" => "none-by-design",
        "tenant_scope" => "platform-level",
        "permission" => "exempt"
      }
    ])

    {out, code} = run(dir)
    assert code == 1
    assert out =~ "a none-by-design / exempt declaration needs a reason"
    assert out =~ "a none-by-design / exempt declaration needs a owner"
  end

  test "a stale entry (no such route) and a bad vocabulary value are errors", %{tmp_dir: dir} do
    build(dir)

    allow(dir, [
      %{
        "route" => "GET /api/open/gone",
        "authentication" => "magic",
        "tenant_scope" => "host",
        "permission" => "X"
      }
    ])

    {out, code} = run(dir)
    assert code == 1
    assert out =~ "authentication 'magic' is not one of"
    assert out =~ "route GET /api/open/gone is declared but no router has it"
  end

  test "coverage: a route no process task and no orphan row names fails", %{tmp_dir: dir} do
    build(dir)
    declare_all(dir)
    {out, code} = run(dir)
    assert code == 1
    assert out =~ "ROUTES 3: 3 declared, 0 with a gap; 0 covered, 3 not"
    assert out =~ "uncovered GET /api/v1/widgets"
  end

  test "--gaps-md writes the failing routes as a table", %{tmp_dir: dir} do
    build(dir)
    file = Path.join(dir, "gaps.md")
    {_out, 1} = run(dir, ["--gaps-md", file])
    md = File.read!(file)
    assert md =~ "| `GET /api/open/ping` |"
    assert md =~ "| `POST /api/v1/widgets/loose` |"
    refute md =~ "| `GET /api/v1/widgets` |"
  end

  describe "t2299_hole: write targets of a pack" do
    defp pack(dir, fixture) do
      write(dir, "priv/modules/maintenance/pack.json", File.read!(Path.join(@fixtures, fixture)))
      dir
    end

    test "t2299_hole: the hole form fails the check and names the variable", %{tmp_dir: dir} do
      pack(dir, "hole_pack.json")
      {out, code} = run(dir)
      assert code == 1
      assert out =~ "ERROR write target maintenance/maintenance_work_order/maintenance_work"
      assert out =~ "'maintenance_order_id' is completer-writable"
    end

    test "t2299_hole: the fixed form (engine-owned data) passes", %{tmp_dir: dir} do
      pack(dir, "fixed_pack.json")
      {out, _code} = run(dir)
      refute out =~ "write target"
    end

    test "t2299_hole: a source shape the engine rule cannot see fails", %{tmp_dir: dir} do
      pack = @fixtures |> Path.join("fixed_pack.json") |> File.read!() |> Jason.decode!()

      bad =
        update_in(pack, ["definitions", Access.at(0), "graph", "nodes", Access.at(2)], fn node ->
          put_in(node, ["attributes", "module_writes", Access.at(0), "args", "order_id"], %{
            "variable" => "x"
          })
        end)

      write(dir, "priv/modules/maintenance/pack.json", Jason.encode!(bad))
      {out, code} = run(dir)
      assert code == 1
      assert out =~ "is not {'var': text} or {'const': _}"
    end
  end
end
