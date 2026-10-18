defmodule Letflow.Routers.EntitiesScopeWritesHttpTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii (design `lib/letflow/design/req518-compiler-scope-filter.md`
  5.2 to 5.4, 5.7, 10.2; spec `test/specs/REQ-518-2c-ii.md`; SEC code-gate step-17 merge
  conditions): the generic record WRITE routes (POST, PUT, DELETE, import) for a SCOPED caller,
  through the FULL `Letflow.Router` on the test-only `fixture_scoped` tenant (stored mode `on`,
  a real OIDC user whose `TENANT_ADMIN` role is held ONLY at the subtree `a`: allowed nodes
  `sf-a`, `sf-a1`, `sf-a2x`; `sf-a2` and `sf-a3` are retired).

    * T-W1 / T-W19: an out-of-scope id (existing, in every other subtree, NULL-scope, retired
      node, already deleted) answers byte for byte like a nonexistent id (status, headers, body),
      runs the SAME SQL statements in the same order, and fires exactly one counted
      `[:letflow, :scope, :not_found]` event with the closed metadata `%{policy, kind}`;
    * T-W3: a malformed or schema-invalid body (and a bad `expected_last_event_global_seq` query
      parameter) for an out-of-scope id is that same 404, never a 400/422;
    * T-W4 / T-W5 / T-W7: the NEW value is checked: a PUT moving a record out of scope, a POST
      with an out-of-scope, NULL, retired, nonexistent or malformed node are the SAME 404 and
      write nothing; a tenant-wide caller may still create a NULL-scope record; a field-level
      grant does not lift the scope check;
    * T-W2: an out-of-scope id or node used as a query filter value is the empty page of a
      nonexistent one;
    * T-W9 / T-W10: import is all-or-nothing for a scoped caller (one answer, zero rows written,
      whichever row or reason), structural checks come first, an in-scope batch is partial
      success per entry as today, `upsert_by: external_ref` is refused;
    * T-W11 / T-W12 / AC 10: revocation (grant swapped or removed, subtree moved) is seen by the
      NEXT request; a cursor carries no set;
    * T-W22 / T-W23: an idempotency replay never confirms a record to a caller whose new value is
      out of scope; an undeclared, `:tenant_wide` and nonexistent type are the same bytes;
    * T-L4 to T-L11: the eight routes are `{:resolver, {ScopeResolver, :record_scope}}`, in scope
      succeeds and out of scope is refused.

  `async: false`: a dedicated provisioned OIDC tenant (sandbox `:auto`), committed writes, the
  VM-global `:oidc` config swap and telemetry handlers.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ScopeResolver
  alias Letflow.Support.RouteInventory
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopeWritesFixture, as: W

  @in_a [:a, :a1, :a2x]
  @out_of_scope [:root, :a2, :a3, :b, :b1, :none]
  @type_item "scoped_item"

  setup do
    {:ok, fx: W.provision!("r518-w")}
  end

  # ---- helpers ------------------------------------------------------------------------------

  defp absent_id, do: Ecto.UUID.generate()

  defp put_item(fx, id, body),
    do: W.request(fx, :put, W.records_path(@type_item, id), body)

  # the canonical generic 404 of a scoped caller: PUT of a nonexistent id with a valid body
  defp canonical(fx), do: fx |> put_item(absent_id(), W.item_body("sf-a")) |> W.norm()

  defp node_value(fx, key), do: W.stored_values(fx, @type_item, fx.items[key].record_id)

  # ===========================================================================================
  describe "T-W1 / T-W19 PUT: an out-of-scope id is a nonexistent id" do
    test "status, headers and body equal; same statements; one counted event of closed shape; nothing written",
         %{fx: fx} do
      ref = W.attach_not_found!()
      body = W.item_body("sf-a")

      # warm-up (first-touch caches), then the measured nonexistent reference
      _warm = put_item(fx, absent_id(), body)
      _ = W.drain_not_found(ref)
      {absent_conn, absent_sql} = W.statements(fn -> put_item(fx, absent_id(), body) end)
      absent_events = W.drain_not_found(ref)
      absent = W.norm(absent_conn)

      assert {404, headers, _body} = absent
      names = Enum.map(headers, &elem(&1, 0))
      refute "etag" in names
      refute "last-modified" in names

      assert [
               {%{count: 1}, %{policy: :EntitiesRecordsWrite, kind: :by_id}} = event
             ] = absent_events

      assert event |> elem(1) |> Map.keys() |> Enum.sort() == [:kind, :policy]

      before = W.counts(fx)

      for key <- @out_of_scope do
        id = fx.items[key].record_id
        {conn, sql} = W.statements(fn -> put_item(fx, id, body) end)

        assert W.norm(conn) == absent, "#{key}: status, headers and body"
        refute conn.resp_body =~ id, "#{key}: the id is never echoed"
        assert sql == absent_sql, "#{key}: the same statements in the same order"
        assert W.drain_not_found(ref) == absent_events, "#{key}: the one counted event"
        assert node_value(fx, key)["name"] == "item-#{key}", "#{key}: untouched"
      end

      assert W.counts(fx) == before, "no row, event, attachment or artifact was written"
    end

    test "an out-of-scope record that is already DELETED is the same 404 (deleted is not part of the predicate)",
         %{fx: fx} do
      assert W.admin_request(
               fx,
               :delete,
               W.records_path(@type_item, fx.items.b.record_id),
               nil
             ).status == 200

      conn = put_item(fx, fx.items.b.record_id, W.item_body("sf-a"))
      assert W.norm(conn) == canonical(fx)

      deleted = W.request(fx, :delete, W.records_path(@type_item, fx.items.b.record_id), nil)
      assert W.norm(deleted) == canonical(fx)
    end
  end

  describe "T-W1 / T-W19 DELETE: an out-of-scope id is a nonexistent id" do
    test "equal bytes and statements for every out-of-scope key, also with a bad query parameter; nothing deleted",
         %{fx: fx} do
      ref = W.attach_not_found!()

      for query <- [
            "",
            "?expected_last_event_global_seq=abc",
            "?expected_last_event_global_seq=0"
          ] do
        del = fn id ->
          W.request(fx, :delete, W.records_path(@type_item, id) <> query, nil)
        end

        _warm = del.(absent_id())
        _ = W.drain_not_found(ref)
        {absent_conn, absent_sql} = W.statements(fn -> del.(absent_id()) end)
        absent_events = W.drain_not_found(ref)
        absent = W.norm(absent_conn)

        assert {404, _headers, _body} = absent, query
        assert [{%{count: 1}, %{policy: :EntitiesRecordsWrite, kind: :by_id}}] = absent_events

        before = W.counts(fx)

        for key <- @out_of_scope do
          {conn, sql} = W.statements(fn -> del.(fx.items[key].record_id) end)

          assert W.norm(conn) == absent, "#{key} #{query}"
          assert sql == absent_sql, "#{key} #{query}"
          assert W.drain_not_found(ref) == absent_events, "#{key} #{query}"
          assert node_value(fx, key), "#{key}: the record is still stored"
          assert W.stored_row(fx, @type_item, fx.items[key].record_id).deleted == false
        end

        assert W.counts(fx) == before, query
      end
    end

    test "a malformed id is the same generic 404 (no lookup)", %{fx: fx} do
      conn = W.request(fx, :delete, W.records_path(@type_item, "not-a-uuid"), nil)
      assert W.norm(conn) == canonical(fx)
    end
  end

  # ===========================================================================================
  describe "T-W3 scope before body: a bad body for an out-of-scope id is the same 404" do
    @bad_bodies [
      "[]",
      "5",
      "{}",
      ~s({"field_values": 5}),
      ~s({"field_values": {"scope_node": "sf-a"}, "idempotency_key": "#{String.duplicate("k", 300)}"}),
      ~s({"field_values": {}, "expected_last_event_global_seq": "x"})
    ]

    test "bad PUT bodies: out-of-scope and nonexistent ids give the canonical 404, an in-scope id its own 400/422",
         %{fx: fx} do
      canonical = canonical(fx)

      for raw <- @bad_bodies do
        for id <- [fx.items.b.record_id, fx.items.none.record_id, absent_id()] do
          conn = W.raw_request(fx, :put, W.records_path(@type_item, id), raw)
          assert W.norm(conn) == canonical, "#{id} <- #{raw}"
        end

        in_scope = W.raw_request(fx, :put, W.records_path(@type_item, fx.items.a.record_id), raw)
        assert in_scope.status in [400, 422], "the in-scope id validates the body: #{raw}"
      end
    end
  end

  # ===========================================================================================
  describe "in scope the routes work as before (T-L5, T-L6)" do
    test "PUT within the subtree, DELETE, and DELETE again (already deleted is a 200 no-op)", %{
      fx: fx
    } do
      put = put_item(fx, fx.items.a1.record_id, W.item_body("sf-a2x", name: "renamed"))
      assert put.status == 200, put.resp_body
      stored = node_value(fx, :a1)
      assert stored["name"] == "renamed"
      assert stored["scope_node"] == "sf-a2x"

      del = W.request(fx, :delete, W.records_path(@type_item, fx.items.a2x.record_id), nil)
      assert del.status == 200, del.resp_body
      assert W.stored_row(fx, @type_item, fx.items.a2x.record_id).deleted == true

      again = W.request(fx, :delete, W.records_path(@type_item, fx.items.a2x.record_id), nil)
      assert again.status == 200
    end
  end

  # ===========================================================================================
  describe "T-W4 the NEW value of a PUT is checked" do
    @refused_values [
      {"another subtree", "sf-b"},
      {"the shared root", "sf-root"},
      {"a retired leaf", "sf-a3"},
      {"a retired intermediate node", "sf-a2"},
      {"a nonexistent node", "no-such-node"},
      {"a node differing only by case", "SF-A"},
      {"a node with a leading blank", " sf-a"},
      {"a LIKE metacharacter", "sf-a%"},
      {"the empty string", ""},
      {"JSON null", nil},
      {"a number", 5},
      {"a list", ["sf-a"]},
      {"an object", %{"x" => 1}},
      {"an absent field", :omit}
    ]

    test "moving a record out of scope, to NULL, to a retired, nonexistent or malformed node is the canonical 404 and changes nothing",
         %{fx: fx} do
      ref = W.attach_not_found!()
      canonical = canonical(fx)
      _ = W.drain_not_found(ref)
      before = W.counts(fx)

      for {label, value} <- @refused_values do
        conn = put_item(fx, fx.items.a.record_id, W.item_body(value, name: "moved"))

        assert W.norm(conn) == canonical, label

        assert [{%{count: 1}, %{policy: :EntitiesRecordsWrite, kind: :write_value}}] =
                 W.drain_not_found(ref),
               label

        stored = node_value(fx, :a)
        assert stored["name"] == "item-a", label
        assert stored["scope_node"] == "sf-a", label
      end

      assert W.counts(fx) == before
    end

    test "moving a record within the subtree, to a live descendant of a retired node, succeeds",
         %{fx: fx} do
      for target <- ["sf-a1", "sf-a2x", "sf-a"] do
        conn = put_item(fx, fx.items.a.record_id, W.item_body(target))
        assert conn.status == 200, target
        assert node_value(fx, :a)["scope_node"] == target
      end
    end
  end

  # ===========================================================================================
  describe "T-W5 POST create (scoped caller)" do
    test "in-scope creates (201); every refused value is the canonical 404 and writes nothing",
         %{fx: fx} do
      ref = W.attach_not_found!()
      canonical = canonical(fx)
      _ = W.drain_not_found(ref)

      for node <- ["sf-a", "sf-a1", "sf-a2x"] do
        conn = W.request(fx, :post, W.records_path(@type_item, nil), W.item_body(node))
        assert conn.status == 201, "#{node}: #{conn.resp_body}"
        record_id = W.json(conn)["record_id"]
        assert W.stored_values(fx, @type_item, record_id)["scope_node"] == node
      end

      before = W.counts(fx)
      _ = W.drain_not_found(ref)

      for {label, value} <- @refused_values do
        conn = W.request(fx, :post, W.records_path(@type_item, nil), W.item_body(value))

        assert W.norm(conn) == canonical, label

        assert [{%{count: 1}, %{policy: :EntitiesRecordsWrite, kind: :write_value}}] =
                 W.drain_not_found(ref),
               label
      end

      assert W.counts(fx) == before, "nothing was written by any refused create"
    end

    test "a tenant-wide caller may create a NULL-scope record; the scoped caller then cannot see or change it",
         %{fx: fx} do
      created = W.admin_request(fx, :post, W.records_path(@type_item, nil), W.item_body(:omit))
      assert created.status == 201, created.resp_body
      record_id = W.json(created)["record_id"]
      assert W.stored_values(fx, @type_item, record_id)["name"] == "written"

      assert W.norm(put_item(fx, record_id, W.item_body("sf-a"))) == canonical(fx)

      assert W.norm(W.request(fx, :delete, W.records_path(@type_item, record_id), nil)) ==
               canonical(fx)

      assert W.stored_row(fx, @type_item, record_id).deleted == false
    end
  end

  # ===========================================================================================
  describe "T-W7 a field-level grant does not lift the scope check" do
    defp restrict_scope_field!(fx) do
      now = NaiveDateTime.utc_now()

      Repo.insert_all(
        "entity_field_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: @type_item,
            field_name: "scope_node",
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: fx.schema_name
      )
    end

    test "without the grant the restricted field is 403; with it out of scope is still 404",
         %{fx: fx} do
      canonical = canonical(fx)
      restrict_scope_field!(fx)

      no_grant =
        W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-b"))

      assert no_grant.status == 404,
             "scope first: an out-of-scope value is refused before the restriction is looked at"

      in_scope_no_grant =
        W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-a"))

      assert in_scope_no_grant.status == 403
      assert W.stored_values(fx, @type_item, fx.items.a.record_id)["scope_node"] == "sf-a"

      # the actor receives the grant
      Repo.insert_all(
        "user_entity_grants",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            user_id: Ecto.UUID.dump!(fx.user_id),
            entity_type: @type_item,
            field_name: "scope_node",
            inserted_at: NaiveDateTime.utc_now()
          }
        ],
        prefix: fx.schema_name
      )

      before = W.counts(fx)

      refused_post = W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-b"))
      assert W.norm(refused_post) == canonical

      refused_put = put_item(fx, fx.items.a.record_id, W.item_body("sf-b"))
      assert W.norm(refused_put) == canonical
      assert W.counts(fx) == before

      ok = put_item(fx, fx.items.a.record_id, W.item_body("sf-a1"))
      assert ok.status == 200, ok.resp_body
    end
  end

  # ===========================================================================================
  describe "T-W2 an out-of-scope id or node as a QUERY filter value is the empty page of a nonexistent one" do
    test "name, node and id filters", %{fx: fx} do
      query = fn field, value ->
        conn =
          W.request(fx, :post, "/api/v1/entities/query", %{
            "entity_type" => @type_item,
            "filters" => [%{"field" => field, "op" => "eq", "value" => value}]
          })

        {conn.status, W.json(conn)}
      end

      for {field, out_of_scope, nonexistent} <- [
            {"scope_node", "sf-b", "no-such-node"},
            {"name", "item-b", "item-none-existing"},
            {"name", fx.items.b.record_id, absent_id()}
          ] do
        assert query.(field, out_of_scope) == {200, %{"items" => [], "next_cursor" => nil}}
        assert query.(field, nonexistent) == {200, %{"items" => [], "next_cursor" => nil}}
      end

      assert {200, %{"items" => [_one]}} = query.("scope_node", "sf-a")
    end
  end

  # ===========================================================================================
  describe "T-W8 (F7) a reference payload naming an out-of-scope record" do
    defp child(fx, requester, item_id) do
      body = %{
        "field_values" => %{"name" => "c", "scope_node" => "sf-a", "item_id" => item_id}
      }

      case requester do
        :scoped -> W.request(fx, :post, W.records_path("scoped_child", nil), body)
        :wide -> W.admin_request(fx, :post, W.records_path("scoped_child", nil), body)
      end
    end

    test "is answered exactly like one naming a NONEXISTENT record (AC 7): no existence oracle through the promoted foreign key",
         %{fx: fx} do
      out_of_scope = child(fx, :scoped, fx.items.b.record_id)
      nonexistent = child(fx, :scoped, absent_id())

      assert {out_of_scope.status, nonexistent.status} == {nonexistent.status, nonexistent.status},
             "an out-of-scope reference is #{out_of_scope.status}, a nonexistent one " <>
               "#{nonexistent.status}: the caller learns that a record outside its scope exists"
    end

    test "the in-scope reference works; the tenant-wide caller sees the same split as today (pre-existing, for the report)",
         %{fx: fx} do
      assert child(fx, :scoped, fx.items.a.record_id).status == 201
      assert child(fx, :wide, fx.items.b.record_id).status == 201
      # PINNED PRE-EXISTING DEFECT (issue #2832, SEC step-20 ruling c): a tenant-wide caller
      # writing a nonexistent reference gets a bare 500 (INV-8, not an INV-5 leak). Whoever fixes
      # it (a 422 on the FK field) MUST keep the scoped answer the generic 404, NEVER a 422: 422
      # for nonexistent vs 404 for out-of-scope would be an oracle. The scoped side is pinned in
      # entities_scope_references_http_test.exs.
      assert child(fx, :wide, absent_id()).status == 500
    end
  end

  # ===========================================================================================
  describe "T-W9 import is all-or-nothing for a scoped caller" do
    test "one bad row in ANY position refuses the whole batch, one answer, zero rows",
         %{fx: fx} do
      ref = W.attach_not_found!()
      canonical = canonical(fx)
      _ = W.drain_not_found(ref)
      before = W.counts(fx)

      bad_values = ["sf-b", :omit, nil, "sf-a3", "sf-a2", "no-such-node", 5, ""]

      for bad <- bad_values, position <- [0, 1, 2] do
        nodes = List.insert_at(["sf-a", "sf-a1"], position, bad)
        conn = W.request(fx, :post, W.import_path(@type_item), W.import_body(@type_item, nodes))

        assert W.norm(conn) == canonical, "#{inspect(bad)} at #{position}"

        assert [{%{count: 1}, %{policy: :EntitiesRecordsImport, kind: :import}}] =
                 W.drain_not_found(ref)
      end

      assert W.counts(fx) == before, "zero rows written by every refused batch"
    end

    test "an entry without field_values and a non-object entry value also refuse the batch", %{
      fx: fx
    } do
      canonical = canonical(fx)
      before = W.counts(fx)

      for entry <- [%{"record_id" => "x"}, %{"field_values" => 5}, %{"field_values" => []}] do
        body =
          Map.put(W.import_body(@type_item, ["sf-a"]), "records", [
            %{"field_values" => %{"name" => "n", "scope_node" => "sf-a"}},
            entry
          ])

        conn = W.request(fx, :post, W.import_path(@type_item), body)
        assert W.norm(conn) == canonical, inspect(entry)
      end

      assert W.counts(fx) == before
    end

    test "an all-in-scope batch succeeds; an invalid in-scope entry is a per-entry error (partial success as today)",
         %{fx: fx} do
      before = W.counts(fx)

      ok =
        W.request(
          fx,
          :post,
          W.import_path(@type_item),
          W.import_body(@type_item, ["sf-a", "sf-a1", "sf-a2x"])
        )

      assert ok.status == 200, ok.resp_body

      assert [%{"status" => "ok"}, %{"status" => "ok"}, %{"status" => "ok"}] =
               W.json(ok)["results"]

      latest = W.counts(fx)["entity_record_latest"]
      assert latest == before["entity_record_latest"] + 3

      body = W.import_body(@type_item, ["sf-a", "sf-a1"])

      invalid =
        update_in(body, ["records", Access.at(1), "field_values"], &Map.put(&1, "amount", "x"))

      mixed = W.request(fx, :post, W.import_path(@type_item), invalid)
      assert mixed.status == 200, mixed.resp_body
      assert [%{"status" => "ok"}, %{"status" => "error"}] = W.json(mixed)["results"]
      assert W.counts(fx)["entity_record_latest"] == latest + 1
    end

    test "structural checks come first: 413 over the cap, 422 version/type/upsert_by, as tenant-wide",
         %{fx: fx} do
      over_cap = W.import_body(@type_item, List.duplicate("sf-b", 201))

      wrong_version =
        Map.put(W.import_body(@type_item, ["sf-b"]), "record_export_schema_version", "nope")

      mismatch = Map.put(W.import_body(@type_item, ["sf-b"]), "entity_type", "other")
      bad_upsert = Map.put(W.import_body(@type_item, ["sf-b"]), "upsert_by", "nope")

      for {label, body} <- [
            {"cap", over_cap},
            {"version", wrong_version},
            {"mismatch", mismatch},
            {"upsert_by value", bad_upsert}
          ] do
        scoped = W.request(fx, :post, W.import_path(@type_item), body)
        wide = W.admin_request(fx, :post, W.import_path(@type_item), body)
        assert scoped.status in [413, 422], label
        assert W.norm(scoped) == W.norm(wide), label
      end
    end

    test "upsert_by external_ref is the generic 404 for a scoped caller; tenant-wide still upserts",
         %{fx: fx} do
      ref = W.attach_not_found!()
      canonical = canonical(fx)
      _ = W.drain_not_found(ref)
      before = W.counts(fx)

      body =
        Map.put(W.import_body(@type_item, ["sf-a"]), "upsert_by", "external_ref")
        |> update_in(
          ["records", Access.at(0)],
          &Map.put(&1, "external_ref", %{"system" => "crm", "id" => "1"})
        )

      conn = W.request(fx, :post, W.import_path(@type_item), body)
      assert W.norm(conn) == canonical

      assert [{%{count: 1}, %{policy: :EntitiesRecordsImport, kind: :import}}] =
               W.drain_not_found(ref)

      assert W.counts(fx) == before

      wide = W.admin_request(fx, :post, W.import_path(@type_item), body)
      assert wide.status == 200, wide.resp_body
    end
  end

  describe "T-W10 the documented race residual of import" do
    test "the batch is bound to the request's grant snapshot: a revocation takes effect on the NEXT request",
         %{
           fx: fx
         } do
      ok = W.request(fx, :post, W.import_path(@type_item), W.import_body(@type_item, ["sf-a"]))
      assert ok.status == 200

      :ok = W.set_grant!(fx, {:node, :b})
      next = W.request(fx, :post, W.import_path(@type_item), W.import_body(@type_item, ["sf-a"]))
      assert W.norm(next) == canonical(fx)
    end
  end

  # ===========================================================================================
  describe "AC 10 / T-W12 revocation is seen by the next request (no cache)" do
    test "a grant swapped to another subtree flips PUT, DELETE and POST to the canonical 404",
         %{fx: fx} do
      assert put_item(fx, fx.items.a.record_id, W.item_body("sf-a")).status == 200
      assert put_item(fx, fx.items.b.record_id, W.item_body("sf-a")).status == 404

      :ok = W.set_grant!(fx, {:node, :b})
      canonical = canonical(fx)

      assert W.norm(put_item(fx, fx.items.a.record_id, W.item_body("sf-b"))) == canonical
      assert put_item(fx, fx.items.b.record_id, W.item_body("sf-b1")).status == 200

      assert W.norm(W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-a"))) ==
               canonical

      assert W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-b1")).status ==
               201
    end

    test "the role grant row removed entirely: nothing is written and nothing is a 2xx", %{fx: fx} do
      before = W.counts(fx)
      :ok = W.set_grant!(fx, :none)

      for conn <- [
            put_item(fx, fx.items.a.record_id, W.item_body("sf-a")),
            W.request(fx, :delete, W.records_path(@type_item, fx.items.a.record_id), nil),
            W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-a")),
            W.request(fx, :post, W.import_path(@type_item), W.import_body(@type_item, ["sf-a"]))
          ] do
        assert conn.status in [403, 404], conn.resp_body
      end

      assert W.counts(fx) == before
    end

    test "a subtree moved out of the caller's grant: its records are the canonical 404 on the next request",
         %{fx: fx} do
      assert put_item(fx, fx.items.a1.record_id, W.item_body("sf-a1")).status == 200

      {:ok, _node} = Letflow.ScopeNodePaths.write({:move, "sf-a1", "sf-b"}, fx.schema_name)

      assert W.norm(put_item(fx, fx.items.a1.record_id, W.item_body("sf-a1"))) == canonical(fx)
      assert W.norm(put_item(fx, fx.items.a.record_id, W.item_body("sf-a1"))) == canonical(fx)
    end
  end

  describe "T-W11 revocation mid-pagination: the cursor carries no set" do
    test "page 2 of the same cursor applies the CURRENT scope", %{fx: fx} do
      body = %{
        "entity_type" => @type_item,
        "page_size" => 1,
        "sort" => [%{"field" => "amount", "dir" => "asc"}]
      }

      first = W.request(fx, :post, "/api/v1/entities/query", body)
      assert first.status == 200
      cursor = W.json(first)["next_cursor"]
      assert is_binary(cursor)

      decoded =
        case Base.url_decode64(cursor, padding: false) do
          {:ok, raw} -> raw
          :error -> cursor
        end

      refute cursor =~ "sf-"
      refute decoded =~ "sf-"
      refute decoded =~ "nodes"

      :ok = W.set_grant!(fx, {:node, :b})

      second = W.request(fx, :post, "/api/v1/entities/query", Map.put(body, "cursor", cursor))
      assert second.status == 200, second.resp_body

      names = for item <- W.json(second)["items"], do: item["field_values"]["name"]
      assert names != [], "page 2 of the new scope holds the b-subtree rows"

      assert names -- ["item-b", "item-b1"] == [],
             "only rows of the CURRENT scope: #{inspect(names)}"
    end
  end

  # ===========================================================================================
  describe "T-W22 an idempotency replay never confirms a record to an out-of-scope value" do
    test "a replayed key with an out-of-scope or NULL value is the canonical 404, no stored id",
         %{fx: fx} do
      canonical = canonical(fx)

      created =
        W.admin_request(
          fx,
          :post,
          W.records_path(@type_item, nil),
          W.item_body("sf-b", key: "replay-1")
        )

      assert created.status == 201
      stored_id = W.json(created)["record_id"]

      for value <- ["sf-b", :omit, nil, "sf-root"] do
        conn =
          W.request(
            fx,
            :post,
            W.records_path(@type_item, nil),
            W.item_body(value, key: "replay-1")
          )

        assert W.norm(conn) == canonical, inspect(value)
        refute conn.resp_body =~ stored_id
        refute Enum.any?(conn.resp_headers, fn {_k, v} -> v =~ stored_id end)

        upd =
          put_item(fx, fx.items.a.record_id, W.item_body(value, key: "replay-1"))

        assert W.norm(upd) == canonical, inspect(value)
        refute upd.resp_body =~ stored_id
      end
    end

    test "own key: in-scope replay as today, out-of-scope replay is the canonical 404",
         %{fx: fx} do
      canonical = canonical(fx)

      first =
        W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-a", key: "own-1"))

      assert first.status == 201
      own_id = W.json(first)["record_id"]

      same =
        W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-a", key: "own-1"))

      assert same.status in [200, 201]
      assert W.json(same)["record_id"] == own_id

      other =
        W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-b", key: "own-1"))

      assert W.norm(other) == canonical
      refute other.resp_body =~ own_id

      upd = put_item(fx, own_id, W.item_body("sf-a1", key: "own-u"))
      assert upd.status == 200
      moved = put_item(fx, own_id, W.item_body("sf-b", key: "own-u"))
      assert W.norm(moved) == canonical
      assert W.stored_values(fx, @type_item, own_id)["scope_node"] == "sf-a1"
    end
  end

  # ===========================================================================================
  describe "T-W23 the type gate: undeclared, tenant_wide and nonexistent types are the same bytes" do
    setup %{fx: fx} do
      F.create_plain_undeclared!(fx, fx.items)
      :ok
    end

    test "create (valid and invalid bodies) and import", %{fx: fx} do
      canonical = canonical(fx)
      types = ["plain_undeclared", "scoped_master", "no_such_type"]

      for type <- types do
        valid =
          W.request(fx, :post, W.records_path(type, nil), %{
            "field_values" => %{"name" => "x", "scope_node" => "sf-a"}
          })

        assert W.norm(valid) == canonical, "create #{type}"

        for raw <- ["[]", "5", "{}"] do
          invalid = W.raw_request(fx, :post, W.records_path(type, nil), raw)
          assert W.norm(invalid) == canonical, "create #{type} <- #{raw}"
        end

        imported = W.request(fx, :post, W.import_path(type), W.import_body(type, ["sf-a"]))
        assert W.norm(imported) == canonical, "import #{type}"
      end

      before = W.counts(fx)

      for type <- types do
        W.request(fx, :post, W.records_path(type, nil), %{"field_values" => %{"name" => "y"}})
      end

      assert W.counts(fx) == before
    end

    test "control: a tenant-wide caller still reaches the type and writes",
         %{fx: fx} do
      invalid = W.raw_admin_request(fx, :post, W.records_path("plain_undeclared", nil), "[]")
      assert invalid.status in [400, 422]

      ok =
        W.admin_request(fx, :post, W.records_path("plain_undeclared", nil), %{
          "field_values" => %{"name" => "tw"}
        })

      assert ok.status == 201
    end

    test "query: an undeclared and a nonexistent type are the same empty page (no difference today)",
         %{fx: fx} do
      undeclared =
        W.request(fx, :post, "/api/v1/entities/query", %{"entity_type" => "plain_undeclared"})

      assert undeclared.status == 200
      assert W.json(undeclared) == %{"items" => [], "next_cursor" => nil}

      absent = W.request(fx, :post, "/api/v1/entities/query", %{"entity_type" => "no_such_type"})
      # observed on the as-built code: a nonexistent type is folded to the same empty page, so
      # the "documented difference" of design 5.3 does not exist today (reported to the supervisor)
      assert W.norm(absent) == W.norm(undeclared)
    end
  end

  # ===========================================================================================
  describe "T-L4 to T-L11 the eight routes are resolver routes with an exported resolver" do
    @resolver {:resolver, {ScopeResolver, :record_scope}}
    @resolver_lines [
      "POST /entities/records/:entity_type EntitiesRecordsWrite",
      "PUT /entities/records/:entity_type/:record_id EntitiesRecordsWrite",
      "DELETE /entities/records/:entity_type/:record_id EntitiesRecordsWrite",
      "POST /entities/records/:entity_type/import EntitiesRecordsImport",
      "POST /entities/records/:entity_type/:record_id/attachments EntitiesAttachmentsManage",
      "GET /entities/records/:entity_type/:record_id/attachments EntitiesAttachmentsRead",
      "GET /entities/records/:entity_type/:record_id/attachments/:attachment_id EntitiesAttachmentsRead",
      "DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id EntitiesAttachmentsManage"
    ]

    test "each is mounted with the resolver class (declared) and the resolver is exported",
         %{fx: _fx} do
      routes = RouteInventory.routes()

      for line <- @resolver_lines do
        row = Enum.find(routes, &(Letflow.Api.RouteScope.snapshot_line(&1) == line))
        assert row, "#{line} is mounted"
        assert row.class == @resolver, line
        assert row.source == :declared, line
      end

      assert function_exported?(ScopeResolver, :record_scope, 1)
    end

    test "the seven definition and restriction routes are explicitly :tenant_wide (declared)", %{
      fx: _fx
    } do
      lines = [
        "POST /entities/definitions/:name/activate EntitiesDefinitionsWrite",
        "POST /entities/definitions EntitiesDefinitionsWrite",
        "GET /entities/definitions/active/:name EntitiesDefinitionsRead",
        "GET /entities/definitions/by-name/:name EntitiesDefinitionsRead",
        "GET /entities/definitions/:id EntitiesDefinitionsRead",
        "GET /entities/definitions EntitiesDefinitionsRead",
        "POST /entities/restrictions/import EntitiesRestrictionsManage"
      ]

      routes = RouteInventory.routes()

      for line <- lines do
        row = Enum.find(routes, &(Letflow.Api.RouteScope.snapshot_line(&1) == line))
        assert row, line
        assert row.class == :tenant_wide and row.source == :declared, line
      end
    end

    test "in scope succeeds, out of scope is refused (create, update, delete, import)",
         %{fx: fx} do
      canonical = canonical(fx)

      assert W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-a")).status ==
               201

      assert put_item(fx, fx.items.a.record_id, W.item_body("sf-a")).status == 200

      assert W.request(fx, :post, W.import_path(@type_item), W.import_body(@type_item, ["sf-a"])).status ==
               200

      assert W.request(fx, :delete, W.records_path(@type_item, fx.items.a1.record_id), nil).status ==
               200

      assert W.norm(W.request(fx, :post, W.records_path(@type_item, nil), W.item_body("sf-b"))) ==
               canonical

      assert W.norm(put_item(fx, fx.items.b.record_id, W.item_body("sf-b"))) == canonical

      assert W.norm(W.request(fx, :delete, W.records_path(@type_item, fx.items.b.record_id), nil)) ==
               canonical

      assert W.norm(
               W.request(
                 fx,
                 :post,
                 W.import_path(@type_item),
                 W.import_body(@type_item, ["sf-b"])
               )
             ) == canonical

      assert in_a_untouched(fx) == [:a, :a2x]
    end
  end

  defp in_a_untouched(fx) do
    Enum.filter(@in_a, fn key ->
      row = W.stored_row(fx, @type_item, fx.items[key].record_id)
      row.deleted == false
    end)
  end
end
