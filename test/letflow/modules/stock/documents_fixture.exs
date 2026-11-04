Code.require_file("stock_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)
Code.require_file("../catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.StockDocsFixture do
  @moduledoc """
  REQ-712 / GH #3749: master data and requests of the stock document tests. Masters are written through
  their owners' own write functions or the owner-path fixtures of their modules (`Letflow.OrgFixture`,
  `Letflow.CatalogItemsFixture`); the request helpers send JSON through the full `Letflow.Router` with a
  bearer token (`Letflow.StockFixture`). A `.exs` file, loaded with `Code.require_file/2`.
  """

  import Plug.Conn

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture

  @base "/api/v1/modules/stock"

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  @doc "A live org unit (no staff) in `schema`; returns its record id."
  def unit!(schema) do
    n = System.unique_integer([:positive])

    {:ok, le} =
      Org.create_legal_entity(
        schema,
        %{"code" => "LE#{n}", "name" => "LE", "bin" => String.pad_leading("#{n}", 12, "5")},
        opts()
      )

    {:ok, site} =
      Org.create_site(
        schema,
        %{"code" => "S#{n}", "name" => "S", "legal_entity_id" => le["record_id"]},
        opts()
      )

    {:ok, unit} =
      Org.create_unit(
        schema,
        %{
          "code" => "U#{n}",
          "name" => "U",
          "legal_entity_id" => le["record_id"],
          "site_id" => site["record_id"]
        },
        opts()
      )

    unit["record_id"]
  end

  @doc """
  A full set of live masters in `schema`: an org unit, a location linked to it, an active employee, a
  unit of measure, an item with that base unit, a lot of the item, a supplier. Returns a map of ids.
  """
  def masters!(schema) do
    n = System.unique_integer([:positive])
    unit_id = unit!(schema)

    {:ok, node} =
      Locations.create_node(
        schema,
        %{"code" => "L#{n}", "name" => "L", "node_kind" => "zone"},
        opts()
      )

    {:ok, _link} = Locations.link_unit_location(schema, unit_id, node["record_id"], opts())

    employee =
      OrgFixture.create!(
        schema,
        "org_employee",
        OrgFixture.values("org_employee", "E#{n}", %{"org_unit_id" => unit_id})
      )

    uom = Cat.uom!(schema, "PCS#{n}")
    item = Cat.item!(schema, "I#{n}", uom.record_id)
    lot = Cat.lot!(schema, item.record_id, "LOT#{n}")
    supplier = Cat.counterparty!(schema, "SUP#{n}")

    %{
      unit: unit_id,
      location: node["record_id"],
      employee: employee.record_id,
      uom: uom.record_id,
      item: item.record_id,
      lot: lot.record_id,
      supplier: supplier.record_id
    }
  end

  @doc "A valid receipt body for `m` (the masters map); `time` is the ISO event time."
  def body(m, time \\ nil, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "receipt",
        "org_unit_id" => m.unit,
        "location_id" => m.location,
        "responsible_id" => m.employee,
        "event_time" => time || DateTime.to_iso8601(DateTime.utc_now()),
        "counterparty_id" => m.supplier,
        "note" => "delivery",
        "lines" => [
          %{
            "catalog_item_id" => m.item,
            "catalog_uom_id" => m.uom,
            "catalog_lot_id" => m.lot,
            "quantity" => "10.5"
          },
          %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "2"}
        ]
      },
      extra
    )
  end

  @doc "Sends `method` `path` (relative to the module base) with an optional JSON body."
  def request(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, @base <> path)
        body -> Plug.Test.conn(method, @base <> path, Jason.encode!(body))
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  @doc "Every document id, header record and line record of `schema` (for 'nothing written' counts)."
  def counts(schema) do
    import Ecto.Query, only: [from: 2]
    alias Letflow.Entities.Record.Latest

    records =
      Letflow.Repo.aggregate(
        from(r in Latest, where: r.entity_type in ["stock_receipt", "stock_receipt_line"]),
        :count,
        prefix: schema
      )

    documents = Letflow.Repo.aggregate(Letflow.Documents.Document, :count, :id, prefix: schema)
    {records, documents}
  end
end
