defmodule Letflow.Routers.EntitiesScopeAttachmentsHttpTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii, AC 11 (design `lib/letflow/design/req518-compiler-scope-filter.md`
  5.5, 10.2 T-W13 to T-W16, T-W20; spec `test/specs/REQ-518-2c-ii.md`): the four RECORD
  ATTACHMENT routes gate on the PARENT record for a scoped caller, through the FULL
  `Letflow.Router` on the `fixture_scoped` tenant (stored mode `on`, a real OIDC user whose
  `TENANT_ADMIN` role is held only at the subtree `a`).

    * T-W13 to T-W16: per route (create, list, content GET, delete) an out-of-scope parent is the
      NONEXISTENT parent: identical status, headers and body, the same SQL statements in the same
      order, one counted `[:letflow, :scope, :not_found]` event (`kind: :attachment_parent`);
      list stays the EMPTY 200 page, the others 404; a scoped caller cannot attach to, list,
      read or delete an attachment of an out-of-scope record, and nothing is written or removed;
    * T-W20 / MU38: the create gate runs BEFORE the multipart part is read: a MISSING file part
      is still the 404 (never the 422) for an out-of-scope and a nonexistent parent, while an
      in-scope parent answers its own 422;
    * a tenant-wide caller is unchanged (no gate statement, no event);
    * a type that is undeclared or hidden is not attachable/readable for a scoped caller (SEC
      F-3, fail closed), a revoked grant is seen by the next request.

  `async: false`: a dedicated provisioned OIDC tenant, committed writes, VM-global config and
  telemetry.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopeWritesFixture, as: W

  @type_item "scoped_item"
  @empty_page %{"items" => [], "next_cursor" => nil}

  setup do
    fx = W.provision!("r518-wa")
    in_scope = W.attach!(fx, @type_item, fx.items.a.record_id)
    out_of_scope = W.attach!(fx, @type_item, fx.items.b.record_id)
    null_scope = W.attach!(fx, @type_item, fx.items.none.record_id)

    {:ok, fx: fx, in_scope: in_scope, out_of_scope: out_of_scope, null_scope: null_scope}
  end

  defp absent_id, do: Ecto.UUID.generate()

  defp list(fx, id),
    do: W.request(fx, :get, W.attachments_path(@type_item, id), nil)

  defp content(fx, id, attachment_id),
    do: W.request(fx, :get, W.item_path(@type_item, id, attachment_id), nil)

  defp delete(fx, id, attachment_id),
    do: W.request(fx, :delete, W.item_path(@type_item, id, attachment_id), nil)

  defp create(fx, id, parts \\ :file),
    do: W.multipart(fx, W.attachments_path(@type_item, id), parts)

  # runs `fun` twice (warm-up, then measured) and returns {norm, sql, events}
  defp measure(ref, fun) do
    _warm = fun.()
    _ = W.drain_not_found(ref)
    {conn, sql} = W.statements(fun)
    events = W.drain_not_found(ref)
    {W.norm(conn), sql, events}
  end

  # ===========================================================================================
  describe "T-W13 attachment CREATE" do
    test "an out-of-scope parent (every out-of-scope key) is the nonexistent parent: same bytes, same statements, one counted event, nothing stored",
         %{fx: fx} do
      ref = W.attach_not_found!()
      {absent, absent_sql, absent_events} = measure(ref, fn -> create(fx, absent_id()) end)

      assert {404, _headers, _body} = absent

      assert [{%{count: 1}, %{policy: :EntitiesAttachmentsManage, kind: :attachment_parent}}] =
               absent_events

      before = W.counts(fx)

      for key <- [:root, :a2, :a3, :b, :b1, :none] do
        {conn, sql} = W.statements(fn -> create(fx, fx.items[key].record_id) end)

        assert W.norm(conn) == absent, "#{key}"
        assert sql == absent_sql, "#{key}"
        assert W.drain_not_found(ref) == absent_events, "#{key}"
      end

      assert W.counts(fx) == before, "no attachment, artifact or event was written"
    end

    test "an in-scope parent uploads (201)", %{fx: fx} do
      conn = create(fx, fx.items.a1.record_id)
      assert conn.status == 201, conn.resp_body
      assert W.json(conn)["record_id"] == fx.items.a1.record_id
    end
  end

  describe "T-W20 / MU38 the create parent gate runs BEFORE the multipart part is read" do
    test "a MISSING file part is 404 for out-of-scope and nonexistent parents, 422 in scope",
         %{fx: fx} do
      ref = W.attach_not_found!()
      absent = W.norm(create(fx, absent_id(), :no_file))
      assert {404, _headers, _body} = absent

      for key <- [:b, :b1, :none, :root] do
        assert W.norm(create(fx, fx.items[key].record_id, :no_file)) == absent, "#{key}"
      end

      # with a valid file part the answer is the very same bytes
      assert W.norm(create(fx, fx.items.b.record_id, :file)) == absent

      in_scope = create(fx, fx.items.a.record_id, :no_file)
      assert in_scope.status == 422
      assert W.json(in_scope)["detail"] =~ "file"

      # one event per out-of-scope/nonexistent attempt, none for the in-scope parent
      events = W.drain_not_found(ref)
      assert length(events) == 6
      assert Enum.all?(events, &match?({%{count: 1}, %{kind: :attachment_parent}}, &1))
    end
  end

  # ===========================================================================================
  describe "T-W14 attachment LIST" do
    test "an out-of-scope parent is the EMPTY 200 page of a nonexistent parent (same bytes, same statements, one event), not a 404",
         %{fx: fx, out_of_scope: att} do
      ref = W.attach_not_found!()
      {absent, absent_sql, absent_events} = measure(ref, fn -> list(fx, absent_id()) end)

      assert {200, _headers, @empty_page} = absent

      assert [{%{count: 1}, %{policy: :EntitiesAttachmentsRead, kind: :attachment_parent}}] =
               absent_events

      for key <- [:root, :a2, :a3, :b, :b1, :none] do
        {conn, sql} = W.statements(fn -> list(fx, fx.items[key].record_id) end)

        assert W.norm(conn) == absent, "#{key}"
        refute conn.resp_body =~ att.id, "#{key}: no attachment of another subtree is listed"
        assert sql == absent_sql, "#{key}"
        assert W.drain_not_found(ref) == absent_events, "#{key}"
      end
    end

    test "an in-scope parent lists its attachment; the page-size/cursor validation is unchanged",
         %{fx: fx, in_scope: att} do
      conn = list(fx, fx.items.a.record_id)
      assert conn.status == 200
      assert [%{"id" => id}] = W.json(conn)["items"]
      assert id == att.id

      bad =
        W.request(
          fx,
          :get,
          W.attachments_path(@type_item, fx.items.a.record_id) <> "?page_size=x",
          nil
        )

      assert bad.status == 400
    end
  end

  describe "T-W15 attachment CONTENT" do
    test "an out-of-scope parent with a REAL attachment id is the 404 of a nonexistent parent (bytes, statements, event); the bytes are never served",
         %{fx: fx, out_of_scope: att, null_scope: null_att} do
      ref = W.attach_not_found!()

      {absent, absent_sql, absent_events} =
        measure(ref, fn -> content(fx, absent_id(), absent_id()) end)

      assert {404, _headers, _body} = absent

      assert [{%{count: 1}, %{policy: :EntitiesAttachmentsRead, kind: :attachment_parent}}] =
               absent_events

      for {key, attachment} <- [b: att, none: null_att] do
        {conn, sql} =
          W.statements(fn -> content(fx, fx.items[key].record_id, attachment.id) end)

        assert W.norm(conn) == absent, "#{key}"
        refute conn.resp_body =~ "ATTACHED-BYTES"
        assert sql == absent_sql, "#{key}"
        assert W.drain_not_found(ref) == absent_events, "#{key}"
      end
    end

    test "an in-scope parent serves its bytes (200); a mismatched parent/attachment pair is still the existing 404",
         %{fx: fx, in_scope: att, out_of_scope: other} do
      ok = content(fx, fx.items.a.record_id, att.id)
      assert ok.status == 200
      assert ok.resp_body == "ATTACHED-BYTES"

      assert content(fx, fx.items.a.record_id, other.id).status == 404
    end
  end

  describe "T-W16 attachment DELETE" do
    test "an out-of-scope parent with a REAL attachment id is the 404 of a nonexistent parent (bytes, statements, event); the attachment is NOT removed",
         %{fx: fx, out_of_scope: att} do
      ref = W.attach_not_found!()

      {absent, absent_sql, absent_events} =
        measure(ref, fn -> delete(fx, absent_id(), absent_id()) end)

      assert {404, _headers, _body} = absent

      assert [{%{count: 1}, %{policy: :EntitiesAttachmentsManage, kind: :attachment_parent}}] =
               absent_events

      before = W.counts(fx)

      {conn, sql} = W.statements(fn -> delete(fx, fx.items.b.record_id, att.id) end)

      assert W.norm(conn) == absent
      assert sql == absent_sql
      assert W.drain_not_found(ref) == absent_events
      assert W.counts(fx) == before, "nothing was removed"
      assert content(fx, fx.items.b.record_id, att.id).status == 404

      # the tenant-wide caller still sees it
      assert W.admin_request(fx, :get, W.item_path(@type_item, fx.items.b.record_id, att.id), nil).status ==
               200
    end

    test "an in-scope parent deletes its attachment (204)", %{fx: fx, in_scope: att} do
      assert delete(fx, fx.items.a.record_id, att.id).status == 204
      assert content(fx, fx.items.a.record_id, att.id).status == 404
    end
  end

  # ===========================================================================================
  describe "a tenant-wide caller is unchanged" do
    test "no gate statement against the scope tables and no counted event; every parent is served",
         %{
           fx: fx,
           out_of_scope: att
         } do
      ref = W.attach_not_found!()

      {conn, sql} =
        W.statements(fn ->
          W.admin_request(fx, :get, W.attachments_path(@type_item, fx.items.b.record_id), nil)
        end)

      assert conn.status == 200
      assert [%{"id" => id}] = W.json(conn)["items"]
      assert id == att.id
      refute Enum.any?(sql, &(&1 =~ "scope_node_paths"))
      assert W.drain_not_found(ref) == []
    end
  end

  describe "SEC F-3: undeclared and hidden types (fail closed for a scoped caller)" do
    test "undeclared type: scoped caller gets empty page / 404, tenant-wide still reads",
         %{fx: fx} do
      record = F.create_plain_undeclared!(fx, fx.items)
      att = W.attach!(fx, "plain_undeclared", record.record_id)
      path = W.attachments_path("plain_undeclared", record.record_id)

      assert W.norm(W.request(fx, :get, path, nil)) ==
               W.norm(
                 W.request(fx, :get, W.attachments_path("plain_undeclared", absent_id()), nil)
               )

      assert W.json(W.request(fx, :get, path, nil)) == @empty_page
      assert W.request(fx, :get, path <> "/#{att.id}", nil).status == 404
      assert W.multipart(fx, path, :file).status == 404

      wide = W.admin_request(fx, :get, path, nil)
      assert [%{"id" => id}] = W.json(wide)["items"]
      assert id == att.id
    end

    test "denied type: even an in-scope parent is the nonexistent answer, one counted event",
         %{fx: fx} do
      now = NaiveDateTime.utc_now()

      Repo.insert_all(
        "entity_type_restrictions",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: @type_item,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: fx.schema_name
      )

      ref = W.attach_not_found!()
      absent = W.norm(list(fx, absent_id()))
      _ = W.drain_not_found(ref)

      assert W.norm(list(fx, fx.items.a.record_id)) == absent

      assert [{%{count: 1}, %{policy: :EntitiesAttachmentsRead, kind: :attachment_parent}}] =
               W.drain_not_found(ref)
    end
  end

  describe "AC 10 revocation for the attachment routes" do
    test "after the grant moves to another subtree the in-scope parent is the nonexistent answer on every route",
         %{fx: fx, in_scope: att} do
      assert list(fx, fx.items.a.record_id).status == 200
      assert content(fx, fx.items.a.record_id, att.id).status == 200

      :ok = W.set_grant!(fx, {:node, :b})

      assert W.json(list(fx, fx.items.a.record_id)) == @empty_page
      assert content(fx, fx.items.a.record_id, att.id).status == 404
      assert delete(fx, fx.items.a.record_id, att.id).status == 404
      assert create(fx, fx.items.a.record_id).status == 404
      assert length(W.json(list(fx, fx.items.b.record_id))["items"]) == 1
    end
  end
end
