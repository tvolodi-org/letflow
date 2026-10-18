defmodule Letflow.Entities.RecordsScopeTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii (design `lib/letflow/design/req518-compiler-scope-filter.md`
  5.2, 5.3; spec `test/specs/REQ-518-2c-ii.md`; SEC code-gate step-17): the `:scope` attribute of
  `Letflow.Entities.Records.create_record/2`, `update_record/2` and `delete_record/2`, the
  by-id `Letflow.Entities.ScopedLookup`, and the in-transaction RACE BACKSTOP (T-L27, T-W6).

    * the attribute: absent and `:all` are the same code path with the same statements (no scope
      read, no extra Multi step); `{:nodes, []}` is `:none`; a malformed value raises
      `ArgumentError`; a scoped set refuses a `:tenant_wide`, undeclared and managed-by-another
      type, and a missing, NULL, out-of-set value, with NOTHING appended (event, latest row,
      idempotency claim);
    * T-W6 (module action path): create, update (old AND new value) and delete behave as the
      HTTP routes do when module code passes the caller's set as `scope:`;
    * T-L27 (race backstop): a concurrent writer MOVES the record out of scope (or removes its
      latest row) between the pre-transaction read and the lock; the transaction re-reads the row
      FOR UPDATE and refuses, writing nothing, for update (with and without
      `expected_last_event_global_seq`) and delete; a control run where the concurrent writer
      changes nothing succeeds, so the refusal is the scope check and not the blocking;
    * `ScopedLookup.fetch_in_scope/5`: one statement, the declaration returned, `:not_found` for
      an out-of-scope, nonexistent, malformed, `:none`, `:tenant_wide`, undeclared, table-dropped
      and column-dropped case (fail closed), the counted event only on refusal.

  `async: false`: a dedicated provisioned tenant, real cross-connection locks (the sandbox
  ownership is released so the helper processes use their own connections).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Entities.ScopedWrites
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopeWritesFixture, as: W

  @in_a {:nodes, ["sf-a", "sf-a1", "sf-a2x"]}
  @type_item "scoped_item"

  setup do
    fx = F.provision!("r518-rs")
    # release the sandbox ownership DataCase took so helper tasks get their OWN connections
    _ = Sandbox.checkin(Repo)
    items = F.seed_items!(fx)
    {:ok, fx: Map.put(fx, :items, items)}
  end

  # ---- helpers ------------------------------------------------------------------------------

  defp attrs(extra) do
    Map.merge(
      %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()},
      Map.new(extra)
    )
  end

  defp values(node, name \\ "w") do
    base = %{"name" => name, "amount" => 1}
    if node == :omit, do: base, else: Map.put(base, "scope_node", node)
  end

  defp create(fx, node, scope, extra \\ []) do
    Records.create_record(
      attrs([entity_type: @type_item, field_values: values(node), scope: scope] ++ extra),
      fx.schema_name
    )
  end

  defp update(fx, key, node, scope) do
    Records.update_record(
      attrs(
        entity_type: @type_item,
        record_id: fx.items[key].record_id,
        field_values: values(node, "updated"),
        scope: scope
      ),
      fx.schema_name
    )
  end

  defp delete(fx, key, scope) do
    Records.delete_record(
      attrs(entity_type: @type_item, record_id: fx.items[key].record_id, scope: scope),
      fx.schema_name
    )
  end

  defp stored(fx, key), do: W.stored_row(fx, @type_item, fx.items[key].record_id)

  # ===========================================================================================
  describe "the :scope attribute" do
    test "absent and :all take the same path: identical statements, no scope read", %{fx: fx} do
      {{:ok, _}, explicit} = W.statements(fn -> create(fx, "sf-a", :all) end)

      {{:ok, _}, implicit} =
        W.statements(fn ->
          Records.create_record(
            attrs(entity_type: @type_item, field_values: values("sf-a")),
            fx.schema_name
          )
        end)

      assert explicit == implicit

      # a scoped set pays for the declaration reads
      {{:ok, _}, scoped} = W.statements(fn -> create(fx, "sf-a", @in_a) end)
      assert length(scoped) > length(implicit)
    end

    test "the :all path adds no row lock: update and delete take only the type's sequence lock, a scoped set adds exactly the latest-row FOR UPDATE",
         %{fx: fx} do
      row_lock? = &(&1 =~ "entity_record_latest" and &1 =~ "FOR UPDATE")

      {{:ok, _}, upd_all} = W.statements(fn -> update(fx, :a, "sf-a1", :all) end)
      {{:ok, _}, upd_scoped} = W.statements(fn -> update(fx, :a1, "sf-a1", @in_a) end)
      {{:ok, _}, del_all} = W.statements(fn -> delete(fx, :a2x, :all) end)
      {{:ok, _}, del_scoped} = W.statements(fn -> delete(fx, :a, @in_a) end)

      assert Enum.count(upd_all, row_lock?) == 0
      assert Enum.count(del_all, row_lock?) == 0
      assert Enum.count(upd_scoped, row_lock?) == 1
      assert Enum.count(del_scoped, row_lock?) == 1
    end

    test "{:nodes, []} is :none (everything refused, nothing written); a malformed value raises ArgumentError",
         %{
           fx: fx
         } do
      before = W.counts(fx)

      assert create(fx, "sf-a", {:nodes, []}) == {:error, :scope_refused}
      assert create(fx, "sf-a", :none) == {:error, :scope_refused}
      assert update(fx, :a, "sf-a", {:nodes, []}) == {:error, :scope_refused}
      assert delete(fx, :a, :none) == {:error, :scope_refused}
      assert W.counts(fx) == before

      for bad <- [
            nil,
            :foo,
            "all",
            {:nodes, :x},
            {:nodes, [1]},
            {:nodes, ["sf-a", :b]},
            [:all],
            {:node, "sf-a"}
          ] do
        assert_raise ArgumentError, fn -> create(fx, "sf-a", bad) end
        assert_raise ArgumentError, fn -> update(fx, :a, "sf-a", bad) end
        assert_raise ArgumentError, fn -> delete(fx, :a, bad) end
      end

      assert W.counts(fx) == before
    end
  end

  describe "T-W6 module-action path: create, update, delete with the caller's set" do
    test "create: in-set writes; out-of-set, missing, retired, nonexistent are :scope_refused; NULL and non-strings refused; nothing written",
         %{fx: fx} do
      assert {:ok, %{record: record}} = create(fx, "sf-a1", @in_a)
      assert record.field_values["scope_node"] == "sf-a1"

      before = W.counts(fx)

      for node <- ["sf-b", "sf-root", "sf-a3", "sf-a2", "no-such", "", :omit] do
        result = create(fx, node, @in_a)
        assert result == {:error, :scope_refused}, "#{inspect(node)} -> #{inspect(result)}"
      end

      # a NULL or non-string value fails the type validation FIRST at this layer (the router's
      # pure check runs before Records and answers the canonical 404 for them, see the HTTP
      # tests): refused here too, with nothing written
      for node <- [nil, 5, ["sf-a"]] do
        assert {:error, {:record_payload_invalid, _}} = create(fx, node, @in_a)
      end

      assert W.counts(fx) == before
    end

    test "update: the OLD value and the NEW value must both be in the set",
         %{fx: fx} do
      before = W.counts(fx)

      assert update(fx, :b, "sf-a", @in_a) == {:error, :scope_refused}, "old out of set"
      assert update(fx, :none, "sf-a", @in_a) == {:error, :scope_refused}, "old NULL"
      assert update(fx, :a3, "sf-a", @in_a) == {:error, :scope_refused}, "old retired node"
      assert update(fx, :a, "sf-b", @in_a) == {:error, :scope_refused}, "new out of set"
      assert update(fx, :a, :omit, @in_a) == {:error, :scope_refused}, "new missing"
      assert {:error, {:record_payload_invalid, _}} = update(fx, :a, nil, @in_a)

      assert W.counts(fx) == before
      assert stored(fx, :a).field_values["name"] == "item-a"

      assert {:ok, %{record: record}} = update(fx, :a, "sf-a2x", @in_a)
      assert record.field_values["scope_node"] == "sf-a2x"
    end

    test "delete: the OLD value must be in the set; out-of-scope already-deleted is the scope refusal",
         %{fx: fx} do
      assert delete(fx, :b, @in_a) == {:error, :scope_refused}
      assert stored(fx, :b).deleted == false

      assert {:ok, %{record: gone}} = delete(fx, :a1, @in_a)
      assert gone.deleted == true

      # in scope + already deleted: today's no-op success
      assert {:ok, %{record: again, is_duplicate: false}} = delete(fx, :a1, @in_a)
      assert again.deleted == true

      # out of scope + already deleted: the scope refusal, not the deleted answer
      assert {:ok, _} = delete(fx, :b, :all)
      assert delete(fx, :b, @in_a) == {:error, :scope_refused}
    end

    test "a nonexistent record id is the existing :record_not_found (the scope never runs on an absent row)",
         %{fx: fx} do
      result =
        Records.update_record(
          attrs(
            entity_type: @type_item,
            record_id: Ecto.UUID.generate(),
            field_values: values("sf-a"),
            scope: @in_a
          ),
          fx.schema_name
        )

      assert {:error, {:record_not_found, _id}} = result
    end

    test "types not scope-aware by a column are refused for a scoped set; a nonexistent type keeps its own error",
         %{fx: fx} do
      F.create_plain_undeclared!(fx, fx.items)
      before = W.counts(fx)

      for type <- ["scoped_master", "plain_undeclared"] do
        result =
          Records.create_record(
            attrs(entity_type: type, field_values: %{"name" => "x"}, scope: @in_a),
            fx.schema_name
          )

        assert result == {:error, :scope_refused}, type
      end

      assert W.counts(fx) == before

      absent =
        Records.create_record(
          attrs(entity_type: "no_such_type", field_values: %{"name" => "x"}, scope: @in_a),
          fx.schema_name
        )

      assert {:error, {:definition_not_found, "no_such_type"}} = absent

      # control: the same writes with :all succeed
      assert {:ok, _} =
               Records.create_record(
                 attrs(entity_type: "scoped_master", field_values: %{"name" => "x"}, scope: :all),
                 fx.schema_name
               )
    end

    test "a managed type keeps the managed-type refusal ahead of the scope (tenant authority)", %{
      fx: fx
    } do
      result =
        Records.create_record(
          attrs(
            entity_type: "scoped_managed_item",
            field_values: %{"name" => "m", "scope_node" => "sf-a"},
            scope: @in_a
          ),
          fx.schema_name
        )

      assert result == {:error, :entity_type_managed}
    end

    test "a refused write claims nothing: the same idempotency key succeeds afterwards", %{fx: fx} do
      key = "claim-#{System.unique_integer([:positive])}"
      assert create(fx, "sf-b", @in_a, idempotency_key: key) == {:error, :scope_refused}
      assert {:ok, %{record: record}} = create(fx, "sf-a", @in_a, idempotency_key: key)
      assert record.field_values["scope_node"] == "sf-a"
    end
  end

  # ===========================================================================================
  describe "T-L27 the race backstop: the row is re-read FOR UPDATE inside the transaction" do
    # A helper process in its OWN connection locks the latest row, tells the test, waits for
    # `:go`, then applies `change` and commits. The writer is started while the lock is held and
    # blocks on its FOR UPDATE; only then is the helper released.
    defp race(fx, key, change, writer_fun, wait_pattern \\ "FOR UPDATE") do
      parent = self()
      record_id = fx.items[key].record_id
      schema = fx.schema_name

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            _locked = Latest.get_for_update(Repo, record_id, @type_item, schema)
            send(parent, :locked)

            receive do
              :go -> :ok
            after
              20_000 -> flunk("the holder was never released")
            end

            apply_change(change, record_id, schema)
          end)
        end)

      assert_receive :locked, 10_000
      writer = Task.async(writer_fun)
      assert S.lock_waiter?(wait_pattern), "the writer never queued on the locked row"
      send(holder.pid, :go)
      assert {:ok, _} = Task.await(holder, 20_000)
      Task.await(writer, 20_000)
    end

    defp apply_change(:none, _record_id, _schema), do: :ok

    defp apply_change({:move, node}, record_id, schema) do
      {1, _} =
        Repo.update_all(
          from(l in Latest, where: l.record_id == ^record_id),
          [set: [field_values: %{"name" => "moved", "amount" => 1, "scope_node" => node}]],
          prefix: schema
        )
    end

    defp apply_change(:remove_row, record_id, schema) do
      {1, _} =
        Repo.delete_all(from(l in Latest, where: l.record_id == ^record_id), prefix: schema)
    end

    test "update: record moved out of scope after the pre-read is refused, nothing written",
         %{fx: fx} do
      before = W.counts(fx)
      schema = fx.schema_name

      result =
        race(fx, :a1, {:move, "sf-b"}, fn ->
          Records.update_record(
            attrs(
              entity_type: @type_item,
              record_id: fx.items.a1.record_id,
              field_values: values("sf-a1", "late"),
              scope: @in_a
            ),
            schema
          )
        end)

      assert result == {:error, :scope_refused}
      assert W.counts(fx) == before, "the refused update appended nothing"
      assert stored(fx, :a1).field_values["scope_node"] == "sf-b"
      assert stored(fx, :a1).field_values["name"] == "moved"
    end

    test "update with expected_last_event_global_seq (the version-check path already holds the lock): the same refusal",
         %{fx: fx} do
      before = W.counts(fx)
      schema = fx.schema_name
      seq = stored(fx, :a1).last_event_global_seq

      result =
        race(fx, :a1, {:move, "sf-b"}, fn ->
          Records.update_record(
            attrs(
              entity_type: @type_item,
              record_id: fx.items.a1.record_id,
              field_values: values("sf-a1", "late"),
              expected_last_event_global_seq: seq,
              scope: @in_a
            ),
            schema
          )
        end)

      assert result == {:error, :scope_refused}
      assert W.counts(fx) == before
      assert stored(fx, :a1).field_values["scope_node"] == "sf-b"
    end

    test "delete: the record is moved out of scope after the pre-read -> refused, not deleted", %{
      fx: fx
    } do
      before = W.counts(fx)
      schema = fx.schema_name

      result =
        race(fx, :a1, {:move, "sf-b"}, fn ->
          Records.delete_record(
            attrs(entity_type: @type_item, record_id: fx.items.a1.record_id, scope: @in_a),
            schema
          )
        end)

      assert result == {:error, :scope_refused}
      assert W.counts(fx) == before
      assert stored(fx, :a1).deleted == false
    end

    test "the latest row disappears between the pre-read and the lock -> refused (absent row is refused)",
         %{
           fx: fx
         } do
      schema = fx.schema_name

      result =
        race(fx, :a1, :remove_row, fn ->
          Records.update_record(
            attrs(
              entity_type: @type_item,
              record_id: fx.items.a1.record_id,
              field_values: values("sf-a1", "late"),
              scope: @in_a
            ),
            schema
          )
        end)

      assert result == {:error, :scope_refused}
      assert stored(fx, :a1) == nil
    end

    test "control: a holder that changes nothing lets the same update through",
         %{fx: fx} do
      schema = fx.schema_name

      result =
        race(fx, :a1, :none, fn ->
          Records.update_record(
            attrs(
              entity_type: @type_item,
              record_id: fx.items.a1.record_id,
              field_values: values("sf-a1", "late"),
              scope: @in_a
            ),
            schema
          )
        end)

      assert {:ok, %{record: record}} = result
      assert record.field_values["name"] == "late"
    end

    test "control: with scope :all the concurrent move is still written (backstop is scoped-only)",
         %{fx: fx} do
      schema = fx.schema_name

      result =
        race(
          fx,
          :a1,
          {:move, "sf-b"},
          fn ->
            Records.update_record(
              attrs(
                entity_type: @type_item,
                record_id: fx.items.a1.record_id,
                field_values: values("sf-b", "late"),
                scope: :all
              ),
              schema
            )
          end,
          "UPDATE"
        )

      assert {:ok, _} = result
    end
  end

  # ===========================================================================================
  describe "ScopedLookup.fetch_in_scope/5" do
    @telemetry {:EntitiesRecordsWrite, :by_id}

    defp lookup(fx, key, scope, type \\ @type_item) do
      id =
        case key do
          id when is_binary(id) -> id
          key -> fx.items[key].record_id
        end

      ScopedLookup.fetch_in_scope(type, id, scope, fx.schema_name, @telemetry)
    end

    test "an in-scope record is {:ok, declaration} with ONE statement and no event; every other id is :not_found with one counted event",
         %{fx: fx} do
      ref = W.attach_not_found!()

      {result, sql} = W.statements(fn -> lookup(fx, :a, @in_a) end)
      assert result == {:ok, {:column, "scope_node"}}
      assert Enum.count(sql, &(&1 =~ "ANY")) == 1
      assert W.drain_not_found(ref) == []

      for id <- [:b, :b1, :root, :none, :a2, :a3, Ecto.UUID.generate(), "not-a-uuid", ""] do
        assert lookup(fx, id, @in_a) == :not_found, inspect(id)

        assert [{%{count: 1}, %{policy: :EntitiesRecordsWrite, kind: :by_id}}] =
                 W.drain_not_found(ref)
      end
    end

    test "scope :all is visible with NO statement and no event; :none is :not_found with NO statement but a counted event",
         %{fx: fx} do
      ref = W.attach_not_found!()

      {all, sql} = W.statements(fn -> lookup(fx, :b, :all) end)
      assert all == {:ok, :unscoped}
      assert sql == []
      assert W.drain_not_found(ref) == []

      {none, sql} = W.statements(fn -> lookup(fx, :a, :none) end)
      assert none == :not_found
      assert sql == []
      assert length(W.drain_not_found(ref)) == 1
    end

    test "the id list is one bound array: a hostile node list matches nothing and injects nothing",
         %{fx: fx} do
      hostile = {:nodes, ["sf-a' OR '1'='1", "sf-%", "sf-_", "x\\", "sf-b\" OR 1=1 --"]}
      assert lookup(fx, :a, hostile) == :not_found
      assert lookup(fx, :b, hostile) == :not_found
      assert lookup(fx, :b, {:nodes, ["sf-b"]}) == {:ok, {:column, "scope_node"}}
    end

    test ":tenant_wide, undeclared, hidden-by-name types are :not_found WITHOUT a statement against the type table",
         %{fx: fx} do
      master = F.create!(fx.schema_name, "scoped_master", %{"name" => "m"})
      plain = F.create_plain_undeclared!(fx, fx.items)

      for {type, id} <- [
            {"scoped_master", master.record_id},
            {"plain_undeclared", plain.record_id},
            {"no_such_type", Ecto.UUID.generate()}
          ] do
        {result, sql} = W.statements(fn -> lookup(fx, id, @in_a, type) end)
        assert result == :not_found, type
        refute Enum.any?(sql, &(&1 =~ "ANY(")), "#{type}: no id lookup statement"
      end
    end

    test "fail closed when the declared column cannot be read: the type table dropped, or its scope column dropped (T-D6)",
         %{fx: fx} do
      assert lookup(fx, :a, @in_a) == {:ok, {:column, "scope_node"}}
      :ok = F.drop_scope_column!(fx, @type_item)
      assert lookup(fx, :a, @in_a) == :not_found
      assert lookup(fx, :b, {:nodes, ["sf-b"]}) == :not_found

      other = F.provision!("r518-rs3")
      _ = Sandbox.checkin(Repo)
      other_items = F.seed_items!(other)
      :ok = F.drop_type_table!(other, @type_item)

      assert ScopedLookup.fetch_in_scope(
               @type_item,
               other_items.a.record_id,
               @in_a,
               other.schema_name,
               @telemetry
             ) == :not_found
    end

    test "emit_not_found/2 returns :ok and emits exactly the closed shape", %{fx: _fx} do
      ref = W.attach_not_found!()
      assert ScopedLookup.emit_not_found(:EntitiesRecordsImport, :import) == :ok

      assert [{%{count: 1}, metadata}] = W.drain_not_found(ref)
      assert metadata == %{policy: :EntitiesRecordsImport, kind: :import}
    end

    test "a tenant that is not the record's tenant sees nothing (the prefix scopes the statement)",
         %{fx: fx} do
      other = S.tenant!("r518-rs4")

      assert ScopedLookup.fetch_in_scope(
               @type_item,
               fx.items.a.record_id,
               @in_a,
               other.schema_name,
               @telemetry
             ) ==
               :not_found
    end
  end

  describe "ScopedWrites.type_gate/3 against the database" do
    test "column types and a managed column type are gated in; :tenant_wide, undeclared and nonexistent types are refused",
         %{fx: fx} do
      F.create_plain_undeclared!(fx, fx.items)
      schema = fx.schema_name

      assert ScopedWrites.type_gate("scoped_item", @in_a, schema) ==
               {:ok, {:column, "scope_node"}}

      assert ScopedWrites.type_gate("scoped_child", @in_a, schema) ==
               {:ok, {:column, "scope_node"}}

      assert ScopedWrites.type_gate("scoped_managed_item", @in_a, schema) ==
               {:ok, {:column, "scope_node"}}

      for type <- ["scoped_master", "plain_undeclared", "no_such_type"] do
        assert ScopedWrites.type_gate(type, @in_a, schema) == :refused, type
      end

      assert ScopedWrites.type_gate("scoped_item", :all, schema) == {:ok, :unscoped}
      assert ScopedWrites.type_gate("scoped_item", :none, schema) == :refused
    end

    test "under the PRODUCTION allowlist [] a declared unmanaged type is refused, the managed one stays in",
         %{fx: fx} do
      original = Application.get_env(:letflow, :scope_declaration_unmanaged_modules)
      Application.put_env(:letflow, :scope_declaration_unmanaged_modules, [])

      on_exit(fn ->
        Application.put_env(:letflow, :scope_declaration_unmanaged_modules, original)
      end)

      schema = fx.schema_name
      assert ScopedWrites.type_gate("scoped_item", @in_a, schema) == :refused
      assert ScopedWrites.type_gate("scoped_master", @in_a, schema) == :refused

      assert ScopedWrites.type_gate("scoped_managed_item", @in_a, schema) ==
               {:ok, {:column, "scope_node"}}
    end
  end

  # keeps the capture helper referenced for readers: the statements of a request are compared
  # in the HTTP files, here only the record layer is exercised
  test "Fixture.capture_repo_queries sees the Records statements (sanity for the statement assertions)",
       %{
         fx: fx
       } do
    {{:ok, _}, queries} = Fixture.capture_repo_queries(fn -> create(fx, "sf-a", :all) end)
    assert queries != []
  end
end
