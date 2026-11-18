Code.require_file("documents_fixture.exs", __DIR__)
Code.require_file("posting_fixture.exs", __DIR__)

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

  REQ-847 / GH #4559: idempotency of POST /documents/:id/issue and /post (criteria 1 to 8):
  - IS-1  issue replay: same answer as GET, one number, one posting instance
  - PO-2  post replay: one instance, also after the post task completed (one ledger entry)
  - IS-3 / PO-3  the key used on another document: 409 idempotency_key_reuse, nothing of A leaks
  - IS-4  no key / new key: today's 409s
  - IS-5  a refused issue binds nothing
  - IS-6  per user and per action; over-long and invalid keys 422
  - IS-7  cross-tenant: tenant B gets the unknown-document 404
  - IS-8  Idempotency pins of the two new families and the concurrent issue
  """

  use Letflow.DataCase, async: false

  import Plug.Conn

  alias Letflow.Idempotency
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Documents
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    a = S.tenant!("stk-id-a", ctx.names.a)
    b = S.tenant!("stk-id-b", ctx.names.b)

    Map.merge(ctx, %{
      a: a,
      b: b,
      schema: a.schema_name,
      holder: Letflow.Support.TokenMintFixture.role_holder!(a.schema_name, ["TENANT_ADMIN"]),
      ma: D.masters!(a.schema_name),
      mb: D.masters!(b.schema_name),
      # the criteria name a STOREKEEPER: the creators are storekeepers, the admin only reads
      tok_admin: S.token(ctx, :a, ["TENANT_ADMIN"]),
      tok_a: S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-a"),
      tok_admin2: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a2"),
      tok_a2: S.token(ctx, :a, ["STOREKEEPER"], sub: "keeper-a2"),
      tok_b: S.token(ctx, :b, ["STOREKEEPER"], sub: "keeper-a")
    })
  end

  # Sends POST /documents with an optional idempotency-key header. `body` is a map (encoded
  # here) or an already-encoded JSON string (sent as given, byte for byte).
  defp create(token, body, key \\ nil) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    conn =
      Plug.Test.conn(:post, "/api/v1/modules/stock/documents", raw)
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

      raw1 = Jason.encode!(body1)

      # The same document as a hand-built JSON string: top-level keys and the line's keys in
      # another order, extra whitespace. An Elixir map has no key order, so only a raw string
      # puts different bytes on the wire.
      raw2 =
        ~s({ "note": "d",\n  "kind": "receipt",\n  "lines": [ {"quantity": "1", ) <>
          ~s("catalog_uom_id": "#{ma.uom}", "catalog_item_id": "#{ma.item}"} ],\n  ) <>
          ~s("counterparty_id": "#{ma.supplier}", "event_time": "#{body1["event_time"]}", ) <>
          ~s("location_id": "#{ma.location}", "org_unit_id": "#{ma.unit}", ) <>
          ~s("responsible_id": "#{ma.employee}" })

      # the bytes really differ, the documents do not
      refute raw2 == raw1
      assert Jason.decode!(raw2) == body1

      {r0, d0} = counts(ctx.a.schema_name)
      first = create(ctx.tok_a, raw1, k) |> status!(201) |> body!()
      second = create(ctx.tok_a, raw2, k) |> status!(201) |> body!()
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
      # distinctive values so that a leak of any of them into the 409 body is visible
      b =
        D.body(ma, nil, %{"note" => "uniq-note-7Q"})
        |> put_in(["lines", Access.at(0), "quantity"], "7.25")

      {r0, d0} = counts(ctx.a.schema_name)
      first = create(ctx.tok_a, b, k) |> status!(201) |> body!()
      {r1, d1} = counts(ctx.a.schema_name)
      assert {r1, d1} != {r0, d0}

      # Change a line quantity.
      b2 = put_in(b, ["lines", Access.at(0), "quantity"], "99.0")
      conn2 = create(ctx.tok_a, b2, k) |> status!(409)
      resp2 = body!(conn2)

      assert resp2["reason"] == "idempotency_key_reuse"

      # Neither the first document's id nor any of its field values is in the 409 body
      # (INV-2): checked on the raw body, so no field or extension can leak them.
      leaked =
        [first["id"], first["note"], "7.25", first["org_unit_id"], first["number"]] ++
          Enum.flat_map(first["lines"] || [], &[&1["id"]])

      for v <- Enum.filter(leaked, &is_binary/1) do
        refute conn2.resp_body =~ v, "the 409 body leaks #{inspect(v)}"
      end

      # Nothing was written by the refused request.
      assert counts(ctx.a.schema_name) == {r1, d1}
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
      get_conn = D.request(:get, "/documents/#{first["id"]}", ctx.tok_a) |> status!(404)

      {r1, d1} = counts(ctx.a.schema_name)
      # Replay → what GET answers (status and body, trace_id aside), no new draft.
      replay_conn = create(ctx.tok_a, b, k) |> status!(404)
      {r2, d2} = counts(ctx.a.schema_name)

      assert strip(body!(replay_conn)) == strip(body!(get_conn))
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
      {r0, d0} = counts(schema)

      task1 = Task.async(fn -> Documents.save(schema, b, actor, k) end)
      task2 = Task.async(fn -> Documents.save(schema, b, actor, k) end)

      r1 = Task.await(task1, 15_000)
      r2 = Task.await(task2, 15_000)

      assert {:ok, doc1} = r1, "task1 failed: #{inspect(r1)}"
      assert {:ok, doc2} = r2, "task2 failed: #{inspect(r2)}"

      assert doc1[:id] == doc2[:id],
             "tasks got different document ids: #{doc1[:id]} vs #{doc2[:id]}"

      # Exactly one document exists afterwards: one header and its two lines (D.body).
      {r1, d1} = counts(schema)
      assert d1 == d0 + 1
      assert r1 == r0 + 1 + length(b["lines"])
    end
  end

  describe "ID-8: key validation" do
    test "ID-8a header over 199 bytes → 422 max_length", ctx do
      long_key = String.duplicate("k", 200)
      before = counts(ctx.a.schema_name)
      conn = create(ctx.tok_a, D.body(ctx.ma), long_key) |> status!(422)
      resp = body!(conn)
      errors = resp["errors"] || []
      assert Enum.any?(errors, &(&1["constraint"] == "max_length"))
      assert counts(ctx.a.schema_name) == before
    end

    test "ID-8b NUL byte in header → 422 format", ctx do
      nul_key = "key" <> <<0>> <> "value"
      before = counts(ctx.a.schema_name)
      conn = create(ctx.tok_a, D.body(ctx.ma), nul_key) |> status!(422)
      resp = body!(conn)
      errors = resp["errors"] || []
      assert Enum.any?(errors, &(&1["constraint"] == "format"))
      assert counts(ctx.a.schema_name) == before
    end

    test "ID-8b2 invalid UTF-8 in the header → 422 format, nothing written", ctx do
      bad_key = <<0xFF, 0xFE>>
      assert not String.valid?(bad_key)
      before = counts(ctx.a.schema_name)
      conn = create(ctx.tok_a, D.body(ctx.ma), bad_key) |> status!(422)
      resp = body!(conn)
      errors = resp["errors"] || []
      assert Enum.any?(errors, &(&1["constraint"] == "format"))
      assert counts(ctx.a.schema_name) == before
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

  # -- REQ-847: issue and post ---------------------------------------------------------------------

  defp act(token, id, action, key \\ nil) do
    conn =
      Plug.Test.conn(:post, "/api/v1/modules/stock/documents/#{id}/#{action}")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")

    conn = if key, do: put_req_header(conn, "idempotency-key", key), else: conn
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp draft!(ctx, token \\ nil),
    do: create(token || ctx.tok_a, D.body(ctx.ma)) |> status!(201) |> body!()

  defp get!(ctx, id, token \\ nil),
    do: D.request(:get, "/documents/#{id}", token || ctx.tok_a) |> status!(200) |> body!()

  defp reason(conn, status), do: conn |> status!(status) |> body!() |> Map.get("reason")
  defp key, do: "k-#{System.unique_integer([:positive])}"

  defp instances(ctx, id) do
    import Ecto.Query, only: [from: 2]

    Letflow.Repo.aggregate(
      from(p in Letflow.EventStore.InstanceProjection,
        where: fragment("?->>'document_id' = ?", p.variables, ^id)
      ),
      :count,
      prefix: ctx.schema
    )
  end

  # An issued document whose posting instance was not started (the case the post route is for).
  defp issued_unstarted!(ctx) do
    Application.put_env(:letflow, :stock_post_start_fail?, true)
    on_exit(fn -> Application.delete_env(:letflow, :stock_post_start_fail?) end)
    doc = draft!(ctx)
    issued = act(ctx.tok_admin, doc["id"], "issue") |> status!(200) |> body!()
    Application.delete_env(:letflow, :stock_post_start_fail?)
    assert instances(ctx, doc["id"]) == 0
    issued
  end

  describe "IS-1: issue replay" do
    test "same key again answers 200 like GET; one number, one instance", ctx do
      doc = draft!(ctx)
      k = key()

      first = act(ctx.tok_admin, doc["id"], "issue", k) |> status!(200) |> body!()
      assert first["state"] == "issued"
      second = act(ctx.tok_admin, doc["id"], "issue", k) |> status!(200) |> body!()

      assert strip(second) == strip(get!(ctx, doc["id"]))
      assert second["number"] == first["number"]
      assert instances(ctx, doc["id"]) == 1
    end
  end

  describe "PO-2: post replay" do
    test "one instance for the retry and its replay; the replay after posting is the posted doc",
         ctx do
      issued = issued_unstarted!(ctx)
      id = issued["id"]
      k = key()

      first = act(ctx.tok_admin, id, "post", k) |> status!(200) |> body!()
      assert instances(ctx, id) == 1
      second = act(ctx.tok_admin, id, "post", k) |> status!(200) |> body!()
      assert strip(second) == strip(get!(ctx, id))
      assert strip(second) == strip(first)
      assert instances(ctx, id) == 1

      task = P.pending_task(ctx, id, "post") || flunk("no pending post task")
      assert {:ok, _} = P.complete(ctx, task)

      third = act(ctx.tok_admin, id, "post", k) |> status!(200) |> body!()
      assert third["state"] == "posted"
      assert strip(third) == strip(get!(ctx, id))
      assert instances(ctx, id) == 1
      assert P.counts(ctx, id).entries == %{"receipt" => 1}
    end
  end

  describe "IS-3 / PO-3: a key used on another document" do
    test "issue: 409 idempotency_key_reuse, B stays a draft, nothing of A in the body", ctx do
      a = draft!(ctx)
      b = draft!(ctx)
      k = key()
      issued_a = act(ctx.tok_admin, a["id"], "issue", k) |> status!(200) |> body!()

      conn = act(ctx.tok_admin, b["id"], "issue", k)
      assert reason(conn, 409) == "idempotency_key_reuse"
      refute conn.resp_body =~ a["id"]
      refute conn.resp_body =~ to_string(issued_a["number"])

      gb = get!(ctx, b["id"])
      assert gb["state"] == "draft"
      assert gb["number"] in [nil, ""]
      assert instances(ctx, b["id"]) == 0
    end

    test "post: 409 idempotency_key_reuse on another document, nothing of A in the body", ctx do
      a = issued_unstarted!(ctx)
      b = issued_unstarted!(ctx)
      k = key()
      act(ctx.tok_admin, a["id"], "post", k) |> status!(200)

      conn = act(ctx.tok_admin, b["id"], "post", k)
      assert reason(conn, 409) == "idempotency_key_reuse"
      refute conn.resp_body =~ a["id"]
      assert instances(ctx, b["id"]) == 0
    end
  end

  describe "IS-4: without the key or with a new key" do
    test "today's 409 answers stay", ctx do
      doc = draft!(ctx)
      act(ctx.tok_admin, doc["id"], "issue") |> status!(200)
      assert reason(act(ctx.tok_admin, doc["id"], "issue"), 409) == "document_not_draft"
      assert reason(act(ctx.tok_admin, doc["id"], "issue", key()), 409) == "document_not_draft"

      # the issue started the posting: its task is pending
      assert reason(act(ctx.tok_admin, doc["id"], "post"), 409) == "posting_pending"
      assert reason(act(ctx.tok_admin, doc["id"], "post", key()), 409) == "posting_pending"

      task = P.pending_task(ctx, doc["id"], "post") || flunk("no pending post task")
      assert {:ok, _} = P.complete(ctx, task)
      assert reason(act(ctx.tok_admin, doc["id"], "post"), 409) == "document_posted"
      assert reason(act(ctx.tok_admin, doc["id"], "post", key()), 409) == "document_posted"
    end
  end

  describe "IS-5: a refused issue binds nothing" do
    test "422 leaves the key free; after the fix the same key issues once", ctx do
      stale = D.body(ctx.ma, "2026-01-01T00:00:00Z")
      doc = create(ctx.tok_a, stale) |> status!(201) |> body!()
      k = key()

      assert reason(act(ctx.tok_admin, doc["id"], "issue", k), 422) == "event_time_too_old"

      D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, D.body(ctx.ma)) |> status!(200)
      issued = act(ctx.tok_admin, doc["id"], "issue", k) |> status!(200) |> body!()
      assert issued["state"] == "issued"
      assert instances(ctx, doc["id"]) == 1
    end
  end

  describe "IS-6: per user and per action; key checks" do
    test "a create key may be used on issue by the same user; a second user gets 409", ctx do
      # activates the stock_receipt definition (needs an admin), so a storekeeper can issue
      act(ctx.tok_admin, draft!(ctx)["id"], "issue") |> status!(200)

      k = key()
      doc = create(ctx.tok_a, D.body(ctx.ma), k) |> status!(201) |> body!()

      # the SAME user (keeper-a) issues with the key K it used on create: no conflict, really issued
      issued = act(ctx.tok_a, doc["id"], "issue", k) |> status!(200) |> body!()
      assert issued["state"] == "issued"
      assert is_binary(issued["number"]) or is_integer(issued["number"])
      assert instances(ctx, doc["id"]) == 1

      # same user, same document, same key again: replay (not a conflict), no second instance
      replay = act(ctx.tok_a, doc["id"], "issue", k) |> status!(200) |> body!()
      assert replay["number"] == issued["number"]
      assert instances(ctx, doc["id"]) == 1

      # a second storekeeper with the same key: no replay of the first user's answer
      assert reason(act(ctx.tok_a2, doc["id"], "issue", k), 409) == "document_not_draft"
    end

    test "over-long and invalid keys are 422 and write nothing", ctx do
      doc = draft!(ctx)

      for action <- ["issue", "post"] do
        long = act(ctx.tok_admin, doc["id"], action, String.duplicate("k", 200)) |> status!(422)
        assert Enum.any?(body!(long)["errors"], &(&1["constraint"] == "max_length"))
        nul = act(ctx.tok_admin, doc["id"], action, "a" <> <<0>> <> "b") |> status!(422)
        assert Enum.any?(body!(nul)["errors"], &(&1["constraint"] == "format"))
      end

      assert get!(ctx, doc["id"])["state"] == "draft"
    end
  end

  describe "IS-7: cross-tenant (INV-10)" do
    test "tenant B with A's document id and key gets the unknown-document 404", ctx do
      doc = draft!(ctx)
      k = key()
      act(ctx.tok_admin, doc["id"], "issue", k) |> status!(200)
      before = get!(ctx, doc["id"])

      for action <- ["issue", "post"] do
        unknown = act(ctx.tok_b, Ecto.UUID.generate(), action, k) |> status!(404)
        other = act(ctx.tok_b, doc["id"], action, k) |> status!(404)

        assert other.resp_body |> Jason.decode!() |> strip() ==
                 unknown.resp_body |> Jason.decode!() |> strip()
      end

      assert get!(ctx, doc["id"]) == before
    end
  end

  describe "IS-8: families and concurrency" do
    @tag :unit
    test "the two families are pinned" do
      actor = Ecto.UUID.generate()

      assert Idempotency.client_key(:stock_issue, actor, nil, "k") ==
               "client:stock_issue:#{actor}:k"

      assert Idempotency.client_key(:stock_post, actor, nil, "k") ==
               "client:stock_post:#{actor}:k"

      assert Idempotency.raw_max(:stock_issue) == 199
      assert Idempotency.raw_max(:stock_post) == 199
    end

    test "two concurrent issues with one key: one number, one instance", ctx do
      # activates the stock_receipt definition (needs an admin), as any first issue does
      act(ctx.tok_admin, draft!(ctx)["id"], "issue") |> status!(200)
      doc = draft!(ctx)
      actor = ctx.holder.id

      k =
        Idempotency.client_key(
          :stock_issue,
          actor,
          nil,
          "conc-#{System.unique_integer([:positive])}"
        )

      opts = [activator: nil, authorized: nil, idempotency_key: k]

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Documents.issue(ctx.schema, doc["id"], actor, opts) end)
        end

      assert [{:ok, d1}, {:ok, d2}] = Enum.map(tasks, &Task.await(&1, 30_000))
      assert d1.id == d2.id
      assert d1.number == d2.number
      assert instances(ctx, doc["id"]) == 1
    end
  end
end
