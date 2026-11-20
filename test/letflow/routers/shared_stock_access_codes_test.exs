Code.require_file("../modules/stock/stock_fixture.exs", __DIR__)
Code.require_file("../modules/stock/documents_fixture.exs", __DIR__)
Code.require_file("../modules/codes/codes_fixture.exs", __DIR__)
Code.require_file("../modules/catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Routers.SharedStockAccessCodesTest do
  @moduledoc """
  REQ-910 / GH #4902 (K8 of docs/status/qoimeks-old-client-compat.md section 5.3; decision 0091 section
  11d): the scan lookup of the old Qoimeks app, `GET /qoimeks/:slug/api/codes/lookup?code=` (and the
  plain `/codes/lookup`), through the full `Letflow.Router` over committed tenants. IDs follow the
  acceptance criteria: L1 item found, L2 place found, L3 the legacy barcode loaded through the code
  imports, L4 not found is one answer, L5 input, L6 access and tenancy, L7 read only.
  `async: false`: committed tenants, VM-global config and buckets.
  """

  # impl_order: REQ-910
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.CodesFixture, as: K
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity.Tenant
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.OldAppReads
  alias Letflow.Plugs.AuthAttemptLimit
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.Repo
  alias Letflow.SharedStockAccess
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.StockFixture, as: S

  @not_found %{"error" => "not found", "reason" => "code_not_found"}
  @required %{"error" => "code is required", "reason" => "invalid_request"}
  @keys ~w(code object_code object_id object_name object_type)

  setup do
    ctx = S.setup_oidc!([:a, :b])
    a = S.tenant!("q910-a", ctx.names.a)
    b = S.tenant!("q910-b", ctx.names.b)

    originals = %{
      tenants: Application.fetch_env(:letflow, :shared_stock_access_tenants),
      limits: Application.fetch_env(:letflow, AuthAttemptLimit)
    }

    on_exit(fn ->
      restore(:shared_stock_access_tenants, originals.tenants)
      restore(AuthAttemptLimit, originals.limits)
      Bucket.reset()
    end)

    Application.put_env(:letflow, :shared_stock_access_tenants, [a.tenant.slug, b.tenant.slug])

    Application.put_env(:letflow, AuthAttemptLimit,
      failure_capacity: 1000,
      request_capacity: 1000
    )

    Bucket.reset()

    {:ok,
     ctx: ctx,
     a: a,
     b: b,
     seeded: seed!(a),
     va: access!(a),
     vb: access!(b),
     tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:letflow, key, value)
  defp restore(key, :error), do: Application.delete_env(:letflow, key)

  defp access!(fx) do
    {:ok, _kind, value} =
      SharedStockAccess.put(fx.schema_name, fx.tenant.slug, %{}, %{
        user_id: Ecto.UUID.generate(),
        trace_id: nil
      })

    value
  end

  defp fresh, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  # Item A-1 'Болт' with barcode 4870001112223, place RI2 with qr LOC-RI2, plus one code of every
  # kind that is NOT found: a received-only code, a retired one, a lot code, an inactive item's code,
  # a mixed-case code, and an item B-1 with an external id (for the import) and no code yet.
  defp seed!(fx) do
    s = fx.schema_name
    uom = Cat.uom!(s, "pcs")
    a1 = Cat.item!(s, "A-1", uom.record_id, %{"kind" => "material", "name" => "Болт"})
    b1 = item_with_ref!(s, "B-1", uom)

    {:ok, ri2} =
      Locations.create_node(
        s,
        %{"code" => "RI2", "name" => "Rack RI2", "node_kind" => "zone"},
        fresh()
      )

    assign!(s, "4870001112223", "catalog_item", a1.record_id)
    assign!(s, "LOC-RI2", "location_node", ri2["record_id"], "qr")
    assign!(s, "QR-ABC", "catalog_item", a1.record_id, "qr")

    K.tag!(s, "5550000000001")

    retired = K.tag!(s, "5550000000002", %{"status" => "assigned"})
    K.assign!(s, retired, "catalog_item", a1.record_id)
    K.set_status!(s, retired, "retired")

    lot = Cat.lot!(s, a1.record_id, "LOT-1")
    assign!(s, "5550000000003", "catalog_lot", lot.record_id)

    off = Cat.item!(s, "A-9", uom.record_id, %{"kind" => "material", "name" => "Off"})
    assign!(s, "5550000000004", "catalog_item", off.record_id)
    Cat.update!(s, off, Map.put(off.field_values, "active", false))

    %{uom: uom, a1: a1, b1: b1, ri2: ri2, lot: lot, off: off}
  end

  defp item_with_ref!(s, code, uom) do
    Cat.item!(s, code, uom.record_id, %{
      "kind" => "material",
      "name" => "Item #{code}",
      "external_ref_system" => "s",
      "external_ref_id" => code
    })
  end

  defp assign!(s, value, type, target_id, kind \\ "barcode") do
    tag = K.tag!(s, value, %{"status" => "assigned", "kind" => kind})
    K.assign!(s, tag, type, target_id)
  end

  defp request(method, slug, path, value, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, "/qoimeks/#{slug}#{path}")
        csv -> Plug.Test.conn(method, "/qoimeks/#{slug}#{path}", csv)
      end

    conn = if value, do: put_req_header(conn, "authorization", "Bearer " <> value), else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp get(fx, path, value), do: request(:get, fx.tenant.slug, path, value)
  defp lookup(fx, query, value), do: get(fx, "/api/codes/lookup" <> query, value)
  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp ok!(conn) do
    assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
    body(conn)
  end

  defp catalog(fx, value), do: get(fx, "/api/catalog", value) |> ok!()

  defp sku_id(cat, code), do: Enum.find(cat["skus"], &(&1["code"] == code))["id"]
  defp place_id(cat, code), do: Enum.find(cat["locations"], &(&1["code"] == code))["id"]

  # -- L1, L2 ---------------------------------------------------------------------------------------

  describe "found" do
    test "L1 an item: exactly five keys, the catalog's integer, both path forms", t do
      cat = catalog(t.a, t.va)
      found = lookup(t.a, "?code=4870001112223", t.va)
      row = ok!(found)

      assert row |> Map.keys() |> Enum.sort() == @keys

      assert row == %{
               "object_type" => "sku",
               "object_id" => sku_id(cat, "A-1"),
               "object_code" => "A-1",
               "object_name" => "Болт",
               "code" => "4870001112223"
             }

      plain = get(t.a, "/codes/lookup?code=4870001112223", t.va)
      assert {plain.status, plain.resp_body} == {200, found.resp_body}
      assert ["private, no-store"] == get_resp_header(found, "cache-control")
    end

    test "L2 a place: object_type location and the catalog's place integer", t do
      cat = catalog(t.a, t.va)
      row = lookup(t.a, "?code=LOC-RI2", t.va) |> ok!()

      assert row == %{
               "object_type" => "location",
               "object_id" => place_id(cat, "RI2"),
               "object_code" => "RI2",
               "object_name" => "Rack RI2",
               "code" => "LOC-RI2"
             }
    end

    test "L1 the lookup works before the catalog was ever read (the id is assigned) and is stable",
         t do
      first = lookup(t.a, "?code=4870001112223", t.va) |> ok!()
      assert is_integer(first["object_id"]) and first["object_id"] > 0
      assert lookup(t.a, "?code=4870001112223", t.va) |> ok!() == first
      assert sku_id(catalog(t.a, t.va), "A-1") == first["object_id"]
    end
  end

  # -- L3 -------------------------------------------------------------------------------------------

  describe "the legacy barcode loaded through the code imports" do
    test "L3 a code_tag and a code_assignment CSV import make the barcode of B-1 findable", t do
      import!(
        t,
        "code_tag",
        "value,kind,external_ref_system,external_ref_id\n4870001112224,barcode,s,T1\n"
      )

      import!(
        t,
        "code_assignment",
        "code_id,target_type,target_id,external_ref_system,external_ref_id\n" <>
          "4870001112224,catalog_item,B-1,s,A1\n"
      )

      cat = catalog(t.a, t.va)
      row = lookup(t.a, "?code=4870001112224", t.va) |> ok!()

      assert %{"object_type" => "sku", "object_code" => "B-1", "code" => "4870001112224"} = row
      assert row["object_id"] == sku_id(cat, "B-1")
      assert Enum.find(cat["skus"], &(&1["code"] == "B-1"))["barcode"] == "4870001112224"
    end
  end

  defp import!(t, type, csv) do
    conn =
      Plug.Test.conn(:post, "/api/v1/entities/records/#{type}/import?upsert_by=external_ref", csv)
      |> put_req_header("content-type", "text/csv")
      |> put_req_header("authorization", "Bearer " <> t.tok_a)
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

    assert conn.status == 200, "#{type} import: #{conn.status} #{conn.resp_body}"
    assert Enum.all?(body(conn)["results"], &(&1["outcome"] == "created")), conn.resp_body
  end

  # -- L4 -------------------------------------------------------------------------------------------

  describe "not found is one answer" do
    @unfound [
      {"an unknown value", "0000000000000"},
      {"a code received but not assigned", "5550000000001"},
      {"a retired code", "5550000000002"},
      {"a code assigned to a lot", "5550000000003"},
      {"a code of an inactive item", "5550000000004"},
      {"the other case of a stored value", "qr-abc"},
      {"a NUL byte", "%00"}
    ]

    test "L4 each is 404 with the same bytes, never 500", t do
      bodies =
        for {label, value} <- @unfound do
          conn = lookup(t.a, "?code=#{value}", t.va)
          assert conn.status == 404, "#{label}: #{conn.status} #{conn.resp_body}"
          assert body(conn) == @not_found, label
          conn.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
      # the stored value itself is found (the case rule is the only difference)
      assert lookup(t.a, "?code=QR-ABC", t.va) |> ok!() |> Map.get("object_code") == "A-1"
    end

    test "L4 a code with two open assignments (a conflict) is the same 404", t do
      s = t.a.schema_name
      tag = K.tag!(s, "5550000000005", %{"status" => "assigned"})
      K.assign!(s, tag, "catalog_item", t.seeded.a1.record_id)
      K.assign!(s, tag, "catalog_item", t.seeded.b1.record_id)

      conn = lookup(t.a, "?code=5550000000005", t.va)
      assert {conn.status, body(conn)} == {404, @not_found}
    end

    test "L4 a target type that is not tenant-wide is the same 404 (the type check fails closed)",
         t do
      s = t.a.schema_name
      assign!(s, "5550000000006", "org_unit", Ecto.UUID.generate())
      conn = lookup(t.a, "?code=5550000000006", t.va)
      assert {conn.status, body(conn)} == {404, @not_found}
    end

    test "L4 code=%FF is not a valid query: InvalidQueryError (status 400) before any lookup",
         t do
      for path <- ["/api/codes/lookup?code=%FF", "/api/balances?sku_id=%FF"] do
        # Plug.Test wraps the raise; the server unwraps it to the reason, whose status is 400
        err = assert_raise Plug.Conn.WrapperError, fn -> get(t.a, path, t.va) end
        assert %Plug.Conn.InvalidQueryError{} = err.reason
        assert Plug.Exception.status(err.reason) == 400
      end
    end
  end

  # -- L5 -------------------------------------------------------------------------------------------

  describe "input" do
    test "L5 spaces around the value are trimmed", t do
      assert lookup(t.a, "?code=%204870001112223%20", t.va) |> ok!() |> Map.get("object_code") ==
               "A-1"
    end

    test "L5 no code, an empty one, a blank one and a non-text one are 400 code is required", t do
      for query <- ["", "?code=", "?code=%20%20", "?code[]=1", "?code[a]=1", "?other=1"] do
        conn = lookup(t.a, query, t.va)
        assert {conn.status, body(conn)} == {400, @required}, query
      end
    end
  end

  # -- L6 -------------------------------------------------------------------------------------------

  describe "access and tenancy" do
    test "L6 no header, a wrong value and another tenant's value give the 401 of the catalog",
         t do
      for value <- [nil, "wrong-value", t.vb] do
        refused = lookup(t.a, "?code=4870001112223", value)
        assert refused.status == 401
        assert refused.resp_body == get(t.a, "/api/catalog", value).resp_body
      end
    end

    test "L6 a value that exists only in A is the 404 for B's own credential", t do
      conn = lookup(t.b, "?code=4870001112223", t.vb)
      assert {conn.status, body(conn)} == {404, @not_found}
      assert lookup(t.b, "?code=LOC-RI2", t.vb).resp_body == conn.resp_body
    end

    test "L6 scope enforcement on or shadow is 403 scope_enforcement_active", t do
      for mode <- [:shadow, :on] do
        from(x in Tenant, where: x.id == ^t.a.tenant_id)
        |> Repo.update_all(set: [scope_enforcement: mode])

        conn = lookup(t.a, "?code=4870001112223", t.va)
        assert {conn.status, body(conn)} == {403, %{"error" => "scope_enforcement_active"}}
      end
    end

    test "L6 an accepted lookup spends one request token and the answer is the limit's 429", t do
      Application.put_env(:letflow, AuthAttemptLimit,
        failure_capacity: 1000,
        request_capacity: 2,
        request_refill_per_sec: 0.0001
      )

      Bucket.reset()
      assert 200 == lookup(t.a, "?code=4870001112223", t.va).status
      assert 404 == lookup(t.a, "?code=nothing", t.va).status
      assert 429 == lookup(t.a, "?code=4870001112223", t.va).status
    end

    test "L6 a crash in the lookup is a plain 500 with no detail (INV-8)", t do
      assert {:error, :code_required} == OldAppReads.code_lookup(t.a.schema_name, %{})
      Repo.query!(~s|DROP TABLE "#{t.a.schema_name}".catalog_item_int_ids|)

      conn = lookup(t.a, "?code=4870001112223", t.va)
      assert {conn.status, body(conn)} == {500, %{"error" => "internal error"}}
    end
  end

  # -- L7 -------------------------------------------------------------------------------------------

  describe "read only" do
    test "L7 the lookups write no code, assignment, audit, document or ledger row", t do
      s = t.a.schema_name
      before = snapshot(s)

      for query <- [
            "?code=4870001112223",
            "?code=LOC-RI2",
            "?code=5550000000001",
            "?code=5550000000002",
            "?code=qr-abc",
            "?code=%00",
            "?code=",
            "?code=nothing"
          ] do
        lookup(t.a, query, t.va)
      end

      get(t.a, "/codes/lookup?code=4870001112223", t.va)
      assert snapshot(s) == before

      # only the integer mappings may have been added
      %{rows: [[skus, places]]} =
        Repo.query!(
          ~s|SELECT (SELECT count(*) FROM "#{s}".catalog_item_int_ids), (SELECT count(*) FROM "#{s}".location_node_int_ids)|
        )

      assert skus >= 1 and places >= 1
    end
  end

  defp snapshot(schema) do
    %{rows: [[ledger]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".ledger_entry|)

    tags_and_assignments =
      Repo.all(
        from(l in Latest,
          where: l.entity_type in ["code_tag", "code_assignment"],
          select: {l.entity_type, count(l.record_id)},
          group_by: l.entity_type
        ),
        prefix: schema
      )
      |> Enum.sort()

    {ledger, tags_and_assignments, Repo.aggregate(Entry, :count, prefix: schema),
     SD.counts(schema)}
  end
end
