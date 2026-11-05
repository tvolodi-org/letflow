Code.require_file("opening_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.OpeningImportTest do
  @moduledoc """
  REQ-727 / GH #3773: the xlsx import of opening lines into a draft opening document, through the real
  record import route (`POST /api/v1/entities/records/stock_opening_line/import?upsert_by=external_ref`)
  with a real OIDC bearer token, on committed tenants with the real `stock` module installed.
  `async: false` (Sandbox `:auto`).

  I2-1..I2-5 registration, create, re-import, change; I3-1..I3-9 references; I4-1..I4-6 draft only and
  shape refusals; I5-1 reasons on the wire; I6-1/I6-2 dry run; I7-1..I7-3 tenancy.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock
  alias Letflow.Modules.Stock.Documents.OpeningImport
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @cols ~w(header_id org_unit_id location_id responsible_id catalog_item_id catalog_uom_id
           catalog_lot_id quantity received_on unit_price line_value external_ref_system
           external_ref_id)
  @sys "erp"

  setup do
    ctx = P.setup!([:a, :b])
    Map.put(ctx, :im, setup_doc!(ctx, ctx.schema, "H1"))
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  # Masters with external refs under @sys (external id = the string in the map) and a draft opening
  # document whose header carries the external id `header_ref`.
  defp masters!(schema) do
    n = System.unique_integer([:positive])
    ref = fn id -> %{"external_ref_system" => @sys, "external_ref_id" => id} end

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
        Map.merge(
          %{
            "code" => "U#{n}",
            "name" => "U",
            "legal_entity_id" => le["record_id"],
            "site_id" => site["record_id"]
          },
          ref.("unit#{n}")
        ),
        opts()
      )

    {:ok, node} =
      Locations.create_node(
        schema,
        Map.merge(%{"code" => "L#{n}", "name" => "L", "node_kind" => "zone"}, ref.("loc#{n}")),
        opts()
      )

    emp =
      OrgFixture.create!(
        schema,
        "org_employee",
        OrgFixture.values(
          "org_employee",
          "E#{n}",
          Map.merge(%{"org_unit_id" => unit["record_id"]}, ref.("emp#{n}"))
        )
      )

    uom = Cat.uom!(schema, "PCS#{n}", ref.("uom#{n}"))
    item = Cat.item!(schema, "I#{n}", uom.record_id, ref.("item#{n}"))

    lot_item =
      Cat.item!(
        schema,
        "LI#{n}",
        uom.record_id,
        Map.put(ref.("litem#{n}"), "tracking_policy", "lot")
      )

    lot = Cat.lot!(schema, lot_item.record_id, "LOT#{n}", ref.("lot#{n}"))

    %{
      n: n,
      unit: unit["record_id"],
      location: node["record_id"],
      employee: emp.record_id,
      uom: uom.record_id,
      item: item.record_id,
      lot_item: lot_item.record_id,
      lot: lot.record_id,
      refs: %{
        "org_unit_id" => "unit#{n}",
        "location_id" => "loc#{n}",
        "responsible_id" => "emp#{n}",
        "catalog_item_id" => "item#{n}",
        "catalog_uom_id" => "uom#{n}",
        "catalog_lot_id" => nil
      }
    }
  end

  defp setup_doc!(ctx, schema, header_ref) do
    m = masters!(schema)

    body = %{
      "kind" => "opening",
      "org_unit_id" => m.unit,
      "external_ref_system" => @sys,
      "external_ref_id" => header_ref,
      "lines" => [
        %{
          "location_id" => m.location,
          "responsible_id" => m.employee,
          "catalog_item_id" => m.item,
          "catalog_uom_id" => m.uom,
          "quantity" => "1",
          "received_on" => O.back(100),
          "external_ref_system" => @sys,
          "external_ref_id" => "BASE"
        }
      ]
    }

    doc = O.save!(ctx, body)
    %{m: m, doc: doc, header_ref: header_ref}
  end

  # One file row; `over` overrides cells (a key with nil clears it).
  defp row(im, ref, over \\ %{}) do
    cells =
      Map.merge(
        %{
          "header_id" => im.header_ref,
          "quantity" => "10.5",
          "received_on" => O.back(400),
          "external_ref_system" => @sys,
          "external_ref_id" => ref
        },
        im.m.refs
      )
      |> Map.merge(over)

    Enum.map(@cols, &Map.get(cells, &1))
  end

  defp import_file(ctx, rows, query \\ "", token \\ nil) do
    bytes = XlsxFixture.build([[@cols | rows]])

    Plug.Test.conn(
      :post,
      "/api/v1/entities/records/stock_opening_line/import?upsert_by=external_ref" <> query,
      bytes
    )
    |> put_req_header("content-type", @xlsx)
    |> put_req_header("authorization", "Bearer " <> (token || ctx.tok_a))
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp results(conn) do
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["results"]
  end

  defp outcomes(conn), do: Enum.map(results(conn), &(&1["outcome"] || &1["reason"]["type"]))
  defp reasons(conn), do: Enum.map(results(conn), & &1["reason"])
  defp shape(conn), do: Enum.map(results(conn), &Map.drop(&1, ["record_id"]))

  defp draft_content(ctx, id) do
    Repo.one(
      from(v in DocumentVersion,
        where: v.document_id == ^id,
        order_by: [desc: v.version_no],
        limit: 1,
        select: v.content
      ),
      prefix: ctx.schema
    )
  end

  defp lines(ctx, id), do: P.get!(ctx, id)["lines"]

  defp no_posting(ctx, id) do
    assert P.counts(ctx, id) == %{entries: %{}, marks: 0}

    instances =
      from(p in Letflow.EventStore.InstanceProjection,
        where: fragment("?->>'document_id' = ?", p.variables, ^id)
      )

    assert Repo.aggregate(instances, :count, prefix: ctx.schema) == 0
  end

  describe "registration, create, re-import, change" do
    test "I2-1 the manifest lists the import function and validates" do
      assert Stock.manifest().import_functions == [
               %{entity_type: "stock_opening_line", function: :import_opening_line}
             ]

      assert Catalog.validate(Stock.manifest()) == :ok
      assert Catalog.import_function("stock", "stock_opening_line") == :ok
    end

    test "I2-2 three rows create three lines; the draft content equals header and lines", ctx do
      id = ctx.im.doc["id"]
      conn = import_file(ctx, [row(ctx.im, "A"), row(ctx.im, "B"), row(ctx.im, "C")])
      assert outcomes(conn) == ["created", "created", "created"]

      saved = lines(ctx, id)
      assert Enum.map(saved, & &1["line_no"]) == [1, 2, 3, 4]
      assert Enum.map(saved, & &1["external_ref_id"]) == ["BASE", "A", "B", "C"]
      new = Enum.at(saved, 1)
      m = ctx.im.m
      assert new["location_id"] == m.location
      assert new["responsible_id"] == m.employee
      assert new["catalog_item_id"] == m.item
      assert new["catalog_uom_id"] == m.uom
      assert Decimal.equal?(Decimal.new(new["quantity"]), Decimal.new("10.5"))

      content = draft_content(ctx, id)
      assert length(content["lines"]) == 4
      assert content["header"]["external_ref_id"] == "H1"

      assert Enum.map(content["lines"], & &1["external_ref_id"]) == ["BASE", "A", "B", "C"]
      assert Enum.map(content["lines"], & &1["quantity"]) == Enum.map(saved, & &1["quantity"])
      no_posting(ctx, id)
    end

    test "I2-3 the same file again is unchanged and writes nothing", ctx do
      rows = [row(ctx.im, "A"), row(ctx.im, "B")]
      assert outcomes(import_file(ctx, rows)) == ["created", "created"]
      before = {O.counts(ctx.schema), draft_content(ctx, ctx.im.doc["id"])}
      assert outcomes(import_file(ctx, rows)) == ["unchanged", "unchanged"]
      assert {O.counts(ctx.schema), draft_content(ctx, ctx.im.doc["id"])} == before
    end

    test "I2-4 a changed quantity replaces that line only", ctx do
      id = ctx.im.doc["id"]
      import_file(ctx, [row(ctx.im, "A"), row(ctx.im, "B")])
      before = lines(ctx, id)

      conn = import_file(ctx, [row(ctx.im, "A"), row(ctx.im, "B", %{"quantity" => "99"})])
      assert outcomes(conn) == ["unchanged", "updated"]
      after_ = lines(ctx, id)
      assert Enum.map(after_, & &1["line_no"]) == [1, 2, 3]
      assert Enum.at(after_, 1) == Enum.at(before, 1)
      assert Enum.at(after_, 2)["quantity"] =~ "99"
      assert Enum.at(after_, 2)["line_id"] == Enum.at(before, 2)["line_id"]
      assert Enum.at(draft_content(ctx, id)["lines"], 2)["quantity"] =~ "99"
    end

    test "I2-5 a row naming the existing line's pair replaces line 1", ctx do
      id = ctx.im.doc["id"]
      conn = import_file(ctx, [row(ctx.im, "BASE", %{"quantity" => "7"})])
      assert outcomes(conn) == ["updated"]
      assert [%{"line_no" => 1, "quantity" => q}] = lines(ctx, id)
      assert q =~ "7"
    end
  end

  describe "references" do
    for {field, n} <-
          Enum.with_index(
            ~w(header_id org_unit_id location_id responsible_id
                                         catalog_item_id catalog_uom_id catalog_lot_id),
            1
          ) do
      test "I3-#{n} an unknown #{field} is reference_not_found", ctx do
        field = unquote(field)
        im = ctx.im
        before = O.counts(ctx.schema)
        # the lot is optional when absent; here it is present but unknown
        conn = import_file(ctx, [row(im, "X", %{field => "nope"})])
        assert reasons(conn) == [%{"type" => "reference_not_found", "header" => field}]
        assert O.counts(ctx.schema) == before
      end
    end

    test "I3-8 a record id instead of an external id is reference_not_found", ctx do
      conn = import_file(ctx, [row(ctx.im, "X", %{"catalog_item_id" => ctx.im.m.item})])

      assert reasons(conn) == [
               %{"type" => "reference_not_found", "header" => "catalog_item_id"}
             ]
    end

    test "I3-9 an inactive target is reference_inactive", ctx do
      m = ctx.im.m
      ref = %{"external_ref_system" => @sys, "external_ref_id" => "dead", "active" => false}
      Cat.item!(ctx.schema, "IN#{m.n}", m.uom, ref)
      conn = import_file(ctx, [row(ctx.im, "X", %{"catalog_item_id" => "dead"})])

      assert reasons(conn) == [
               %{"type" => "reference_inactive", "header" => "catalog_item_id"}
             ]
    end

    test "I3-10 an absent lot cell is allowed; a present lot is stored", ctx do
      m = ctx.im.m
      id = ctx.im.doc["id"]

      conn =
        import_file(ctx, [
          row(ctx.im, "L1", %{"catalog_item_id" => "litem#{m.n}", "catalog_lot_id" => "lot#{m.n}"})
        ])

      assert outcomes(conn) == ["created"]
      assert Enum.at(lines(ctx, id), 1)["catalog_lot_id"] == m.lot
    end
  end

  describe "draft only and shape refusals" do
    test "I4-1 an issued document answers document_not_draft and writes nothing", ctx do
      im2 = setup_doc!(ctx, ctx.schema, "H2")
      m2 = im2.m
      {:ok, _} = Locations.link_unit_location(ctx.schema, m2.unit, m2.location, opts())
      issued = D.request(:post, "/documents/#{im2.doc["id"]}/issue", ctx.tok_a) |> P.status!(200)
      assert issued["state"] == "issued"
      before = {lines(ctx, im2.doc["id"]), draft_content(ctx, im2.doc["id"])}

      conn = import_file(ctx, [row(im2, "A")])
      assert reasons(conn) == [%{"type" => "document_not_draft"}]
      assert {lines(ctx, im2.doc["id"]), draft_content(ctx, im2.doc["id"])} == before
    end

    test "I4-2 a row for another org unit than the header's is org_unit_mismatch", ctx do
      other = masters!(ctx.schema)
      conn = import_file(ctx, [row(ctx.im, "A", %{"org_unit_id" => "unit#{other.n}"})])
      assert reasons(conn) == [%{"type" => "org_unit_mismatch"}]
      assert length(lines(ctx, ctx.im.doc["id"])) == 1
    end

    test "I4-3 the 101st line is lines_count", ctx do
      refs = for i <- 1..99, do: "N#{i}"
      id = ctx.im.doc["id"]
      # two files: the cap of one file is 200 rows, so one file of 99 rows fills the document
      assert Enum.uniq(outcomes(import_file(ctx, Enum.map(refs, &row(ctx.im, &1))))) == [
               "created"
             ]

      assert length(lines(ctx, id)) == 100

      conn =
        import_file(ctx, [row(ctx.im, "ONE-TOO-MANY"), row(ctx.im, "N1", %{"quantity" => "2"})])

      assert outcomes(conn) == ["lines_count", "updated"]
      assert length(lines(ctx, id)) == 100
    end

    for {q, n} <- Enum.with_index(["0", "-1"], 1) do
      test "I4-4#{n} quantity #{q} is quantity_invalid", ctx do
        conn = import_file(ctx, [row(ctx.im, "Q", %{"quantity" => unquote(q)})])
        assert reasons(conn) == [%{"type" => "quantity_invalid"}]
        assert length(lines(ctx, ctx.im.doc["id"])) == 1
      end
    end

    test "I4-5 a negative unit_price or line_value is price_invalid", ctx do
      conn =
        import_file(ctx, [
          row(ctx.im, "P1", %{"unit_price" => "-1"}),
          row(ctx.im, "P2", %{"line_value" => "-2"}),
          row(ctx.im, "P3", %{"unit_price" => "2", "line_value" => "20"})
        ])

      assert outcomes(conn) == ["price_invalid", "price_invalid", "created"]
    end

    test "I4-6 nothing is posted, no instance and no mark exist", ctx do
      import_file(ctx, [row(ctx.im, "A")])
      no_posting(ctx, ctx.im.doc["id"])
    end
  end

  describe "reasons on the wire" do
    test "I5-1 a shape refusal the core does not catch is line_invalid or a closed reason", ctx do
      # called directly: the core's own cell checks (csv_invalid_*) refuse a bad date or decimal first
      m = ctx.im.m
      id = ctx.im.doc["id"]

      call = fn over ->
        cells =
          Map.merge(
            %{
              "header_id" => "H1",
              "org_unit_id" => m.refs["org_unit_id"],
              "location_id" => m.refs["location_id"],
              "responsible_id" => m.refs["responsible_id"],
              "catalog_item_id" => m.refs["catalog_item_id"],
              "catalog_uom_id" => m.refs["catalog_uom_id"],
              "quantity" => "1",
              "received_on" => O.back(5)
            },
            over
          )

        entry = %{
          entity_type: "stock_opening_line",
          external_ref: %Letflow.Entities.ExternalRef{system: @sys, id: "DIRECT"},
          field_values: cells
        }

        OpeningImport.row(ctx.schema, entry, %{actor_id: Ecto.UUID.generate(), dry_run: false})
      end

      assert {:error, {:line_invalid, "received_on"}} = call.(%{"received_on" => "2026-13-45"})
      assert {:error, :quantity_invalid} = call.(%{"quantity" => "abc"})
      assert {:error, :price_invalid} = call.(%{"unit_price" => "x"})
      assert {:ok, %{outcome: :created}} = call.(%{})
      assert length(lines(ctx, id)) == 2
    end
  end

  describe "dry run" do
    test "I6-1 the dry run answers like the real import and writes nothing", ctx do
      id = ctx.im.doc["id"]
      before = {lines(ctx, id), draft_content(ctx, id), O.counts(ctx.schema)}

      rows = [
        row(ctx.im, "A"),
        row(ctx.im, "B", %{"quantity" => "0"}),
        row(ctx.im, "C", %{"catalog_item_id" => "nope"}),
        row(ctx.im, "D")
      ]

      dry = import_file(ctx, rows, "&dry_run=true")
      assert {lines(ctx, id), draft_content(ctx, id), O.counts(ctx.schema)} == before

      real = import_file(ctx, rows)
      assert outcomes(real) == ["created", "quantity_invalid", "reference_not_found", "created"]
      assert shape(dry) == shape(real)
      assert Enum.map(lines(ctx, id), & &1["line_no"]) == [1, 2, 3]
    end

    test "I6-2 a refused second row does not stop an independent third row", ctx do
      # the same ref twice in one file: the core refuses the second; the third is independent
      rows = [row(ctx.im, "A"), row(ctx.im, "A"), row(ctx.im, "B")]
      dry = import_file(ctx, rows, "&dry_run=true")
      assert length(lines(ctx, ctx.im.doc["id"])) == 1
      real = import_file(ctx, rows)
      assert shape(dry) == shape(real)
      assert Enum.map(results(real), & &1["status"]) == ["ok", "error", "ok"]
      assert length(lines(ctx, ctx.im.doc["id"])) == 3
    end
  end

  describe "tenancy" do
    test "I7-1 tenant B naming A's header gets reference_not_found and A is unchanged", ctx do
      %{b: b, tok_b: tok_b} = P.tenant_b!(ctx)
      im_b = setup_doc_b!(ctx, b)
      id = ctx.im.doc["id"]
      before = {lines(ctx, id), draft_content(ctx, id), O.counts(ctx.schema)}

      # "H1" is the external id of A's header; B's own header is "HB"
      conn = import_file(ctx, [row(%{im_b | header_ref: "H1"}, "A")], "", tok_b)
      assert reasons(conn) == [%{"type" => "reference_not_found", "header" => "header_id"}]
      assert {lines(ctx, id), draft_content(ctx, id), O.counts(ctx.schema)} == before
    end

    test "I7-2 a holder whose grant is not tenant-wide is refused and nothing is written", ctx do
      fx = %{tenant_id: ctx.a.tenant_id, schema_name: ctx.schema}
      :ok = On.store_mode!(fx, :on)
      user = On.scoped_holder!(fx, "TENANT_ADMIN")
      before = O.counts(ctx.schema)

      conn =
        On.call(
          Letflow.Routers.Entities,
          :post,
          "/records/stock_opening_line/import",
          fx,
          user.id,
          ["TENANT_ADMIN"],
          :on,
          %{
            "record_export_schema_version" => "entities/record-export/v1",
            "entity_type" => "stock_opening_line",
            "upsert_by" => "external_ref",
            "records" => [
              %{
                "external_ref" => %{"system" => @sys, "id" => "A"},
                "field_values" => %{"header_id" => "H1", "quantity" => "1"}
              }
            ]
          }
        )

      assert conn.status in 400..499
      assert O.counts(ctx.schema) == before
      assert length(lines(ctx, ctx.im.doc["id"])) == 1
    end

    test "I7-3 a TASK_WORKER gets 403 and nothing is written", ctx do
      tok = Letflow.StockFixture.token(ctx, :a, ["TASK_WORKER"], sub: "worker-1")
      before = O.counts(ctx.schema)
      conn = import_file(ctx, [row(ctx.im, "A")], "", tok)
      assert conn.status == 403
      assert O.counts(ctx.schema) == before
    end
  end

  # Masters and a draft opening for tenant B (its own schema), with header "HB".
  defp setup_doc_b!(ctx, b) do
    mb = masters!(b.schema_name)

    body = %{
      "kind" => "opening",
      "org_unit_id" => mb.unit,
      "external_ref_system" => @sys,
      "external_ref_id" => "HB",
      "lines" => [
        %{
          "location_id" => mb.location,
          "responsible_id" => mb.employee,
          "catalog_item_id" => mb.item,
          "catalog_uom_id" => mb.uom,
          "quantity" => "1",
          "received_on" => O.back(10)
        }
      ]
    }

    tok_b = Letflow.StockFixture.token(ctx, :b, ["TENANT_ADMIN"])
    D.request(:post, "/documents", tok_b, body) |> P.status!(201)
    %{m: mb, doc: nil, header_ref: "HB"}
  end
end
