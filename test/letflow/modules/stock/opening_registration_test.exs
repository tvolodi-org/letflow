Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.OpeningRegistrationTest do
  @moduledoc """
  REQ-725 / GH #3775 criteria 1 and 2 (O-REG-1, O-REG-2): the manifest, the installed record types and
  the registered document type `stock_opening` on a fresh committed tenant, and the exact field sets of
  both record types. REQ-726 criterion 1: the registration gains the cause `opening`.
  Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents.DocumentType
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs
  alias Letflow.Modules.ManifestHash
  alias Letflow.Modules.Stock
  alias Letflow.StockFixture, as: S

  @header ~w(document_id external_ref_id external_ref_system note org_unit_id)
  @line ~w(catalog_item_id catalog_lot_id catalog_uom_id external_ref_id external_ref_system header_id line_no line_value location_id org_unit_id quantity received_on responsible_id unit_price)

  setup do
    ctx = S.setup_oidc!([:a])
    %{tenant: S.tenant!("stk-opr", ctx.names.a)}
  end

  defp definition(name) do
    path = Path.join(["priv", "modules", "stock", "entity_definitions", name <> ".json"])
    path |> File.read!() |> Jason.decode!()
  end

  test "O-REG-1: manifest, active managed types, the document type, a second install is a no-op",
       %{tenant: t} do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok
    assert m.version == "0.14.0"

    assert "stock_opening" in m.manages_entity_types and
             "stock_opening_line" in m.manages_entity_types

    assert Map.take(m.scope_declarations, ["stock_opening", "stock_opening_line"]) == %{
             "stock_opening" => {:column, "org_unit_id"},
             "stock_opening_line" => {:column, "org_unit_id"}
           }

    assert {"POST", "/documents/:id/check", :StockPost} in m.route_policies

    rows =
      Letflow.Repo.all(
        from(d in Letflow.Entities.EntityDefinition,
          where: d.name in ["stock_opening", "stock_opening_line"],
          select: {d.name, d.status, d.managed_by}
        ),
        prefix: t.schema_name
      )

    assert Enum.sort(rows) == [
             {"stock_opening", :active, "stock"},
             {"stock_opening_line", :active, "stock"}
           ]

    type = Letflow.Repo.get!(DocumentType, "stock_opening", prefix: t.schema_name)

    assert {type.owner_module, type.numbering_scope, type.number_prefix, type.number_pad,
            type.legal_entity_required, type.declared_fields} ==
             {"stock", :year, "OPN", 6, false, %{}}

    _ = Installs.install("stock", Ecto.UUID.generate(), prefix: t.schema_name, rationale: "again")

    assert Letflow.Repo.aggregate(
             from(d in DocumentType, where: d.key == "stock_opening"),
             :count,
             prefix: t.schema_name
           ) == 1
  end

  test "O-REG-2: the exact field sets, flags and none of the moved or forbidden fields" do
    header = definition("stock_opening")
    names = header["fields"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == @header

    for gone <- ~w(event_time number status posted_at posted_by location_id responsible_id),
        do: refute(gone in names)

    required = for f <- header["fields"], f["required"], do: f["name"]
    assert Enum.sort(required) == ~w(document_id org_unit_id)
    assert header["constraints"] == nil

    for name <- ~w(org_unit_id external_ref_system external_ref_id) do
      assert Enum.find(header["fields"], &(&1["name"] == name))["queried"] == true
    end

    line = definition("stock_opening_line")
    assert line["fields"] |> Enum.map(& &1["name"]) |> Enum.sort() == @line

    required = for f <- line["fields"], f["required"], do: f["name"]

    assert Enum.sort(required) ==
             ~w(catalog_item_id catalog_uom_id header_id line_no location_id org_unit_id quantity received_on responsible_id)

    assert [%{"field" => "header_id", "references_entity" => "stock_opening"}] =
             line["foreign_keys"]

    for name <- ~w(quantity unit_price line_value) do
      f = Enum.find(line["fields"], &(&1["name"] == name))
      assert f["type"] == "decimal" and f["decimal_strict"] == true
    end

    assert Enum.find(line["fields"], &(&1["name"] == "received_on"))["type"] == "date"
  end

  test "O-POL-1b: the cause opening is registered and the manifest hash moved" do
    {:ok, r} = Catalog.fetch_ledger("stock", "stock")
    assert r.causes["opening"] == %{sign_rule: :positive, reason_required: false}
    base = Stock.manifest()
    refute ManifestHash.compute(base) == ManifestHash.compute(%{base | version: "0.4.0"})

    no_opening =
      put_in(base.ledger["stock"].causes, Map.delete(base.ledger["stock"].causes, "opening"))

    refute ManifestHash.compute(base) == ManifestHash.compute(no_opening)
  end
end
