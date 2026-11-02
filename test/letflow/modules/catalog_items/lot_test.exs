Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.LotTest do
  @moduledoc """
  GH #3593 / REQ-647 (tests L-01..L-17): the lot master `catalog_lot` of the `catalog_items`
  module, its read API and `item_lot_valid?/3`, on a real provisioned tenant.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.CatalogItems

  import Letflow.CatalogItemsFixture, except: [values: 3]

  defp values(type, code, extra \\ %{}), do: Letflow.CatalogItemsFixture.values(type, code, extra)

  @type_name "catalog_lot"
  @trace "gh3593-lot-fixed-trace"
  @entities_opts Letflow.Routers.Entities.init([])
  @runbook Path.expand("../../../../docs/runbooks/wms-foundation.md", __DIR__)

  @non_uuids [nil, 123, "x", "", %{}, %{"a" => 1}, [], :atom, 1.5, "not-a-uuid", <<255>>]

  setup do
    ctx = installed_tenant!("gh3593-lot")
    uom = uom!(ctx.schema, "LU")
    item = item!(ctx.schema, "LI", uom.record_id)
    {:ok, Map.merge(ctx, %{uom: uom, item: item})}
  end

  defp lot_vals(item, code, extra \\ %{}),
    do: values(@type_name, code, Map.merge(%{"item_id" => item.record_id}, extra))

  defp lot_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^@type_name), :count,
        prefix: schema
      )

  defp call_entities(tenant_id, method, path, body) do
    Plug.Test.conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant_id,
      roles: ["TENANT_ADMIN"]
    })
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  # The write either returns or raises; report which, never let a raise fail the test.
  defp observe(fun) do
    {:returned, fun.()}
  rescue
    e -> {:raised, e}
  end

  describe "criteria 3 and 4: definition-level rules through the owner path" do
    test "L-01: a lot with item_id, code and active only is stored", %{schema: schema, item: item} do
      assert {:ok, %{record: rec}} = create(schema, @type_name, lot_vals(item, "A-1"))
      assert rec.field_values["item_id"] == item.record_id
      refute Map.has_key?(rec.field_values, "expiry_date")
      assert lot_count(schema) == 1
    end

    test "L-02: all fields are stored, the expiry date as the given date", %{
      schema: schema,
      item: item
    } do
      rec =
        lot!(schema, item.record_id, "A-2", %{
          "producer" => "Dairy Ltd",
          "mark" => "Premium",
          "expiry_date" => "2027-03-31",
          "external_ref_system" => "1c",
          "external_ref_id" => "9"
        })

      assert {:ok, map} = CatalogItems.lookup(schema, rec.record_id)
      assert map["producer"] == "Dairy Ltd"
      assert map["mark"] == "Premium"
      assert map["expiry_date"] == "2027-03-31"

      %{rows: [[date]]} =
        Repo.query!(
          "SELECT expiry_date FROM #{schema}.entity_catalog_lot WHERE record_id = $1",
          [Ecto.UUID.dump!(rec.record_id)]
        )

      assert date == ~D[2027-03-31]
    end

    test "L-03: a duplicate item_id + code is refused with a unique violation", %{
      schema: schema,
      item: item
    } do
      assert {:ok, _} = create(schema, @type_name, lot_vals(item, "D-1"))

      assert {:error, {:record_payload_invalid, [violation]}} =
               create(schema, @type_name, lot_vals(item, "D-1", %{"mark" => "other"}))

      assert %Violation{rule: :unique, path: ["item_id", "code"]} = violation
      assert lot_count(schema) == 1
    end

    test "L-04: the same code for another item is accepted", %{
      schema: schema,
      item: item,
      uom: uom
    } do
      other = item!(schema, "LI-2", uom.record_id)
      assert {:ok, _} = create(schema, @type_name, lot_vals(item, "SAME"))
      assert {:ok, _} = create(schema, @type_name, lot_vals(other, "SAME"))
      assert lot_count(schema) == 2
    end

    test "L-05/06/07: each missing required field is refused naming the field", %{
      schema: schema,
      item: item
    } do
      for field <- ["item_id", "code", "active"] do
        vals = Map.delete(lot_vals(item, "M-#{field}"), field)

        assert {:error, {:record_payload_invalid, violations}} =
                 create(schema, @type_name, vals),
               "missing #{field} was accepted"

        assert Enum.any?(violations, &(&1.field_path == "/" <> field)),
               "#{field}: #{inspect(violations)}"
      end

      assert lot_count(schema) == 0
    end

    test "L-08: the same non-null external_ref pair is refused, null pairs pass", %{
      schema: schema,
      item: item
    } do
      ref = %{"external_ref_system" => "1c", "external_ref_id" => "42"}
      assert {:ok, _} = create(schema, @type_name, lot_vals(item, "R-1", ref))

      assert {:error, {:record_payload_invalid, [violation]}} =
               create(schema, @type_name, lot_vals(item, "R-2", ref))

      assert %Violation{rule: :unique, path: ["external_ref_system", "external_ref_id"]} =
               violation

      for n <- 1..2, do: assert({:ok, _} = create(schema, @type_name, lot_vals(item, "N-#{n}")))
      assert lot_count(schema) == 3
    end

    test "L-09: a well-formed item uuid naming no item is refused and nothing is stored", %{
      schema: schema
    } do
      result =
        observe(fn ->
          create(
            schema,
            @type_name,
            values(@type_name, "U-1", %{"item_id" => Ecto.UUID.generate()})
          )
        end)

      IO.puts("L-09 observed (unknown item uuid): #{inspect(result, limit: 8)}")
      assert lot_count(schema) == 0
      refute match?({:returned, {:ok, _}}, result)
    end

    test "L-10: a non-uuid item_id stores nothing (observed answer printed)", %{schema: schema} do
      result =
        observe(fn ->
          create(schema, @type_name, values(@type_name, "U-2", %{"item_id" => "not-a-uuid"}))
        end)

      IO.puts("L-10 observed (non-uuid item_id): #{inspect(result, limit: 8)}")
      assert lot_count(schema) == 0
      refute match?({:returned, {:ok, _}}, result)
    end

    test "L-14: a malformed expiry date 2027-02-30 stores nothing (observed answer printed)", %{
      schema: schema,
      item: item
    } do
      result =
        observe(fn ->
          create(schema, @type_name, lot_vals(item, "U-3", %{"expiry_date" => "2027-02-30"}))
        end)

      IO.puts("L-14 observed (expiry 2027-02-30): #{inspect(result, limit: 8)}")
      assert lot_count(schema) == 0
      refute match?({:returned, {:ok, _}}, result)
    end
  end

  describe "criterion 5: retire is active false, never a delete" do
    test "L-11: a retired lot stays readable, is not active?, the generic delete is refused", %{
      schema: schema,
      tenant_id: tenant_id,
      item: item
    } do
      rec = lot!(schema, item.record_id, "RET-1", %{"producer" => "P"})
      assert CatalogItems.active?(schema, rec.record_id)

      update!(schema, rec, lot_vals(item, "RET-1", %{"producer" => "P", "active" => false}))

      assert {:ok, %{"active" => false, "code" => "RET-1"}} =
               CatalogItems.lookup(schema, rec.record_id)

      assert CatalogItems.active?(schema, rec.record_id) == false

      conn = call_entities(tenant_id, :delete, "/records/#{@type_name}/#{rec.record_id}", %{})
      assert conn.status == 403, conn.resp_body
      assert conn.resp_body == Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})

      for name <- [:delete, :delete_lot, :remove, :destroy] do
        refute function_exported?(CatalogItems, name, 2)
        refute function_exported?(CatalogItems, name, 3)
      end
    end
  end

  describe "criterion 6: lookup/2 and active?/2 return lots" do
    test "L-12: lookup returns the lot map; the other three types still resolve", %{
      schema: schema,
      item: item,
      uom: uom
    } do
      rec = lot!(schema, item.record_id, "LK-1", %{"expiry_date" => "2027-01-01"})

      assert {:ok, map} = CatalogItems.lookup(schema, rec.record_id)
      assert map["record_id"] == rec.record_id
      assert map["entity_type"] == @type_name
      assert map["item_id"] == item.record_id
      assert map["code"] == "LK-1"
      assert map["expiry_date"] == "2027-01-01"
      assert map["active"] == true
      assert CatalogItems.active?(schema, rec.record_id) == true
      assert CatalogItems.active?(schema, Ecto.UUID.generate()) == false

      cp = counterparty!(schema, "LK-C")

      for {id, type} <- [
            {uom.record_id, "catalog_uom"},
            {item.record_id, "catalog_item"},
            {cp.record_id, "catalog_counterparty"}
          ] do
        assert {:ok, %{"entity_type" => ^type}} = CatalogItems.lookup(schema, id)
      end
    end
  end

  describe "criterion 7: item_lot_valid?/3" do
    setup %{schema: schema, item: item} do
      {:ok, lot: lot!(schema, item.record_id, "V-1")}
    end

    test "L-13a: true for an active item and its active lot", ctx do
      assert CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, ctx.lot.record_id)

      # canonical text: an upper-case argument is cast, the stored text compares equal
      assert CatalogItems.item_lot_valid?(
               ctx.schema,
               String.upcase(ctx.item.record_id),
               String.upcase(ctx.lot.record_id)
             )
    end

    test "L-13b: false for a lot of another item", ctx do
      other = item!(ctx.schema, "V-OTHER", ctx.uom.record_id)
      refute CatalogItems.item_lot_valid?(ctx.schema, other.record_id, ctx.lot.record_id)
    end

    test "L-13c: false for a retired lot", ctx do
      update!(ctx.schema, ctx.lot, lot_vals(ctx.item, "V-1", %{"active" => false}))
      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, ctx.lot.record_id)
    end

    test "L-13d: false for a soft-deleted lot", ctx do
      delete!(ctx.schema, ctx.lot)
      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, ctx.lot.record_id)
    end

    test "L-13e: false for a retired item", ctx do
      update!(
        ctx.schema,
        ctx.item,
        values("catalog_item", "LI", %{"base_uom_id" => ctx.uom.record_id, "active" => false})
      )

      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, ctx.lot.record_id)
    end

    test "L-13f: false for an unknown item uuid and for an unknown lot uuid", ctx do
      refute CatalogItems.item_lot_valid?(ctx.schema, Ecto.UUID.generate(), ctx.lot.record_id)
      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, Ecto.UUID.generate())
    end

    test "L-13g: false when the lot id is a uom or a counterparty id", ctx do
      cp = counterparty!(ctx.schema, "V-CP")
      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, ctx.uom.record_id)
      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, cp.record_id)
      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, ctx.item.record_id)
    end

    test "L-13h: false when the item id is a lot id", ctx do
      refute CatalogItems.item_lot_valid?(ctx.schema, ctx.lot.record_id, ctx.lot.record_id)
    end

    test "L-13i: non-uuid values are false and never raise", ctx do
      for bad <- @non_uuids do
        refute CatalogItems.item_lot_valid?(ctx.schema, bad, ctx.lot.record_id), inspect(bad)
        refute CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, bad), inspect(bad)
      end
    end

    test "L-13j: a non-text prefix is false and never raises", ctx do
      for bad <- [nil, 5, :atom, %{}] do
        refute CatalogItems.item_lot_valid?(bad, ctx.item.record_id, ctx.lot.record_id)
      end
    end

    test "L-13k: the function reads only, the record count does not change", ctx do
      count = fn ->
        Repo.aggregate(
          from(l in Latest, where: l.entity_type in ["catalog_lot", "catalog_item"]),
          :count,
          prefix: ctx.schema
        )
      end

      before = count.()
      CatalogItems.item_lot_valid?(ctx.schema, ctx.item.record_id, ctx.lot.record_id)
      CatalogItems.item_lot_valid?(ctx.schema, "bad", "bad")
      assert count.() == before
    end
  end

  describe "criterion 8: tenant isolation (INV-1, INV-5, INV-10)" do
    test "L-15: tenant A's lot is not found with tenant B's prefix, same as an absent id", %{
      schema: schema_a,
      item: item
    } do
      b = installed_tenant!("gh3593-lot-b")
      rec = lot!(schema_a, item.record_id, "ISO-1")

      assert {:ok, %{"code" => "ISO-1"}} = CatalogItems.lookup(schema_a, rec.record_id)
      assert CatalogItems.lookup(b.schema, rec.record_id) == {:error, :not_found}

      assert CatalogItems.lookup(b.schema, rec.record_id) ==
               CatalogItems.lookup(b.schema, Ecto.UUID.generate())

      assert CatalogItems.active?(b.schema, rec.record_id) == false
      assert CatalogItems.item_lot_valid?(schema_a, item.record_id, rec.record_id)
      refute CatalogItems.item_lot_valid?(b.schema, item.record_id, rec.record_id)

      source =
        File.read!(
          Path.join([
            File.cwd!(),
            "lib",
            "letflow",
            "modules",
            "catalog_items",
            "catalog_items.ex"
          ])
        )

      refute source =~ "tenant_id"
    end
  end

  describe "criterion 2: the generic routes refuse the lot type" do
    test "L-16: create and import answer 403 entity_type_managed and write nothing", %{
      schema: schema,
      tenant_id: tenant_id,
      item: item
    } do
      expected = Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})
      vals = lot_vals(item, "IMP-1")

      conn =
        call_entities(tenant_id, :post, "/records/#{@type_name}", %{"field_values" => vals})

      assert conn.status == 403, conn.resp_body
      assert conn.resp_body == expected

      body = %{
        "record_export_schema_version" => "entities/record-export/v1",
        "entity_type" => @type_name,
        "records" => [%{"field_values" => vals}]
      }

      conn = call_entities(tenant_id, :post, "/records/#{@type_name}/import", body)
      assert conn.status == 403, conn.resp_body
      assert conn.resp_body == expected
      assert lot_count(schema) == 0
    end
  end

  describe "criterion 8: no permission, route or grant" do
    test "L-17: the manifest adds no permission, route policy or role grant" do
      manifest = CatalogItems.manifest()
      assert manifest.permissions == []
      assert manifest.route_policies == []
      assert manifest.role_grants == %{}
    end
  end

  describe "criterion 9: runbook" do
    test "B-lot: the runbook names the type, the check, and decisions D-065 and D-066" do
      text = File.read!(@runbook)

      for needle <- ["catalog_lot", "item_lot_valid?", "D-065", "D-066", "upgrade"] do
        assert text =~ needle, "runbook does not mention #{needle}"
      end
    end
  end
end
