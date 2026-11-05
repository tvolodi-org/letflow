Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountsRegistrationTest do
  @moduledoc """
  REQ-700 / GH #3737 criterion 1 (R-MANIFEST, R-INSTALL): the manifest of module `stock` 0.2.0 and what an
  install of it leaves in a fresh tenant: three active managed types, a closed generic entity route, four
  document types, a second install that changes nothing.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.CountsFixture, as: F
  alias Letflow.Documents.DocumentType
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Stock

  test "R1 (REQ-717) count_signature, the five count_order fields, the five routes, version 0.9.0" do
    m = Stock.manifest()
    assert m.version == "0.14.0" and Catalog.validate(m) == :ok
    assert "count_signature" in m.manages_entity_types
    assert m.scope_declarations["count_signature"] == {:column, "org_unit_id"}

    pack = "priv/modules/stock/pack.json" |> File.read!() |> Jason.decode!()

    names = fn type ->
      pack["entity_definitions"]
      |> Enum.find(&(&1["name"] == type))
      |> get_in(["definition_json", "fields"])
      |> Enum.map(& &1["name"])
    end

    assert Enum.sort(names.("count_signature")) ==
             ~w(count_order_id document_id document_kind employee_id marked_at marked_by org_unit_id signer_role version_no)

    for f <-
          ~w(sheet_signed_at differences_document_id differences_number differences_issued_at differences_signed_at),
        do: assert(f in names.("count_order"))

    for route <- [
          {"POST", "/counts/:id/sheet-signatures", :StockCountRecord},
          {"POST", "/counts/:id/differences", :StockCountRecord},
          {"POST", "/counts/:id/differences-signatures", :StockCountRecord},
          {"GET", "/counts/:id/differences", :StockRead},
          {"GET", "/counts/:id/signatures", :StockRead}
        ],
        do: assert(route in m.route_policies)
  end

  test "R-MANIFEST (REQ-701 R1, R2) the count permissions, five managed scoped types, decimal fields" do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok

    assert m.permissions ==
             [
               :StockPost,
               :StockReverse,
               :StockRead,
               :StockReconcile,
               :StockCountOrder,
               :StockCountRecord
             ]

    assert m.role_grants == %{
             STOREKEEPER: [
               :StockRead,
               :StockPost,
               :StockReverse,
               :StockCountOrder,
               :StockCountRecord
             ]
           }

    assert Enum.slice(m.manages_entity_types, 12, 5) == [
             "count_order",
             "count_order_scope",
             "count_commission_member",
             "count_sheet_line",
             "count_entry"
           ]

    assert Map.values(m.scope_declarations) |> Enum.uniq() == [{:column, "org_unit_id"}]
    # REQ-701 R2: the four quantity fields are exact decimals in the shipped pack
    pack = "priv/modules/stock/pack.json" |> File.read!() |> Jason.decode!()

    fields = fn type ->
      pack["entity_definitions"]
      |> Enum.find(&(&1["name"] == type))
      |> get_in(["definition_json", "fields"])
      |> Map.new(&{&1["name"], &1})
    end

    for {type, names} <- [
          {"count_sheet_line", ~w(book_quantity counted_quantity)},
          {"count_entry", ~w(quantity_before quantity_after)}
        ],
        name <- names do
      f = Map.fetch!(fields.(type), name)
      assert f["type"] == "decimal" and f["decimal_strict"] == true, "#{type}.#{name}"
      assert f["decimal_scale"] == 9 and f["decimal_precision"] == 24
    end

    assert Map.keys(m.scope_declarations) |> Enum.sort() == Enum.sort(m.manages_entity_types)
    assert m.depends_on == ["catalog_items", "codes", "locations", "org"]

    for {_method, _path, permission} <- m.route_policies,
        do: assert(permission in m.permissions)
  end

  test "R1a (REQ-716) count_entry accepts typed and scan and has the four optional scan fields" do
    pack = "priv/modules/stock/pack.json" |> File.read!() |> Jason.decode!()

    definition =
      pack["entity_definitions"]
      |> Enum.find(&(&1["name"] == "count_entry"))
      |> Map.fetch!("definition_json")

    by_name = Map.new(definition["fields"], &{&1["name"], &1})
    assert by_name["method"]["enum_values"] == ["typed", "scan"]

    for name <- ~w(scan_id code_id scanned_text location_id) do
      assert by_name[name]["type"] == "string" and by_name[name]["required"] != true, name
    end

    assert by_name["scan_id"]["queried"] == true
    assert Enum.any?(definition["indexes"], &(&1["fields"] == ["count_order_id", "scan_id"]))
  end

  test "R-INSTALL the install activates the types and registers the four document types" do
    t = F.tenant!()
    s = t.schema

    rows =
      Repo.all(
        from(d in EntityDefinition, select: {d.name, d.managed_by, d.status}, order_by: d.name),
        prefix: s
      )

    assert Enum.filter(
             rows,
             &(elem(&1, 1) == "stock" and String.starts_with?(elem(&1, 0), "count_"))
           ) ==
             Enum.map(
               ~w(count_commission_member count_entry count_order count_order_scope count_sheet_line count_signature),
               &{&1, "stock", :active}
             )

    assert Letflow.Entities.ScopeDeclaration.for_type("count_order", s) ==
             {:column, "org_unit_id"}

    for type <-
          ~w(count_order count_order_scope count_commission_member count_sheet_line count_entry count_signature) do
      conn =
        Plug.Test.conn(:post, "/records/#{type}")
        |> Map.put(:body_params, %{"field_values" => %{"kind" => "full"}})
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: t.tenant_id,
          roles: ["TENANT_ADMIN"]
        })
        |> Plug.Conn.assign(:trace_id, "req700-install-trace")
        |> Letflow.Routers.Entities.call(Letflow.Routers.Entities.init([]))

      assert conn.status == 403 and conn.resp_body =~ "entity_type_managed", type
    end

    types =
      Repo.all(
        from(d in DocumentType, where: like(d.key, "count.%"), order_by: d.key),
        prefix: s
      )

    assert Enum.map(types, &{&1.key, &1.number_prefix}) ==
             [
               {"count.differences", "CD"},
               {"count.order", "CO"},
               {"count.posting", "CP"},
               {"count.sheet", "CS"}
             ]

    for type <- types do
      assert type.owner_module == "stock"
      assert type.numbering_scope == :year
      assert type.legal_entity_required == false
    end

    # registering the same four types again changes nothing (an equal registration is a no-op)
    ctx = %{actor_id: Ecto.UUID.generate(), rationale: "test: REQ-700"}

    for type <- types do
      attrs = %{
        key: type.key,
        owner_module: "stock",
        numbering_scope: :year,
        number_prefix: type.number_prefix,
        number_pad: 4,
        legal_entity_required: false,
        declared_fields: %{}
      }

      assert {:ok, _} = Letflow.Documents.register_type(s, attrs, ctx)
    end

    # the receipt, the opening (REQ-725), issue and write-off (REQ-715), the three two-sided kinds
    # and the four count types
    assert length(Repo.all(DocumentType, prefix: s)) == 11
  end
end
