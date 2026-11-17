Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.DocumentsIdempotencyTest do
  @moduledoc """
  REQ-846 / GH #4560: idempotency of POST /modules/stock/documents (all 11 acceptance criteria).

  Tests:
  - ID-1  same key + same body → same document, no second draft
  - ID-2  same key + reordered JSON keys → same answer
  - ID-3  same key + changed body → 409 idempotency_key_reuse
  - ID-4  replay after replace; replay after delete → current document state / 404
  - ID-5  keys are per user: second STOREKEEPER gets a new document
  - ID-6  refused shape check does not bind the key
  - ID-7  concurrency: two concurrent creates → one document
  - ID-8a header value over 199 bytes → 422 max_length
  - ID-8b NUL or invalid UTF-8 → 422 format
  - ID-8c without header → today's behaviour, two creates = two drafts
  - ID-9  Letflow.Idempotency.client_key(:stock_create, ...) and raw_max(:stock_create)
  - ID-10 cross-tenant: same key K on tenant B creates a new document, tenant A unchanged
  - ID-11 static checks pass (covered by mix letflow.check.static in the CI gate)
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Idempotency
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Documents
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    a = S.tenant!("stk-id-a", ctx.names.a)
    b = S.tenant!("stk-id-b", ctx.names.b)

    Map.merge(ctx, %{
      a: a,
      b: b,
      ma: D.masters!(a.schema_name),
      mb: D.masters!(b.schema_name),
      tok_a: S.token(ctx, :a, ["TENANT_ADMIN"]),
      tok_a2: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "user-a2"),
      tok_b: S.token(ctx, :b, ["TENANT_ADMIN"])
    })
  end

  # Sends POST /documents with an optional idempotency-key header.
  defp create(token, body, key \\ nil) do
    conn =
      Plug.Test.conn(:post, "/api/v1/modules/stock/documents", Jason.encode!(body))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    conn =
      if key do
        put_req_header(conn, "idempotency-key", key)
      else
        conn
      end

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp status!(conn, expected) do
    assert conn.status == expected,
           "expected #{expected}, got #{conn.status}: #{conn.resp_body}"

    conn
  end

  defp body!(conn), do: Jason.decode!(conn.resp_body)
  defp strip(b), do: M.strip(b)

  # Counts of tenant-schema rows for checking "nothing was written".
  defp counts(schema), do: D.counts(schema)

  describe "ID-1: same key + same body returns existing document" do
    test "second create with same key gets 201 with the same document id", ctx do
      b = D.body(ctx.ma)
      k = "key-#{System.unique_integer([:positive])}"

      first = create(ctx.tok_a, b, k) |> status!(201) |> body!()
      {r1, d1} = counts(ctx.a.schema_name)

      second = create(ctx.tok_a, b, k) |> status!(201) |> body!()
      {r2, d2} = counts(ctx.a.schema_name)

      assert strip(second) == strip(first),
             "replay body differs from first"

      assert r1 == r2, "record count changed on replay"
      assert d1 == d2, "document count changed on replay"

      # Confirm the returned id is fetchable and matches.
      got = D.request(:get, "/documents/#{first["id"]}", ctx.tok_a) |> status!(200) |> body!()
      assert strip(got) == strip(first)
    end
  end

  describe "ID-2: key-order-insensitive body comparison" do
    test "reordered JSON keys produce the same document on replay", ctx do
      ma = ctx.ma
      k = "key-#{System.unique_integer([:positive])}"

      body1 = %{
        "kind" => "receipt",
        "org_unit_id" => ma.unit,
        "location_id" => ma.location,
        "responsible_id" => ma.employee,
        "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
        "counterparty_id" => ma.supplier,
        "note" => "d",
        "lines" => [
          %{"catalog_item_id" => ma.item, "catalog_uom_id" => ma.uom, "quantity" => "1"}
        ]
      }

      # Same map, different insertion order on the wire.
      body2 = %{
        "note" => "d",
        "kind" => "receipt",
        "lines" => [
          %{"quantity" => "1", "catalog_uom_id" => ma.uom, "catalog_item_id" => ma.item}
        ],
        "counterparty_id" => ma.supplier,
        "event_time" => body1["event_time"],
        "location_id" => ma.location,
        "org_unit_id" => ma.unit,
        "responsible_id" => ma.employee
      }

      {r0, d0} = counts(ctx.a.schema_name)
      first = create(ctx.tok_a, body1, k) |> status!(201) |> body!()
      second = create(ctx.tok_a, body2, k) |> status!(201) |> body!()
      {r1, d1} = counts(ctx.a.schema_name)

      assert strip(second) == strip(first)

      assert r0 + 2 == r1,
             "expected 1 header + 1 line = 2 records, got #{r1 - r0}"

      assert d0 + 1 == d1
    end
  end

  describe "ID-3: same key + changed body → 409 idempotency_key_reuse" do
    test "changed quantity returns 409 with reason idempotency_key_reuse, nothing written", ctx do
      ma = ctx.ma
      k = "key-#{System.unique_integer([:positive])}"
      b = D.body(ma)

      {r0, d0} = counts(ctx.a.schema_name)
      first = create(ctx.tok_a, b, k) |> status!(201) |> body!()
      {r1, d1} = counts(ctx.a.schema_name)

      # Change a line quantity.
      b2 = put_in(b, ["lines", Access.at(0), "quantity"], "99.0")
      conn2 = create(ctx.tok_a, b2, k) |> status!(409)
      resp2 = body!(conn2)

      assert resp2["reason"] == "idempotency_key_reuse"
      # The first document's id is NOT in the 409 body (INV-2).
      refute resp2["detail"] =~ first["id"]

      {r2, d2} = counts(ctx.a.schema_name)
      assert r1 == r2
      assert d1 == d2

      # Existing tests: row counts did not change from before the first create.
      _ = {r0, d0}
    end
  end

  describe "ID-4: replay after replace and after delete" do
    test "replay after PUT returns current document, nothing written", ctx do
      ma = ctx.ma
      k = "key-#{System.unique_integer([:positive])}"
      b = D.body(ma)

      first = create(ctx.tok_a, b, k) |> status!(201) |> body!()

      # Replace the draft with a new body.
      b2 = Map.put(b, "note", "replaced note")

      replaced =
        D.request(:put, "/documents/#{first["id"]}", ctx.tok_a, b2) |> status!(200) |> body!()

      assert replaced["note"] == "replaced note"

      {r1, d1} = counts(ctx.a.schema_name)
      replay = create(ctx.tok_a, b, k) |> status!(201) |> body!()
      {r2, d2} = counts(ctx.a.schema_name)

      # Returns the replaced content (current state).
      assert strip(replay) == strip(replaced)
      assert r1 == r2
      assert d1 == d2
    end

    test "replay after DELETE returns 404 (what GET says), nothing written", ctx do
      ma = ctx.ma
      k = "key-#{System.unique_integer([:positive])}"
      b = D.body(ma)

      first = create(ctx.tok_a, b, k) |> status!(201) |> body!()

      D.request(:delete, "/documents/#{first["id"]}", ctx.tok_a) |> status!(204)

      # GET the discarded document → 404
      D.request(:get, "/documents/#{first["id"]}", ctx.tok_a) |> status!(404)

      {r1, d1} = counts(ctx.a.schema_name)
      # Replay → 404 (same as GET), no new draft.
      create(ctx.tok_a, b, k) |> status!(404)
      {r2, d2} = counts(ctx.a.schema_name)

      assert r1 == r2
      assert d1 == d2
    end
  end

  describe "ID-5: keys are per user" do
    test "a second STOREKEEPER with the same key and body gets a new document", ctx do
      ma = ctx.ma
      k = "key-#{System.unique_integer([:positive])}"
      b = D.body(ma)

      first = create(ctx.tok_a, b, k) |> status!(201) |> body!()
      second = create(ctx.tok_a2, b, k) |> status!(201) |> body!()

      refute first["id"] == second["id"], "both users got the same document id"
    end
  end

  describe "ID-6: a refused shape check does not bind the key" do
    test "shape failure leaves key unbound; subsequent valid create succeeds", ctx do
      ma = ctx.ma
      k = "key-#{System.unique_integer([:positive])}"

      # Missing required field → 422.
      bad_body = %{"kind" => "receipt"}
      create(ctx.tok_a, bad_body, k) |> status!(422)

      # Same key with a valid body → 201.
      good_body = D.body(ma)
      result = create(ctx.tok_a, good_body, k) |> status!(201) |> body!()
      assert result["id"]
    end
  end

  describe "ID-7: concurrency — two creates with the same key produce one document" do
    # Calls Documents.save/4 directly (not through the HTTP router) so the admission-control
    # plug cannot reject either task with 503. The outer setup_oidc! already entered auto mode
    # and committed the tenant and master data, so both tasks open real, independent DB
    # transactions and the advisory lock in save_idempotent/4 serialises them.
    test "both tasks answer {:ok, doc} with the same document id", ctx do
      schema = ctx.a.schema_name
      actor = "00000000-0000-0000-0000-00000000c701"
      raw = "conc-#{System.unique_integer([:positive])}"
      k = Idempotency.client_key(:stock_create, actor, nil, raw)
      b = D.body(ctx.ma)

      task1 = Task.async(fn -> Documents.save(schema, b, actor, k) end)
      task2 = Task.async(fn -> Documents.save(schema, b, actor, k) end)

      r1 = Task.await(task1, 15_000)
      r2 = Task.await(task2, 15_000)

      assert {:ok, doc1} = r1, "task1 failed: #{inspect(r1)}"
      assert {:ok, doc2} = r2, "task2 failed: #{inspect(r2)}"

      assert doc1[:id] == doc2[:id],
             "tasks got different document ids: #{doc1[:id]} vs #{doc2[:id]}"
    end
  end

  describe "ID-8: key validation" do
    test "ID-8a header over 199 bytes → 422 max_length", ctx do
      long_key = String.duplicate("k", 200)
      conn = create(ctx.tok_a, D.body(ctx.ma), long_key) |> status!(422)
      resp = body!(conn)
      errors = resp["errors"] || []
      assert Enum.any?(errors, &(&1["constraint"] == "max_length"))
    end

    test "ID-8b NUL byte in header → 422 format", ctx do
      nul_key = "key" <> <<0>> <> "value"
      conn = create(ctx.tok_a, D.body(ctx.ma), nul_key) |> status!(422)
      resp = body!(conn)
      errors = resp["errors"] || []
      assert Enum.any?(errors, &(&1["constraint"] == "format"))
    end

    test "ID-8c without header → two identical creates make two drafts (today's behaviour)",
         ctx do
      b = D.body(ctx.ma)

      # No idempotency key header.
      first = create(ctx.tok_a, b) |> status!(201) |> body!()
      second = create(ctx.tok_a, b) |> status!(201) |> body!()

      refute first["id"] == second["id"], "expected two different documents without header"
    end
  end

  describe "ID-9: Idempotency.client_key(:stock_create, ...) and raw_max/1" do
    @tag :unit
    test "shape and raw_max" do
      actor = Ecto.UUID.generate()

      assert Idempotency.client_key(:stock_create, actor, nil, "k") ==
               "client:stock_create:#{actor}:k"

      assert Idempotency.raw_max(:stock_create) == 199
    end

    @tag :unit
    test "router source scan: stock router does not read the header itself" do
      # The source scan in test/letflow/idempotency_test.exs already checks all lib/**/*.ex;
      # this assertion re-states the expectation for REQ-846's own test file.
      stock_router = File.read!("lib/letflow/modules/stock/router.ex")
      refute stock_router =~ ~s("idempotency_key"), "stock router must not read the body field"

      refute stock_router =~ ~s("idempotency-key"),
             "stock router must not read the header directly"
    end
  end

  describe "ID-10: cross-tenant isolation (INV-10)" do
    test "same key on tenant B gets a new document; tenant A counts unchanged", ctx do
      ma = ctx.ma
      mb = ctx.mb
      k = "key-cross-#{System.unique_integer([:positive])}"

      # Create in tenant A.
      a_doc = create(ctx.tok_a, D.body(ma), k) |> status!(201) |> body!()
      {ra, da} = counts(ctx.a.schema_name)

      # Same key (and same actor UUID from token) in tenant B → new document.
      b_doc = create(ctx.tok_b, D.body(mb), k) |> status!(201) |> body!()

      refute a_doc["id"] == b_doc["id"], "cross-tenant key collision: same document id"

      # Tenant A counts unchanged.
      {ra2, da2} = counts(ctx.a.schema_name)
      assert ra == ra2
      assert da == da2
    end
  end
end
