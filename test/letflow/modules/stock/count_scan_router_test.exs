Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../codes/codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountScanRouterTest do
  @moduledoc """
  REQ-716 / GH #3765 criteria 7 and 8 (R7a..R7d, R8a..R8d): `POST /counts/:id/scan` of module `stock`
  through the full `Letflow.Router` with real OIDC bearer tokens on committed tenants in Sandbox
  `:auto` mode. `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CodesFixture, as: K
  alias Letflow.CountsFixture, as: F
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Counts
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp call(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, S.base() <> path)
        b -> Plug.Test.conn(method, S.base() <> path, Jason.encode!(b))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp strip(conn), do: M.strip_conn(conn)

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    S.json(conn)
  end

  defp window do
    now = DateTime.utc_now()

    %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(now, -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(now, 20 * 3600))
    }
  end

  # A tenant with codes installed, a world, a chair and a member who are real users, and a `counting` count
  # with one book line (the item at location a).
  defp world!(ctx, name) do
    t = S.tenant!("scanr", Map.fetch!(ctx.names, name))
    s = t.schema_name
    w = F.world!(s)
    chair_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "chair-#{name}")
    member_tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "member-#{name}")
    status!(call(:get, "/counts", chair_tok), 200)
    status!(call(:get, "/counts", member_tok), 200)
    chair_user = Repo.one!(from(u in User, where: u.username == ^"chair-#{name}"), prefix: s)
    member_user = Repo.one!(from(u in User, where: u.username == ^"member-#{name}"), prefix: s)
    chair = F.employee!(s, w.unit, user: chair_user.id)
    member = F.employee!(s, w.unit, user: member_user.id)
    w = %{w | chair: chair, members: [member]}
    m = D.masters!(s)
    S.post!(s, "receipt", %{lines: [S.line(m.item, "3", %{to: S.side(w.unit, w.a)})]})
    x = %{t: t, s: s, w: w, m: m, chair_tok: chair_tok, member_tok: member_tok}
    Map.put(x, :id, counting!(x))
  end

  defp counting!(x) do
    created = status!(call(:post, "/counts", x.chair_tok, F.input(x.w, window())), 201)
    id = created["id"]
    status!(call(:post, "/counts/#{id}/issue", x.chair_tok, %{}), 200)
    status!(call(:post, "/counts/#{id}/open", x.chair_tok, %{}), 200)
    id
  end

  defp code!(s, type, target) do
    value = "C-#{System.unique_integer([:positive])}"
    tag = K.tag!(s, value, %{"status" => "assigned"})
    K.assign!(s, tag, type, target)
    value
  end

  defp body(x, text, extra \\ %{}),
    do:
      Map.merge(
        %{"scanned_text" => text, "location_id" => x.w.a, "scan_id" => Ecto.UUID.generate()},
        extra
      )

  defp scan(_x, id, tok, b), do: call(:post, "/counts/#{id}/scan", tok, b)

  test "R7a an item scan answers 200 with the quantity as a JSON string", ctx do
    x = world!(ctx, :a)
    value = code!(x.s, "catalog_item", x.m.item)
    got = status!(scan(x, x.id, x.member_tok, body(x, value)), 200)
    assert got["duplicate"] == false and got["catalog_item_id"] == x.m.item

    assert is_binary(got["counted_quantity"]) and
             Decimal.equal?(Decimal.new(got["counted_quantity"]), 1)

    loc = code!(x.s, "location_node", x.w.a1)

    assert %{"kind" => "location", "location_id" => l} =
             status!(scan(x, x.id, x.member_tok, body(x, loc)), 200)

    assert l == x.w.a1
  end

  test "R7b refusals answer 422 with a reason", ctx do
    x = world!(ctx, :a)
    retired = "R-#{System.unique_integer([:positive])}"
    K.tag!(x.s, retired, %{"status" => "retired"})
    plain = "P-#{System.unique_integer([:positive])}"
    K.tag!(x.s, plain)
    item = code!(x.s, "catalog_item", x.m.item)
    first = body(x, item)

    for {b, reason} <- [
          {body(x, retired), "code_retired"},
          {body(x, plain), "code_not_assigned"},
          {body(x, item, %{"location_id" => x.w.b}), "location_not_in_count"},
          {body(x, code!(x.s, "catalog_item", Ecto.UUID.generate())), "scan_no_line"},
          {Map.put(body(x, item), "bogus", 1), "field_not_allowed"},
          {Map.delete(body(x, item), "scanned_text"), "field_invalid"}
        ] do
      assert status!(scan(x, x.id, x.member_tok, b), 422)["reason"] == reason
    end

    status!(scan(x, x.id, x.member_tok, first), 200)
    conflict = body(x, item, %{"scan_id" => first["scan_id"], "location_id" => x.w.a1})
    assert status!(scan(x, x.id, x.member_tok, conflict), 422)["reason"] == "scan_id_conflict"
    assert status!(scan(x, x.id, x.member_tok, [1]), 422)["reason"] == "field_invalid"
  end

  test "R7c an unknown code is the 404 of an unknown count id", ctx do
    x = world!(ctx, :a)
    want = scan(x, Ecto.UUID.generate(), x.member_tok, body(x, "nope"))
    assert want.status == 404

    outside = code!(x.s, "location_node", x.w.b)

    for text <- ["no-such-code", outside] do
      got = scan(x, x.id, x.member_tok, body(x, text))
      assert got.status == 404
      assert strip(got) == strip(want)
    end
  end

  test "R7d the route is declared in the module's route policies" do
    assert {"POST", "/counts/:id/scan", :StockCountRecord} in Letflow.Modules.Stock.manifest().route_policies
  end

  test "R8a another tenant's count is a plain 404 and stays unchanged", ctx do
    _a = world!(ctx, :a)
    b = world!(ctx, :b)
    value = code!(b.s, "catalog_item", b.m.item)
    unknown = scan(b, Ecto.UUID.generate(), ctx.tok_a, body(b, value))
    got = scan(b, b.id, ctx.tok_a, body(b, value))
    assert got.status == 404 and strip(got) == strip(unknown)
    {:ok, page} = Counts.entries(b.s, b.id, %{}, %{actor_id: Ecto.UUID.generate(), scope: :all})
    assert page.rows == []
  end

  test "R8b a code that exists only in another tenant is code_unknown", ctx do
    a = world!(ctx, :a)
    b = world!(ctx, :b)
    only_b = code!(b.s, "catalog_item", b.m.item)
    assert scan(a, a.id, a.member_tok, body(a, only_b)).status == 404
  end

  test "R8c a caller granted another unit gets the unknown-id 404", ctx do
    t = S.tenant!("scanr-s", Map.fetch!(ctx.names, :s))
    s = t.schema_name
    wx = F.world!(s)
    wy = F.world!(s)
    opts = %{actor_id: Ecto.UUID.generate(), scope: :all}
    {:ok, oy} = Counts.create(s, F.input(wy, window()), opts)
    tok = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-scan")
    status!(call(:get, "/counts", tok), 200)
    user = Repo.one!(from(u in User, where: u.username == "scoped-scan"), prefix: s)
    group = RSG.group_of!(s, "TENANT_ADMIN")
    _ = RSG.raw_delete_rows!(s, group, "TENANT_ADMIN")
    :ok = RSG.raw_user_row!(s, user.id, "TENANT_ADMIN", wx.unit)

    b = %{"scanned_text" => "x", "location_id" => wy.a, "scan_id" => Ecto.UUID.generate()}
    got = call(:post, "/counts/#{oy["id"]}/scan", tok, b)
    want = call(:post, "/counts/#{Ecto.UUID.generate()}/scan", tok, b)
    assert got.status == 404 and strip(got) == strip(want)
  end

  test "R8d a role without StockCountRecord is forbidden", ctx do
    x = world!(ctx, :a)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-scan")
    assert scan(x, x.id, tok, body(x, "x")).status == 403
  end
end
