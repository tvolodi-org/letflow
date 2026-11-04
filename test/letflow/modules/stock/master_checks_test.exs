Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.MasterChecksTest do
  @moduledoc """
  REQ-712 / GH #3749 criterion 5 (A-MC-1..7): the master checks of the issue step, one test per reason
  with real master records written through their owners' paths, the order of the checks, and that a
  failed check leaves a draft with no number taken. Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a])
    a = S.tenant!("stk-mc", ctx.names.a)
    Map.merge(ctx, %{a: a, m: D.masters!(a.schema_name), tok: S.token(ctx, :a, ["TENANT_ADMIN"])})
  end

  defp issue(ctx, body) do
    doc = D.request(:post, "/documents", ctx.tok, body)
    assert doc.status == 201, doc.resp_body
    id = S.json(doc)["id"]
    {id, D.request(:post, "/documents/#{id}/issue", ctx.tok)}
  end

  defp refused(ctx, body, reason, extra \\ %{}) do
    {id, conn} = issue(ctx, body)
    assert conn.status == 422, conn.resp_body
    json = S.json(conn)
    assert json["reason"] == reason
    for {k, v} <- extra, do: assert(json[k] == v)

    assert D.request(:get, "/documents/#{id}", ctx.tok) |> S.json() |> Map.get("state") == "draft"
    id
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  test "A-MC-1 not_linked: an unlinked location, a retired unit, a retired location", ctx do
    m = ctx.m
    s = ctx.a.schema_name

    {:ok, other} =
      Locations.create_node(s, %{"code" => "X1", "name" => "x", "node_kind" => "zone"}, opts())

    refused(ctx, D.body(m, nil, %{"location_id" => other["record_id"]}), "not_linked")

    {:ok, _} = Locations.retire_node(s, m.location, opts())
    refused(ctx, D.body(m), "not_linked")
  end

  test "A-MC-1b not_linked for a retired org unit", ctx do
    s = ctx.a.schema_name
    m = ctx.m
    unit = D.unit!(s)
    {:ok, _} = Locations.link_unit_location(s, unit, m.location, opts())

    saved = D.request(:post, "/documents", ctx.tok, D.body(m, nil, %{"org_unit_id" => unit}))
    assert saved.status == 201, saved.resp_body
    id = S.json(saved)["id"]

    {:ok, _} = Org.retire_unit(s, unit, opts())
    conn = D.request(:post, "/documents/#{id}/issue", ctx.tok)
    assert conn.status == 422 and S.json(conn)["reason"] == "not_linked"
  end

  test "A-MC-2 employee_not_active: an inactive employee and an unknown one", ctx do
    m = ctx.m
    s = ctx.a.schema_name

    inactive =
      OrgFixture.create!(
        s,
        "org_employee",
        OrgFixture.values("org_employee", "EX#{System.unique_integer([:positive])}", %{
          "org_unit_id" => m.unit,
          "active" => false
        })
      )

    refused(ctx, D.body(m, nil, %{"responsible_id" => inactive.record_id}), "employee_not_active")

    refused(
      ctx,
      D.body(m, nil, %{"responsible_id" => Ecto.UUID.generate()}),
      "employee_not_active"
    )
  end

  test "A-MC-3 counterparty_not_active: an item as counterparty and an inactive supplier", ctx do
    m = ctx.m
    s = ctx.a.schema_name
    refused(ctx, D.body(m, nil, %{"counterparty_id" => m.item}), "counterparty_not_active")

    sup = Letflow.Repo.get_by!(Letflow.Entities.Record.Latest, [record_id: m.supplier], prefix: s)
    Cat.update!(s, sup, Map.put(sup.field_values, "active", false))
    refused(ctx, D.body(m), "counterparty_not_active")
  end

  test "A-MC-4 unit_not_valid with the line number", ctx do
    m = ctx.m
    other_uom = Cat.uom!(ctx.a.schema_name, "KG#{System.unique_integer([:positive])}")
    good = %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "1"}
    bad = %{good | "catalog_uom_id" => other_uom.record_id}
    refused(ctx, D.body(m, nil, %{"lines" => [good, bad]}), "unit_not_valid", %{"line_no" => 2})
  end

  test "A-MC-5 lot_not_valid with the line number: a lot of another item", ctx do
    m = ctx.m
    s = ctx.a.schema_name
    item2 = Cat.item!(s, "I2#{System.unique_integer([:positive])}", m.uom)
    lot2 = Cat.lot!(s, item2.record_id, "LOT2#{System.unique_integer([:positive])}")

    line = %{
      "catalog_item_id" => m.item,
      "catalog_uom_id" => m.uom,
      "catalog_lot_id" => lot2.record_id,
      "quantity" => "1"
    }

    refused(ctx, D.body(m, nil, %{"lines" => [line]}), "lot_not_valid", %{"line_no" => 1})
  end

  test "A-MC-6 the first failure in the entry's order wins", ctx do
    m = ctx.m
    other_uom = Cat.uom!(ctx.a.schema_name, "KG#{System.unique_integer([:positive])}")

    line = %{
      "catalog_item_id" => m.item,
      "catalog_uom_id" => other_uom.record_id,
      "quantity" => "1"
    }

    body = D.body(m, nil, %{"responsible_id" => Ecto.UUID.generate(), "lines" => [line]})
    refused(ctx, body, "employee_not_active")

    body = D.body(m, nil, %{"counterparty_id" => m.item, "lines" => [line]})
    refused(ctx, body, "counterparty_not_active")
  end

  test "A-MC-7 failed checks take no number: the next good issue is number 1", ctx do
    refused(
      ctx,
      D.body(ctx.m, nil, %{"responsible_id" => Ecto.UUID.generate()}),
      "employee_not_active"
    )

    {_id, conn} = issue(ctx, D.body(ctx.m))
    assert conn.status == 200
    assert S.json(conn)["number"] =~ ~r/-000001\z/
  end
end
