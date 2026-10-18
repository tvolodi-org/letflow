defmodule Letflow.Routers.EntitiesScopeReferencesHttpTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii, BUG-1 (SEC step-20 ruling, design r2b 5.3 and T-W8 (a) to (g);
  spec `test/specs/REQ-518-2c-ii.md`): the REFERENCE payload of a scoped write is resolved
  through the scope of the REFERENCED type, so a reference naming an out-of-scope record and one
  naming a nonexistent record are one answer (AC 7).

  Fixture: `scoped_child` (declared by column, foreign key `item_id` to `scoped_item`, which is
  also declared by column), a real OIDC user holding `TENANT_ADMIN` only at subtree `a`, stored
  mode `on`, the FULL router.

    * (a) create and PUT: an out-of-scope existing reference vs a nonexistent one: identical
      status, headers, body, ordered SQL statement sequence and telemetry (`policy`, `kind`);
      nothing written, no idempotency row; a PUT with an unchanged in-scope reference succeeds;
    * (b) a tenant-wide caller: in-scope and out-of-scope references are 2xx; the nonexistent
      reference is a pinned PRE-EXISTING 500 (issue #2832, the fix must keep the scoped 404);
    * (c) null / omitted reference succeeds; non-string, malformed and empty references are one
      answer with no lookup statement;
    * (d) idempotency replay with a reference that is out of scope (or has LEFT the scope since):
      the canonical 404, the stored id appears nowhere;
    * (e) import: a bad reference in the first, middle and last entry, for an out-of-scope, a
      nonexistent and a malformed value: one answer, zero rows, ONE lookup statement per
      reference field whatever the batch size;
    * (g) the foreign-key backstop: the referenced row is removed after the pre-checks passed;
      the scoped caller gets the generic 404, never a 500.

  `async: false`: a dedicated provisioned OIDC tenant, committed writes, cross-connection locks.
  """

  use Letflow.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.ScopeWritesFixture, as: W

  @child "scoped_child"

  setup do
    {:ok, fx: W.provision!("r518-wr")}
  end

  # ---- helpers ------------------------------------------------------------------------------

  defp absent_id, do: Ecto.UUID.generate()

  defp child_values(item_id) do
    values = %{"name" => "c", "scope_node" => "sf-a"}
    if item_id == :omit, do: values, else: Map.put(values, "item_id", item_id)
  end

  defp child_body(item_id), do: %{"field_values" => child_values(item_id)}

  defp child_body(item_id, key), do: Map.put(child_body(item_id), "idempotency_key", key)

  defp post_child(fx, body), do: W.request(fx, :post, W.records_path(@child, nil), body)
  defp put_child(fx, id, body), do: W.request(fx, :put, W.records_path(@child, id), body)

  defp create_child!(fx, item_id) do
    conn = post_child(fx, child_body(item_id))
    assert conn.status == 201, conn.resp_body
    W.json(conn)["record_id"]
  end

  # the canonical generic 404 (as in the other 2c-ii files)
  defp canonical(fx) do
    fx
    |> W.request(:put, W.records_path("scoped_item", absent_id()), W.item_body("sf-a"))
    |> W.norm()
  end

  defp import_children(refs) do
    records =
      refs
      |> Enum.with_index()
      |> Enum.map(fn {ref, i} ->
        %{"record_id" => "src-#{i}", "field_values" => child_values(ref)}
      end)

    %{
      "record_export_schema_version" => "entities/record-export/v1",
      "entity_type" => @child,
      "records" => records
    }
  end

  defp import_children(fx, refs),
    do: W.request(fx, :post, W.import_path(@child), import_children(refs))

  defp lookup_statements(sql),
    do: Enum.filter(sql, &(&1 =~ "entity_scoped_item" and &1 =~ "ANY("))

  # ===========================================================================================
  describe "T-W8 (a) create: an out-of-scope reference is a nonexistent reference" do
    test "identical status, headers, body, statements and telemetry; nothing written", %{fx: fx} do
      ref = W.attach_not_found!()
      canonical = canonical(fx)
      _warm = post_child(fx, child_body(absent_id()))
      _ = W.drain_not_found(ref)

      {absent_conn, absent_sql} =
        W.statements(fn -> post_child(fx, child_body(absent_id())) end)

      absent_events = W.drain_not_found(ref)
      assert W.norm(absent_conn) == canonical

      assert [{%{count: 1}, %{policy: :EntitiesRecordsWrite, kind: :write_value}} = event] =
               absent_events

      assert event |> elem(1) |> Map.keys() |> Enum.sort() == [:kind, :policy]
      assert length(lookup_statements(absent_sql)) == 1, "one lookup statement for the field"

      before = W.counts(fx)

      for key <- [:b, :b1, :root, :a2, :a3, :none] do
        {conn, sql} = W.statements(fn -> post_child(fx, child_body(fx.items[key].record_id)) end)

        assert W.norm(conn) == canonical, "#{key}"
        assert sql == absent_sql, "#{key}: the same statements in the same order"
        assert W.drain_not_found(ref) == absent_events, "#{key}"
        refute conn.resp_body =~ fx.items[key].record_id
      end

      assert W.counts(fx) == before, "no row, event, idempotency row or attachment written"
    end

    test "in-scope references (and the live descendant of a retired node) create", %{fx: fx} do
      for key <- [:a, :a1, :a2x] do
        id = create_child!(fx, fx.items[key].record_id)
        assert W.stored_values(fx, @child, id)["item_id"] == fx.items[key].record_id
      end
    end
  end

  describe "T-W8 (a) PUT" do
    test "changing the reference to an out-of-scope or nonexistent record is the canonical 404, equal statements, nothing changed",
         %{fx: fx} do
      ref = W.attach_not_found!()
      canonical = canonical(fx)
      id = create_child!(fx, fx.items.a.record_id)
      _warm = put_child(fx, id, child_body(absent_id()))
      _ = W.drain_not_found(ref)

      {absent_conn, absent_sql} =
        W.statements(fn -> put_child(fx, id, child_body(absent_id())) end)

      absent_events = W.drain_not_found(ref)
      assert W.norm(absent_conn) == canonical
      assert [{%{count: 1}, %{policy: :EntitiesRecordsWrite, kind: :write_value}}] = absent_events

      before = W.counts(fx)

      for key <- [:b, :b1, :none] do
        {conn, sql} =
          W.statements(fn -> put_child(fx, id, child_body(fx.items[key].record_id)) end)

        assert W.norm(conn) == canonical, "#{key}"
        assert sql == absent_sql, "#{key}"
        assert W.drain_not_found(ref) == absent_events, "#{key}"
      end

      assert W.counts(fx) == before
      assert W.stored_values(fx, @child, id)["item_id"] == fx.items.a.record_id
    end

    test "an UNCHANGED in-scope reference and a change to another in-scope reference succeed", %{
      fx: fx
    } do
      id = create_child!(fx, fx.items.a.record_id)
      same = put_child(fx, id, child_body(fx.items.a.record_id))
      assert same.status == 200, same.resp_body

      moved = put_child(fx, id, child_body(fx.items.a1.record_id))
      assert moved.status == 200, moved.resp_body
      assert W.stored_values(fx, @child, id)["item_id"] == fx.items.a1.record_id
    end

    test "no exemption for an unchanged stored reference that has LEFT the scope: the generic 404 until it is changed (fail closed)",
         %{fx: fx} do
      id = create_child!(fx, fx.items.a1.record_id)
      canonical = canonical(fx)

      {:ok, _node} = Letflow.ScopeNodePaths.write({:move, "sf-a1", "sf-b"}, fx.schema_name)
      # the child's own scope node is still sf-a; its referenced item now lives under b
      assert W.norm(put_child(fx, id, child_body(fx.items.a1.record_id))) == canonical
      assert put_child(fx, id, child_body(fx.items.a.record_id)).status == 200
    end
  end

  # ===========================================================================================
  describe "T-W8 (b) a tenant-wide caller" do
    test "in-scope and out-of-scope references are 2xx; the nonexistent reference is a PINNED pre-existing 500 (issue #2832)",
         %{fx: fx} do
      wide = fn ref ->
        W.admin_request(fx, :post, W.records_path(@child, nil), child_body(ref))
      end

      assert wide.(fx.items.a.record_id).status == 201
      assert wide.(fx.items.b.record_id).status == 201
      assert wide.(fx.items.none.record_id).status == 201

      # PINNED PRE-EXISTING DEFECT (issue #2832, INV-8 not INV-5): a bare 500 for a nonexistent
      # promoted reference. NOT an assertion that tenant-wide gets 404. The fix (a 422 on the FK
      # field) MUST keep the SCOPED answer the generic 404, never 422 (an oracle otherwise).
      assert wide.(absent_id()).status == 500
    end
  end

  # ===========================================================================================
  describe "T-W8 (c) null, omitted and malformed references" do
    test "an omitted reference succeeds; an explicit JSON null fails the type validation (422, same bytes as a tenant-wide caller, independent of any record: no oracle)",
         %{fx: fx} do
      assert post_child(fx, child_body(:omit)).status == 201

      scoped = post_child(fx, child_body(nil))
      wide = W.admin_request(fx, :post, W.records_path(@child, nil), child_body(nil))
      assert scoped.status == 422
      assert W.norm(scoped) == W.norm(wide)
    end

    test "non-string, malformed and empty references are the canonical 404 with NO lookup statement",
         %{
           fx: fx
         } do
      canonical = canonical(fx)
      before = W.counts(fx)

      for bad <- [5, true, "not-a-uuid", "", " ", ["x"], %{"id" => "x"}, "12345678-1234"] do
        {conn, sql} = W.statements(fn -> post_child(fx, child_body(bad)) end)
        assert W.norm(conn) == canonical, inspect(bad)
        assert lookup_statements(sql) == [], "#{inspect(bad)}: no lookup for a malformed value"
      end

      assert W.counts(fx) == before
    end
  end

  # ===========================================================================================
  describe "T-W22 / T-W8 (d) idempotency replay with a reference outside the scope" do
    test "replayed key with an out-of-scope or nonexistent reference: canonical 404, no stored id",
         %{fx: fx} do
      canonical = canonical(fx)

      created =
        W.admin_request(
          fx,
          :post,
          W.records_path(@child, nil),
          child_body(fx.items.b.record_id, "ref-replay")
        )

      assert created.status == 201
      stored = W.json(created)["record_id"]

      for ref <- [fx.items.b.record_id, absent_id()] do
        conn = post_child(fx, child_body(ref, "ref-replay"))
        assert W.norm(conn) == canonical
        refute conn.resp_body =~ stored
        refute Enum.any?(conn.resp_headers, fn {_k, v} -> v =~ stored end)
      end
    end

    test "own key: in-scope replay as today; after the target leaves the scope the replay is the canonical 404",
         %{fx: fx} do
      canonical = canonical(fx)
      first = post_child(fx, child_body(fx.items.a2x.record_id, "own-ref"))
      assert first.status == 201
      stored = W.json(first)["record_id"]

      same = post_child(fx, child_body(fx.items.a2x.record_id, "own-ref"))
      assert same.status in [200, 201]
      assert W.json(same)["record_id"] == stored

      # the referenced item is moved to subtree b by a tenant-wide caller
      moved =
        W.admin_request(
          fx,
          :put,
          W.records_path("scoped_item", fx.items.a2x.record_id),
          W.item_body("sf-b")
        )

      assert moved.status == 200

      replay = post_child(fx, child_body(fx.items.a2x.record_id, "own-ref"))
      assert W.norm(replay) == canonical
      refute replay.resp_body =~ stored
    end
  end

  # ===========================================================================================
  describe "T-W8 (e) import resolves the references of every entry" do
    test "bad reference at any position and reason: one answer, zero rows, one lookup statement",
         %{fx: fx} do
      ref = W.attach_not_found!()
      canonical = canonical(fx)
      good = [fx.items.a.record_id, fx.items.a1.record_id]
      _ = W.drain_not_found(ref)
      before = W.counts(fx)

      for position <- [0, 1, 2] do
        sqls =
          for {reason, bad} <- [
                out_of_scope: fx.items.b.record_id,
                nonexistent: absent_id(),
                out_of_scope_null_node: fx.items.none.record_id
              ] do
            refs = List.insert_at(good, position, bad)
            {conn, sql} = W.statements(fn -> import_children(fx, refs) end)

            assert W.norm(conn) == canonical, "#{reason} @ #{position}"

            assert [{%{count: 1}, %{policy: :EntitiesRecordsImport, kind: :import}}] =
                     W.drain_not_found(ref),
                   "#{reason} @ #{position}"

            assert length(lookup_statements(sql)) == 1,
                   "#{reason} @ #{position}: ONE statement for the field, not one per value"

            sql
          end

        assert sqls |> Enum.uniq() |> length() == 1, "position #{position}: same sequence"
      end

      for bad <- ["not-a-uuid", 5, ""], position <- [0, 1, 2] do
        conn = import_children(fx, List.insert_at(good, position, bad))
        assert W.norm(conn) == canonical, "#{inspect(bad)} @ #{position}"
      end

      assert W.counts(fx) == before, "zero rows written by every refused batch"
    end

    test "an omitted reference is allowed in a batch; an all-in-scope batch is created",
         %{
           fx: fx
         } do
      conn =
        import_children(fx, [
          fx.items.a.record_id,
          :omit,
          fx.items.a1.record_id,
          fx.items.a.record_id
        ])

      assert conn.status == 200, conn.resp_body
      assert Enum.all?(W.json(conn)["results"], &(&1["status"] == "ok"))
    end

    test "a batch with the same reference repeated costs the same ONE lookup statement", %{fx: fx} do
      {_conn, sql} =
        W.statements(fn ->
          import_children(fx, List.duplicate(fx.items.b.record_id, 5))
        end)

      assert length(lookup_statements(sql)) == 1
    end

    test "T-W9b: upsert_by external_ref is the generic 404 for a scoped caller", %{fx: fx} do
      body = Map.put(import_children([fx.items.a.record_id]), "upsert_by", "external_ref")
      before = W.counts(fx)
      conn = W.request(fx, :post, W.import_path(@child), body)
      assert W.norm(conn) == canonical(fx)
      assert W.counts(fx) == before
    end
  end

  # ===========================================================================================
  describe "T-W8 (g) the foreign-key backstop" do
    test "the referenced row disappears after the pre-checks passed: the scoped caller gets the generic 404, never a 500",
         %{fx: fx} do
      _ = Sandbox.checkin(Repo)
      parent = self()
      schema = fx.schema_name
      target = fx.items.a2x.record_id
      canonical = canonical(fx)
      before = W.counts(fx)

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s|SELECT 1 FROM "#{schema}".entity_scoped_item WHERE record_id = $1 FOR UPDATE|,
              [Ecto.UUID.dump!(target)]
            )

            send(parent, :locked)

            receive do
              :go -> :ok
            after
              20_000 -> flunk("never released")
            end

            Repo.query!(~s|DELETE FROM "#{schema}".entity_scoped_item WHERE record_id = $1|, [
              Ecto.UUID.dump!(target)
            ])
          end)
        end)

      assert_receive :locked, 10_000
      writer = Task.async(fn -> post_child(fx, child_body(target)) end)
      assert S.lock_waiter?("entity_scoped_child"), "the writer never queued on the foreign key"
      send(holder.pid, :go)
      assert {:ok, _} = Task.await(holder, 20_000)
      conn = Task.await(writer, 30_000)

      assert conn.status == 404, conn.resp_body
      assert W.norm(conn) == canonical
      assert W.counts(fx) == before
      refute conn.resp_body =~ "constraint"
    end
  end
end
