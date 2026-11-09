Code.require_file("count_freeze_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountFreezeRouterTest do
  @moduledoc """
  REQ-765 / GH #3906 criteria 7 and 8 (F23 to F27): the freeze fields of the count view and the route `GET
  /frozen-locations` through the full `Letflow.Router` with real OIDC bearer tokens, and the tenancy and scope
  of the guard and the list (INV-1, INV-2, INV-5, INV-10). Committed tenants in Sandbox `:auto` mode,
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.CountFreezeFixture, as: C
  alias Letflow.CountsFixture, as: F
  alias Letflow.Identity.User
  alias Letflow.Modules.Stock.FreezeGuard
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = S.setup_oidc!([:a, :b])
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp frozen(x, query \\ ""),
    do: C.call(:get, "/frozen-locations" <> query, x.chair_tok) |> C.status!(200)

  defp iso_utc?(text) do
    match?({:ok, %DateTime{utc_offset: 0}, 0}, DateTime.from_iso8601(text))
  end

  test "F23 the count view and list answer the six freeze fields, computed and in ISO 8601 UTC",
       ctx do
    x = C.world!(ctx, :a)
    plain = C.ordered!(x, %{"location_ids" => [x.w.b]})
    p = C.count(x, plain)

    for k <-
          ~w(freeze_state freeze_started_at freeze_until freeze_ended_at freeze_end_reason freeze_locations) do
      assert Map.has_key?(p, k), "missing #{k}"
    end

    assert p["freeze_locations"] == false and p["freeze_state"] == "none"
    assert p["freeze_started_at"] == nil and p["freeze_until"] == nil

    id = C.frozen!(x)
    v = C.count(x, id)
    assert v["freeze_locations"] == true and v["freeze_state"] == "active"
    assert iso_utc?(v["freeze_started_at"]) and iso_utc?(v["freeze_until"])
    assert v["freeze_ended_at"] == nil and v["freeze_end_reason"] == nil

    listed = C.status!(C.call(:get, "/counts", x.chair_tok), 200)["rows"]
    assert Enum.find(listed, &(&1["id"] == id))["freeze_state"] == "active"

    C.cancel!(x, id)
    v = C.count(x, id)
    assert v["freeze_state"] == "ended" and v["freeze_end_reason"] == "cancelled"
    assert iso_utc?(v["freeze_ended_at"])
  end

  test "F24 frozen-locations: exact keys, order, location_id filter, limit and cursor, bad query refused",
       ctx do
    x = C.world!(ctx, :a)
    assert frozen(x) == %{"rows" => [], "next_cursor" => nil}

    id = C.frozen!(x)
    number = C.count(x, id)["number"]
    all = frozen(x)["rows"]
    assert length(all) == 3
    assert all == Enum.sort_by(all, & &1["location_id"])

    for row <- all do
      assert Map.keys(row) |> Enum.sort() ==
               ~w(count_number count_order_id freeze_until location_id org_unit_id)

      assert row["count_order_id"] == id and row["count_number"] == number
      assert row["org_unit_id"] == x.w.unit and iso_utc?(row["freeze_until"])
    end

    assert Enum.sort(Enum.map(all, & &1["location_id"])) == Enum.sort([x.w.a, x.w.a1, x.w.a11])
    assert [%{"location_id" => loc}] = frozen(x, "?location_id=#{x.w.a1}")["rows"]
    assert loc == x.w.a1
    assert frozen(x, "?location_id=#{x.w.b}")["rows"] == []

    first = frozen(x, "?limit=2")
    assert length(first["rows"]) == 2 and is_binary(first["next_cursor"])
    second = frozen(x, "?limit=2&cursor=#{first["next_cursor"]}")
    assert length(second["rows"]) == 1 and second["next_cursor"] == nil
    assert first["rows"] ++ second["rows"] == all

    for bad <- ["?bogus=1", "?limit=0", "?limit=201", "?location_id=nope", "?cursor=nope"] do
      assert C.call(:get, "/frozen-locations" <> bad, x.chair_tok).status == 422, bad
    end

    C.cancel!(x, id)
    assert frozen(x)["rows"] == []
  end

  test "F25 a freeze of tenant B never refuses tenant A and is not in A's list (same keys in both)",
       ctx do
    a = C.world!(ctx, :a)
    b = C.world!(ctx, :b)
    id = C.frozen!(b)
    number = C.count(b, id)["number"]

    key = %{"sku" => S.uuid(), "location" => b.w.a1, "org_unit" => b.w.unit}

    summary = %{
      ledger_id: "stock",
      cause: "receipt",
      document_type: "stock_receipt",
      document_id: S.uuid(),
      keys: [key]
    }

    assert FreezeGuard.check(b.s, summary) == {:held, number}
    # the very same keys against tenant A's schema: nothing frozen there
    assert FreezeGuard.check(a.s, summary) == :ok
    assert frozen(a)["rows"] == []
    assert length(frozen(b)["rows"]) == 3

    C.receive!(a, a.ma, "3")
  end

  defp scoped_caller!(ctx, name, x, unit) do
    tok = S.token(ctx, name, ["TENANT_ADMIN"], sub: "scoped-freeze")
    C.status!(C.call(:get, "/counts", tok), 200)
    user = Repo.one!(from(u in User, where: u.username == "scoped-freeze"), prefix: x.s)
    group = RSG.group_of!(x.s, "TENANT_ADMIN")
    _ = RSG.raw_delete_rows!(x.s, group, "TENANT_ADMIN")
    :ok = RSG.raw_user_row!(x.s, user.id, "TENANT_ADMIN", unit)
    tok
  end

  test "F26 a caller scoped to unit X sees X's frozen locations only and gets 404 for Y's count",
       ctx do
    x = C.world!(ctx, :a)
    x_id = C.frozen!(x)

    # a second unit Y with its own chair (a second real user) and its own frozen order
    wy = F.world!(x.s)
    y_tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "chair-y")
    C.status!(C.call(:get, "/counts", y_tok), 200)
    y_user = Repo.one!(from(u in User, where: u.username == "chair-y"), prefix: x.s)
    wy = %{wy | chair: F.employee!(x.s, wy.unit, user: y_user.id)}
    y_input = F.input(wy, Map.merge(C.window(), %{"freeze_locations" => true}))
    y_id = C.status!(C.call(:post, "/counts", y_tok, y_input), 201)["id"]
    C.status!(C.call(:post, "/counts/#{y_id}/issue", y_tok, %{}), 200)
    C.status!(C.call(:post, "/counts/#{y_id}/open", y_tok, %{}), 200)

    assert length(frozen(x)["rows"]) == 6

    tok = scoped_caller!(ctx, :a, x, x.w.unit)
    rows = C.call(:get, "/frozen-locations", tok) |> C.status!(200) |> Map.fetch!("rows")
    assert length(rows) == 3 and Enum.all?(rows, &(&1["org_unit_id"] == x.w.unit))
    assert Enum.all?(rows, &(&1["count_order_id"] == x_id))

    unknown = C.call(:get, "/counts/#{Ecto.UUID.generate()}", tok)
    assert unknown.status == 404
    conn = C.call(:get, "/counts/#{y_id}", tok)
    assert conn.status == 404
    assert Map.delete(S.json(conn), "trace_id") == Map.delete(S.json(unknown), "trace_id")
    assert C.call(:get, "/counts/#{x_id}", tok).status == 200
  end

  test "F27 a caller without StockRead is forbidden on the route", ctx do
    x = C.world!(ctx, :a)
    tok = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")
    assert C.call(:get, "/frozen-locations", tok).status == 403
    assert C.call(:get, "/frozen-locations", x.chair_tok).status == 200
  end
end
