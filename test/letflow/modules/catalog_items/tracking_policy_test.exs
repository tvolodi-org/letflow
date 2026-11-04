Code.require_file("catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Modules.CatalogItems.TrackingPolicyTest do
  @moduledoc """
  GH #3581 / REQ-641: the `tracking_policy` field of `catalog_item` (W-*, R-01) and the read-only
  `Letflow.Modules.CatalogItems.validate_capture/3` (V-*, E-*) on a real installed tenant.
  """

  use Letflow.DataCase, async: false

  import Letflow.CatalogItemsFixture

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.EventStore.Event
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.CatalogItems
  alias Letflow.Repo

  setup do
    ctx = installed_tenant!("gh3581-tp")
    uom = uom!(ctx.schema, "U-TP")
    {:ok, Map.put(ctx, :uom, uom)}
  end

  defp item_with(ctx, code, policy) do
    extra = if policy, do: %{"tracking_policy" => policy}, else: %{}
    item!(ctx.schema, code, ctx.uom.record_id, extra)
  end

  defp validate(ctx, item, capture),
    do: CatalogItems.validate_capture(ctx.schema, item.record_id, capture)

  describe "the field" do
    for policy <- ["none", "lot", "serial", "expiry"] do
      test "W-#{policy}: an item with policy #{policy} is stored and read back", ctx do
        policy = unquote(policy)
        item = item_with(ctx, "W-#{policy}", policy)
        assert item.field_values["tracking_policy"] == policy

        assert {:ok, %{"tracking_policy" => ^policy}} =
                 CatalogItems.lookup(ctx.schema, item.record_id)
      end
    end

    test "W-05/R-01: an item without the field is accepted and has no key", ctx do
      item = item_with(ctx, "W-none-key", nil)
      refute Map.has_key?(item.field_values, "tracking_policy")
      assert {:ok, map} = CatalogItems.lookup(ctx.schema, item.record_id)
      refute Map.has_key?(map, "tracking_policy")
    end

    test "W-06: a value outside the enum is refused naming the field", ctx do
      assert {:error, error} =
               create(
                 ctx.schema,
                 "catalog_item",
                 values("catalog_item", "W-bad", %{
                   "base_uom_id" => ctx.uom.record_id,
                   "tracking_policy" => "batch"
                 })
               )

      assert inspect(error) =~ "tracking_policy"
    end
  end

  describe "an existing tenant" do
    @json Path.join(
            :code.priv_dir(:letflow),
            "modules/catalog_items/entity_definitions/catalog_item.json"
          )

    test "I-04: activating the new definition keeps an old record readable", ctx do
      shipped =
        @json
        |> File.read!()
        |> Jason.decode!(keys: :atoms)
        |> Map.update!(:fields, fn fs ->
          Enum.map(fs, &Map.update!(&1, :type, fn t -> String.to_existing_atom(t) end))
        end)
        |> Map.update(:constraints, [], fn cs ->
          Enum.map(cs, &Map.update!(&1, :type, fn t -> String.to_existing_atom(t) end))
        end)

      old =
        Map.update!(shipped, :fields, fn fs ->
          Enum.reject(fs, &(&1.name == "tracking_policy"))
        end)

      actor = Ecto.UUID.generate()
      # the row the install wrote and activated: the shipped shape (this is "the new definition")
      {:ok, %{id: shipped_id}} = Definitions.get_definition_by_name("catalog_item", ctx.schema)

      # an older tenant: an earlier version without the field is the active one
      {:ok, _} =
        Definitions.create_definition(
          %{definition: old, created_by: actor},
          ctx.schema,
          owner()
        )

      assert {:ok, _} =
               Definitions.activate_definition(
                 "catalog_item",
                 actor,
                 "gh3581 I-04 old",
                 ctx.schema
               )

      item = item_with(ctx, "I-04", nil)
      refute Map.has_key?(item.field_values, "tracking_policy")

      # the module upgrade: the shipped row becomes the newest and is activated by name
      Repo.update_all(
        from(e in Letflow.Entities.EntityDefinition, where: e.id == ^shipped_id),
        [set: [inserted_at: DateTime.utc_now() |> DateTime.add(60)]],
        prefix: ctx.schema
      )

      assert {:ok, %{id: ^shipped_id}} =
               Definitions.activate_definition(
                 "catalog_item",
                 actor,
                 "gh3581 I-04 new",
                 ctx.schema
               )

      assert {:ok, map} = CatalogItems.lookup(ctx.schema, item.record_id)
      assert map["code"] == "I-04"
      refute Map.has_key?(map, "tracking_policy")
    end
  end

  describe "validate_capture/3 accepts" do
    test "V-01: none with an empty capture", ctx do
      assert :ok = validate(ctx, item_with(ctx, "V-1", "none"), %{})
    end

    test "V-02: none with only blank values", ctx do
      capture = %{"lot" => nil, "serial" => "", "expiry" => "   "}
      assert :ok = validate(ctx, item_with(ctx, "V-2", "none"), capture)
    end

    test "V-03: lot with a lot", ctx do
      assert :ok = validate(ctx, item_with(ctx, "V-3", "lot"), %{"lot" => "L1"})
    end

    test "V-04: serial with a serial", ctx do
      assert :ok = validate(ctx, item_with(ctx, "V-4", "serial"), %{"serial" => "S1"})
    end

    test "V-05: expiry with a lot and a date", ctx do
      capture = %{"lot" => "L1", "expiry" => "2027-03-31"}
      assert :ok = validate(ctx, item_with(ctx, "V-5", "expiry"), capture)
    end

    test "V-05b: an item with no stored policy behaves as none", ctx do
      item = item_with(ctx, "V-5b", nil)
      assert :ok = validate(ctx, item, %{})
      assert {:error, {:capture_not_allowed, "lot"}} = validate(ctx, item, %{"lot" => "L"})
    end
  end

  describe "validate_capture/3 refuses" do
    test "E-01..E-03: bad, unknown and deleted items are :item_not_found", ctx do
      assert {:error, :item_not_found} = CatalogItems.validate_capture(ctx.schema, "x", %{})

      assert {:error, :item_not_found} =
               CatalogItems.validate_capture(ctx.schema, Ecto.UUID.generate(), %{})

      assert {:error, :item_not_found} =
               CatalogItems.validate_capture(nil, ctx.uom.record_id, %{})

      # a record of another type is not an item
      assert {:error, :item_not_found} = validate(ctx, ctx.uom, %{})

      item = item_with(ctx, "E-3", "lot")
      delete!(ctx.schema, item)
      assert {:error, :item_not_found} = validate(ctx, item, %{"lot" => "L"})
    end

    test "E-04: an inactive item", ctx do
      item = item!(ctx.schema, "E-4", ctx.uom.record_id, %{"active" => false})
      assert {:error, :item_inactive} = validate(ctx, item, %{})
    end

    test "E-05: a capture that is not a map", ctx do
      item = item_with(ctx, "E-5", "none")
      assert {:error, :invalid_capture} = validate(ctx, item, [])
      assert {:error, :invalid_capture} = validate(ctx, item, nil)
    end

    test "E-06..E-09: required captures", ctx do
      lot = item_with(ctx, "E-6", "lot")
      serial = item_with(ctx, "E-7", "serial")
      expiry = item_with(ctx, "E-8", "expiry")

      assert {:error, {:capture_required, "lot"}} = validate(ctx, lot, %{})
      assert {:error, {:capture_required, "serial"}} = validate(ctx, serial, %{"serial" => "  "})
      assert {:error, {:capture_required, "expiry"}} = validate(ctx, expiry, %{"lot" => "L"})

      assert {:error, {:capture_required, "lot"}} =
               validate(ctx, expiry, %{"expiry" => "2027-03-31"})
    end

    test "E-10..E-12: values the policy does not allow", ctx do
      none = item_with(ctx, "E-10", "none")
      lot = item_with(ctx, "E-11", "lot")
      serial = item_with(ctx, "E-12", "serial")

      assert {:error, {:capture_not_allowed, "lot"}} = validate(ctx, none, %{"lot" => "L"})

      assert {:error, {:capture_not_allowed, "serial"}} =
               validate(ctx, lot, %{"lot" => "L", "serial" => "S"})

      assert {:error, {:capture_not_allowed, "lot"}} =
               validate(ctx, serial, %{"serial" => "S", "lot" => "L"})
    end

    test "E-13..E-15: invalid values", ctx do
      lot = item_with(ctx, "E-13", "lot")
      expiry = item_with(ctx, "E-14", "expiry")

      assert {:error, {:capture_invalid, "lot"}} = validate(ctx, lot, %{"lot" => 5})

      for bad <- ["31/03/2027", "2027-02-30", "2027-3-31", ~D[2027-03-31]] do
        assert {:error, {:capture_invalid, "expiry"}} =
                 validate(ctx, expiry, %{"lot" => "L", "expiry" => bad})
      end
    end

    test "E-16: lot is checked before expiry", ctx do
      expiry = item_with(ctx, "E-16", "expiry")
      assert {:error, {:capture_required, "lot"}} = validate(ctx, expiry, %{"expiry" => "bad"})
    end

    test "E-17: the check writes nothing", ctx do
      item = item_with(ctx, "E-17", "lot")
      before = counts(ctx.schema)
      assert :ok = validate(ctx, item, %{"lot" => "L"})
      assert {:error, {:capture_required, "lot"}} = validate(ctx, item, %{})
      assert counts(ctx.schema) == before
    end
  end

  defp counts(schema) do
    {Repo.aggregate(Latest, :count, prefix: schema),
     Repo.aggregate(Event, :count, prefix: schema)}
  end
end
