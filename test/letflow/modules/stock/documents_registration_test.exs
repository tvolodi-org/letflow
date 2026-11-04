Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.DocumentsRegistrationTest do
  @moduledoc """
  REQ-712 / GH #3749 criteria 1 and 2 (A-REG-1..4, A-FLD-1, A-FLD-2, A-DOC-1): the manifest literals, the
  installed record types (active, `managed_by` stock) and the registered document type on a fresh
  committed tenant, the exact field name sets of both types, and the amended documents file.
  Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents.DocumentType
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Stock
  alias Letflow.StockFixture, as: S

  @header ~w(counterparty_id document_id event_time location_id note org_unit_id responsible_id)
  @line ~w(catalog_item_id catalog_lot_id catalog_uom_id header_id line_no org_unit_id quantity)

  setup do
    ctx = S.setup_oidc!([:a])
    %{tenant: S.tenant!("stk-reg", ctx.names.a)}
  end

  defp definition(name) do
    path = Path.join(["priv", "modules", "stock", "entity_definitions", name <> ".json"])
    path |> File.read!() |> Jason.decode!()
  end

  test "A-REG-1: the manifest literals and the catalog check" do
    m = Stock.manifest()
    assert m.version == "0.2.0"
    assert m.pack == "modules/stock/pack.json"
    assert m.depends_on == ["catalog_items", "locations", "org"]
    assert m.manages_entity_types == ["stock_receipt", "stock_receipt_line"]

    assert m.scope_declarations == %{
             "stock_receipt" => {:column, "org_unit_id"},
             "stock_receipt_line" => {:column, "org_unit_id"}
           }

    assert Catalog.validate(m) == :ok
    assert File.exists?(Path.join("priv", m.pack))
  end

  test "A-REG-2: install leaves both types active and managed by stock", %{tenant: t} do
    rows =
      Letflow.Repo.all(
        from(d in Letflow.Entities.EntityDefinition,
          where: d.name in ["stock_receipt", "stock_receipt_line"],
          select: {d.name, d.status, d.managed_by}
        ),
        prefix: t.schema_name
      )

    assert Enum.sort(rows) == [
             {"stock_receipt", :active, "stock"},
             {"stock_receipt_line", :active, "stock"}
           ]
  end

  test "A-REG-3: the document type is registered with the six attributes", %{tenant: t} do
    type = Letflow.Repo.get!(DocumentType, "stock_receipt", prefix: t.schema_name)
    assert type.owner_module == "stock"
    assert type.numbering_scope == :year
    assert type.number_prefix == "RCP"
    assert type.number_pad == 6
    assert type.legal_entity_required == false
    assert type.declared_fields == %{}
  end

  test "A-REG-4: a second install is refused or a no-op and leaves one document type", %{
    tenant: t
  } do
    _ = Installs.install("stock", Ecto.UUID.generate(), prefix: t.schema_name, rationale: "again")

    assert Letflow.Repo.aggregate(
             from(d in DocumentType, where: d.key == "stock_receipt"),
             :count,
             prefix: t.schema_name
           ) == 1
  end

  test "A-FLD-1: the header has exactly the declared field names, none of the moved ones" do
    names = definition("stock_receipt")["fields"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == @header

    for gone <- ~w(number status posted_at posted_by reversed_by_entry), do: refute(gone in names)
    required = for f <- definition("stock_receipt")["fields"], f["required"], do: f["name"]

    assert Enum.sort(required) ==
             ~w(document_id event_time location_id org_unit_id responsible_id)

    assert Enum.find(definition("stock_receipt")["fields"], &(&1["name"] == "org_unit_id"))[
             "queried"
           ]
  end

  test "A-FLD-2: the line fields, the foreign key and the strict decimal" do
    d = definition("stock_receipt_line")
    assert d["fields"] |> Enum.map(& &1["name"]) |> Enum.sort() == @line

    assert [%{"field" => "header_id", "references_entity" => "stock_receipt"} = fk] =
             d["foreign_keys"]

    assert fk["name"] == "fk_stock_receipt_line_header_id"
    quantity = Enum.find(d["fields"], &(&1["name"] == "quantity"))
    assert quantity["type"] == "decimal" and quantity["decimal_strict"] == true
    assert quantity["required"] == true
    assert Enum.find(d["fields"], &(&1["name"] == "org_unit_id"))["queried"] == true
  end

  test "A-DOC-1: the documents file says the moved values are read from the versioned document" do
    text = File.read!("docs/assets/stock-workflow-documents.md")
    section = text |> String.split("### 1.4") |> Enum.at(1) |> String.split("### 1.5") |> hd()
    assert section =~ "not stored on the header"
    assert section =~ "versioned document"
    refute section =~ "| `posted_at` |"
    life = text |> String.split("### 9.1 Life cycle") |> Enum.at(1) |> String.slice(0, 900)
    assert life =~ "read from the versioned document"
  end
end
