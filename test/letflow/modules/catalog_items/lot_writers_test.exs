Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.LotWritersTest do
  @moduledoc """
  GH #3614 / REQ-664 (tests W-01..W-15): the lot writers `create_lot/3`, `update_lot/4` and
  `retire_lot/3` of `catalog_items`, on real provisioned tenants. W-13 (audit failure) and W-16
  (concurrency) are not forced: they need DDL or a race.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.CatalogItems

  import Letflow.CatalogItemsFixture, except: [values: 3]

  @type_name "catalog_lot"
  @non_uuids [nil, 123, "x", "", %{}, [], :atom, 1.5, "not-a-uuid"]

  setup do
    ctx = installed_tenant!("gh3614-lot")
    uom = uom!(ctx.schema, "WU")
    item = item!(ctx.schema, "WI", uom.record_id)
    {:ok, Map.merge(ctx, %{uom: uom, item: item})}
  end

  defp opts(key \\ nil),
    do: %{actor_id: Ecto.UUID.generate(), idempotency_key: key || Ecto.UUID.generate()}

  defp lot_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^@type_name), :count,
        prefix: schema
      )

  defp audit_rows(schema) do
    Repo.all(
      from(e in Audit.Entry, where: like(e.action, "catalog_lot.%"), order_by: e.timestamp),
      prefix: schema
    )
  end

  defp assert_refused(ctx, expected, fun) do
    before_lots = lot_count(ctx.schema)
    before_audit = length(audit_rows(ctx.schema))
    assert fun.() == expected
    assert lot_count(ctx.schema) == before_lots
    assert length(audit_rows(ctx.schema)) == before_audit
  end

  test "W-01 create gives a valid lot, retire makes it invalid", ctx do
    {:ok, lot} =
      CatalogItems.create_lot(
        ctx.schema,
        %{
          "item_id" => ctx.item.record_id,
          "code" => "L1",
          "producer" => "P",
          "expiry_date" => "2027-01-31"
        },
        opts()
      )

    assert lot["entity_type"] == @type_name
    assert lot["active"] == true
    assert lot["code"] == "L1"
    assert CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, lot["record_id"])

    assert {:ok, %{"active" => false}} =
             CatalogItems.retire_lot(ctx.schema, lot["record_id"], opts())

    refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, lot["record_id"])
  end

  test "W-02 update changes the optional fields, nil clears", ctx do
    {:ok, lot} =
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => ctx.item.record_id, "code" => "L2", "producer" => "P", "mark" => "M"},
        opts()
      )

    attrs = %{
      "producer" => "Q",
      "mark" => nil,
      "expiry_date" => "2028-02-29",
      "external_ref_system" => "erp",
      "external_ref_id" => "7"
    }

    assert {:ok, up} = CatalogItems.update_lot(ctx.schema, lot["record_id"], attrs, opts())
    assert up["producer"] == "Q"
    refute Map.has_key?(up, "mark")
    assert up["expiry_date"] == "2028-02-29"
    assert up["external_ref_id"] == "7"
    assert up["code"] == "L2"
    assert up["item_id"] == ctx.item.record_id
    assert up["active"] == true
  end

  test "W-03 item refusals", ctx do
    for bad <- @non_uuids do
      assert_refused(ctx, {:error, :item_not_found}, fn ->
        CatalogItems.create_lot(ctx.schema, %{"item_id" => bad, "code" => "X"}, opts())
      end)
    end

    assert_refused(ctx, {:error, :item_not_found}, fn ->
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => Ecto.UUID.generate(), "code" => "X"},
        opts()
      )
    end)

    assert_refused(ctx, {:error, :item_not_found}, fn ->
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => ctx.uom.record_id, "code" => "X"},
        opts()
      )
    end)

    gone = item!(ctx.schema, "WGONE", ctx.uom.record_id)
    delete!(ctx.schema, gone)

    assert_refused(ctx, {:error, :item_not_found}, fn ->
      CatalogItems.create_lot(ctx.schema, %{"item_id" => gone.record_id, "code" => "X"}, opts())
    end)

    retired = item!(ctx.schema, "WRET", ctx.uom.record_id, %{"active" => false})

    assert_refused(ctx, {:error, :item_inactive}, fn ->
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => retired.record_id, "code" => "X"},
        opts()
      )
    end)
  end

  test "W-04 code refusals", ctx do
    for bad <- [nil, "", "  ", 5, %{}] do
      attrs = %{"item_id" => ctx.item.record_id, "code" => bad}

      assert_refused(ctx, {:error, {:field_invalid, "code"}}, fn ->
        CatalogItems.create_lot(ctx.schema, attrs, opts())
      end)
    end

    assert_refused(ctx, {:error, {:field_invalid, "code"}}, fn ->
      CatalogItems.create_lot(ctx.schema, %{"item_id" => ctx.item.record_id}, opts())
    end)
  end

  test "W-05 expiry date refusals", ctx do
    for bad <- ["2026-02-30", "31.12.2026", "20261231", 12345, "2026-1-1"] do
      attrs = %{"item_id" => ctx.item.record_id, "code" => "D", "expiry_date" => bad}

      assert_refused(ctx, {:error, {:field_invalid, "expiry_date"}}, fn ->
        CatalogItems.create_lot(ctx.schema, attrs, opts())
      end)
    end

    {:ok, lot} =
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => ctx.item.record_id, "code" => "D"},
        opts()
      )

    assert_refused(ctx, {:error, {:field_invalid, "expiry_date"}}, fn ->
      CatalogItems.update_lot(
        ctx.schema,
        lot["record_id"],
        %{"expiry_date" => "2026-02-30"},
        opts()
      )
    end)

    assert_refused(ctx, {:error, {:field_invalid, "producer"}}, fn ->
      CatalogItems.update_lot(ctx.schema, lot["record_id"], %{"producer" => 5}, opts())
    end)
  end

  test "W-06 one code per item", ctx do
    other = item!(ctx.schema, "WI2", ctx.uom.record_id)
    attrs = %{"item_id" => ctx.item.record_id, "code" => "SAME"}
    assert {:ok, _} = CatalogItems.create_lot(ctx.schema, attrs, opts())

    before_audit = length(audit_rows(ctx.schema))

    assert {:error, {:record_payload_invalid, _}} =
             CatalogItems.create_lot(ctx.schema, attrs, opts())

    assert lot_count(ctx.schema) == 1
    assert length(audit_rows(ctx.schema)) == before_audit

    assert {:ok, _} =
             CatalogItems.create_lot(
               ctx.schema,
               %{"item_id" => other.record_id, "code" => "SAME"},
               opts()
             )

    assert lot_count(ctx.schema) == 2
  end

  test "W-07 update refuses fixed fields and unknown keys", ctx do
    {:ok, lot} =
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => ctx.item.record_id, "code" => "F"},
        opts()
      )

    for key <- ["item_id", "code", "active", "bogus"] do
      assert_refused(ctx, {:error, {:field_not_allowed, key}}, fn ->
        CatalogItems.update_lot(ctx.schema, lot["record_id"], %{key => "x"}, opts())
      end)
    end

    assert_refused(ctx, {:error, {:field_not_allowed, "active"}}, fn ->
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => ctx.item.record_id, "code" => "G", "active" => false},
        opts()
      )
    end)
  end

  test "W-08 unknown lot", ctx do
    for id <- [Ecto.UUID.generate(), ctx.item.record_id, "x", nil, 5] do
      assert_refused(ctx, {:error, :lot_not_found}, fn ->
        CatalogItems.update_lot(ctx.schema, id, %{"mark" => "m"}, opts())
      end)

      assert_refused(ctx, {:error, :lot_not_found}, fn ->
        CatalogItems.retire_lot(ctx.schema, id, opts())
      end)
    end
  end

  test "W-10 an uppercase item uuid is stored lowercase", ctx do
    upper = String.upcase(ctx.item.record_id)
    {:ok, lot} = CatalogItems.create_lot(ctx.schema, %{"item_id" => upper, "code" => "U"}, opts())
    assert lot["item_id"] == ctx.item.record_id
    assert CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, lot["record_id"])
  end

  test "W-11 one audit entry per accepted change", ctx do
    o1 = opts()

    {:ok, lot} =
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => ctx.item.record_id, "code" => "A", "mark" => "m"},
        o1
      )

    o2 = opts()
    {:ok, _} = CatalogItems.update_lot(ctx.schema, lot["record_id"], %{"mark" => "n"}, o2)
    o3 = opts()
    {:ok, _} = CatalogItems.retire_lot(ctx.schema, lot["record_id"], o3)
    # retiring a retired lot: no write, no entry
    {:ok, %{"active" => false}} = CatalogItems.retire_lot(ctx.schema, lot["record_id"], opts())

    assert [c, u, r] = audit_rows(ctx.schema)

    assert {c.action, u.action, r.action} ==
             {"catalog_lot.created", "catalog_lot.updated", "catalog_lot.retired"}

    assert c.actor_id == o1.actor_id and u.actor_id == o2.actor_id and r.actor_id == o3.actor_id

    assert Enum.all?(
             [c, u, r],
             &(&1.resource_type == @type_name and &1.resource_id == lot["record_id"])
           )

    assert c.before_state == nil
    assert c.after_state["code"] == "A"
    assert u.before_state["mark"] == "m" and u.after_state["mark"] == "n"
    assert r.before_state["active"] == true and r.after_state["active"] == false
  end

  test "W-12 replay with the same key returns the original, other input is refused", ctx do
    attrs = %{"item_id" => ctx.item.record_id, "code" => "R", "mark" => "a"}
    o = opts()
    {:ok, lot} = CatalogItems.create_lot(ctx.schema, attrs, o)
    assert {:ok, ^lot} = CatalogItems.create_lot(ctx.schema, attrs, o)
    assert lot_count(ctx.schema) == 1
    assert length(audit_rows(ctx.schema)) == 1

    assert {:error, _} = CatalogItems.create_lot(ctx.schema, Map.put(attrs, "mark", "b"), o)
    assert lot_count(ctx.schema) == 1

    ou = opts()
    {:ok, up} = CatalogItems.update_lot(ctx.schema, lot["record_id"], %{"mark" => "z"}, ou)

    assert {:ok, ^up} =
             CatalogItems.update_lot(ctx.schema, lot["record_id"], %{"mark" => "z"}, ou)

    assert {:error, _} =
             CatalogItems.update_lot(ctx.schema, lot["record_id"], %{"mark" => "y"}, ou)

    orr = opts()
    {:ok, ret} = CatalogItems.retire_lot(ctx.schema, lot["record_id"], orr)
    assert {:ok, ^ret} = CatalogItems.retire_lot(ctx.schema, lot["record_id"], orr)

    assert length(audit_rows(ctx.schema)) == 3
  end

  test "W-14 another tenant sees nothing", ctx do
    other = installed_tenant!("gh3614-lotb")

    {:ok, lot} =
      CatalogItems.create_lot(
        ctx.schema,
        %{"item_id" => ctx.item.record_id, "code" => "T"},
        opts()
      )

    assert {:error, :item_not_found} =
             CatalogItems.create_lot(
               other.schema,
               %{"item_id" => ctx.item.record_id, "code" => "T"},
               opts()
             )

    assert {:error, :lot_not_found} =
             CatalogItems.update_lot(other.schema, lot["record_id"], %{"mark" => "x"}, opts())

    assert {:error, :lot_not_found} =
             CatalogItems.retire_lot(other.schema, lot["record_id"], opts())

    assert lot_count(other.schema) == 0
    assert audit_rows(other.schema) == []

    assert {:ok, %{"active" => true, "mark" => nil}} =
             {:ok,
              Map.merge(
                %{"mark" => nil},
                elem(CatalogItems.lookup(ctx.schema, lot["record_id"]), 1)
              )}

    for {name, arity} <- [create_lot: 3, update_lot: 4, retire_lot: 3],
        do: assert(function_exported?(CatalogItems, name, arity))

    for {name, arity} <- [create_lot: 4, update_lot: 5, retire_lot: 4],
        do: refute(function_exported?(CatalogItems, name, arity))
  end

  test "W-15 opts are programmer input", ctx do
    assert_raise ArgumentError, fn -> CatalogItems.create_lot(ctx.schema, %{}, %{}) end
    assert {:error, {:field_invalid, "attrs"}} = CatalogItems.create_lot(ctx.schema, "x", opts())
  end
end
