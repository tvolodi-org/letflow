Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.KindChangeFixture do
  @moduledoc """
  GH #3902 / REQ-759 (assets C15 part 2): masters and bodies of the change of kind tests. Builds on
  `Letflow.AssetsDocsFixture` (org unit, linked location, employees) and adds the stock side (unit of
  measure, an item without tracking, a lot-tracked item and its lot), a second place for the asset
  side, a location linked to the other unit only and an id that is not an org unit. A `.exs` file
  loaded with `Code.require_file/2`; callers are `async: false` (Sandbox `:auto`).
  """

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Modules.Org

  @doc "The masters of `schema`: the documents masters plus the stock and asset side ones."
  def masters!(schema) do
    n = System.unique_integer([:positive])
    base = D.masters!(schema)
    uom = Cat.uom!(schema, "KPCS#{n}")
    item = Cat.item!(schema, "KI#{n}", uom.record_id)
    lot_item = Cat.item!(schema, "KLI#{n}", uom.record_id, %{"tracking_policy" => "lot"})
    lot = Cat.lot!(schema, lot_item.record_id, "KLOT#{n}")
    other_unit = D.unit!(schema)

    {:ok, entity} =
      Org.create_legal_entity(
        schema,
        %{"code" => "KLE#{n}", "name" => "LE", "bin" => String.pad_leading("#{n}", 12, "7")},
        %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      )

    Map.merge(base, %{
      uom: uom.record_id,
      item: item.record_id,
      lot_item: lot_item.record_id,
      lot: lot.record_id,
      other_unit: other_unit,
      other_location: D.location!(schema, other_unit),
      other_employee: D.employee!(schema, other_unit),
      non_unit: entity["record_id"]
    })
  end

  @doc "A valid low-value line for `m`; `extra` overrides keys (a nil value removes the key)."
  def line(m, extra \\ %{}) do
    %{
      "catalog_item_id" => m.item,
      "catalog_uom_id" => m.uom,
      "quantity" => "20",
      "stock_location_id" => m.location,
      "stock_responsible_id" => m.employee,
      "target_kind" => "low_value",
      "asset_location_id" => m.location,
      "material_responsible_id" => m.employee2,
      "inventory_number" => "KC-#{System.unique_integer([:positive])}",
      "asset_name" => "Office chair"
    }
    |> Map.merge(extra)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "A valid kind_change body with one line; `extra` overrides header keys."
  def body(m, extra \\ %{}, lines \\ nil) do
    Map.merge(
      %{
        "kind" => "kind_change",
        "org_unit_id" => m.unit,
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "reason_text" => "moved from stock",
        "lines" => lines || [line(m)]
      },
      extra
    )
  end

  @doc "Counts of kind_change header and line records and of versioned documents in `schema`."
  def written(schema) do
    import Ecto.Query, only: [from: 2]

    records =
      Letflow.Repo.aggregate(
        from(r in Letflow.Entities.Record.Latest,
          where:
            r.entity_type in ["assets_kind_change", "assets_kind_change_line", "assets_card"] and
              not r.deleted
        ),
        :count,
        prefix: schema
      )

    {records, Letflow.Repo.aggregate(Letflow.Documents.Document, :count, :id, prefix: schema)}
  end
end
