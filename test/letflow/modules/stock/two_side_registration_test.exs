Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.TwoSideRegistrationTest do
  @moduledoc """
  REQ-721 / GH #3770 criterion 1 (REG-1..4): the manifest, the installed record types and document
  types, the exact field sets and the three posting process definitions of transfer, hand over and
  return. Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents.DocumentType
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Stock
  alias Letflow.StockFixture, as: S

  @types ~w(stock_transfer stock_transfer_line stock_handover stock_handover_line stock_return stock_return_line)
  @line ~w(catalog_item_id catalog_lot_id catalog_uom_id header_id line_no org_unit_id quantity)
  @common ~w(document_id event_time note org_unit_id)
  @headers %{
    "stock_transfer" =>
      ~w(from_location_id from_responsible_id to_org_unit_id to_location_id to_responsible_id),
    "stock_handover" =>
      ~w(from_location_id from_responsible_id to_org_unit_id to_location_id to_responsible_id),
    "stock_return" =>
      ~w(from_org_unit_id from_location_id from_responsible_id to_location_id to_responsible_id)
  }

  setup do
    ctx = S.setup_oidc!([:a])
    %{tenant: S.tenant!("stk-2sreg", ctx.names.a)}
  end

  defp definition(name) do
    ["priv", "modules", "stock", "entity_definitions", name <> ".json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  test "REG-1: the manifest gains the six types, each scoped by org_unit_id; catalog check ok" do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok
    assert m.version == "0.7.0"

    assert Enum.slice(m.manages_entity_types, 0, 8) == [
             "stock_receipt",
             "stock_receipt_line" | @types
           ]

    for type <- @types, do: assert(m.scope_declarations[type] == {:column, "org_unit_id"})
  end

  test "REG-2: install leaves six types active and managed by stock, three document types",
       %{tenant: t} do
    rows =
      Letflow.Repo.all(
        from(d in Letflow.Entities.EntityDefinition,
          where: d.name in ^@types,
          select: {d.name, d.status, d.managed_by}
        ),
        prefix: t.schema_name
      )

    assert Enum.sort(rows) == Enum.sort(for type <- @types, do: {type, :active, "stock"})

    for {key, prefix} <- [
          {"stock_transfer", "TRF"},
          {"stock_handover", "HOV"},
          {"stock_return", "RET"}
        ] do
      type = Letflow.Repo.get!(DocumentType, key, prefix: t.schema_name)
      assert type.owner_module == "stock"
      assert type.numbering_scope == :year
      assert type.number_prefix == prefix
      assert type.number_pad == 6
      assert type.legal_entity_required == false
      assert type.declared_fields == %{}
    end

    _ = Installs.install("stock", Ecto.UUID.generate(), prefix: t.schema_name, rationale: "again")

    assert Letflow.Repo.aggregate(
             from(d in DocumentType, where: d.key in ^Map.keys(@headers)),
             :count,
             prefix: t.schema_name
           ) == 3
  end

  test "REG-3: the exact field names and required sets of the six types" do
    for {type, extra} <- @headers do
      d = definition(type)
      assert d["fields"] |> Enum.map(& &1["name"]) |> Enum.sort() == Enum.sort(@common ++ extra)
      required = for f <- d["fields"], f["required"], do: f["name"]
      assert Enum.sort(required) == Enum.sort(List.delete(@common, "note") ++ extra)
      assert Enum.find(d["fields"], &(&1["name"] == "org_unit_id"))["queried"] == true

      line = definition(type <> "_line")
      assert line["fields"] |> Enum.map(& &1["name"]) |> Enum.sort() == @line
      assert [%{"field" => "header_id", "references_entity" => ^type}] = line["foreign_keys"]
      quantity = Enum.find(line["fields"], &(&1["name"] == "quantity"))
      assert quantity["decimal_strict"] == true and quantity["required"] == true
    end

    # no price, value, reason or counterparty field on any header
    for type <- Map.keys(@headers),
        gone <- ~w(counterparty_id unit_price line_value reason_code location_id responsible_id) do
      refute gone in Enum.map(definition(type)["fields"], & &1["name"])
    end
  end

  test "REG-4: the pack has one HUMAN_TASK post / post_document definition per new kind" do
    defs =
      "priv/modules/stock/pack.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("definitions")

    for key <- Map.keys(@headers) do
      definition = Enum.find(defs, &(&1["process_key"] == key))

      assert [%{"id" => "post", "attributes" => %{"module_writes" => [line]}}] =
               Enum.filter(definition["graph"]["nodes"], &(&1["node_type"] == "HUMAN_TASK"))

      assert line["module"] == "stock" and line["handler"] == "post_document"
    end

    ids = Enum.map(defs, & &1["definition_id"])
    assert ids == Enum.uniq(ids)
  end
end
