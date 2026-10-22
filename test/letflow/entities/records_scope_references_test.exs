defmodule Letflow.Entities.RecordsScopeReferencesTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-ii, BUG-1 (SEC step-20 ruling, design r2b 5.3, T-W8 (f) and (g);
  spec `test/specs/REQ-518-2c-ii.md`): the REFERENCES of the NEW document of a scoped write are
  resolved through the scope of the REFERENCED type, at the `Records` layer (module code), in
  `ScopedWrites.check_references/4`, `check_batch_references/4` and `ScopedLookup.all_in_scope?/4`.

    * `Records.create_record/2` and `update_record/2` with a scoped set and an out-of-scope or
      nonexistent reference are `{:error, :scope_refused}` and write nothing; an unchanged stored
      reference that left the set is refused too (fail closed); scope `:all` is unchanged;
    * `check_references/4`: one statement per field for in-scope, out-of-scope and absent ids
      alike, existence only for a `:tenant_wide` target, NO statement for an undeclared target,
      null / absent values or a malformed value, every field evaluated;
    * `all_in_scope?/4` and `check_batch_references/4`: ONE statement for the whole list or batch;
    * the foreign-key backstop: the referenced row is removed after every pre-check passed (it is
      locked FOR UPDATE by another connection, so the writer blocks on the foreign key of its
      INSERT); a scoped writer gets `{:error, :scope_refused}`, never the raw database error,
      while scope `:all` gets the constant 422 shape `{:record_payload_invalid, [%Violation{rule:
      :reference}]}` (issue #2832).

  `async: false`: a dedicated provisioned tenant, real cross-connection locks.
  """

  use Letflow.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Records
  alias Letflow.Entities.ScopedLookup
  alias Letflow.Entities.ScopedWrites
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScopeWritesFixture, as: W

  @in_a {:nodes, ["sf-a", "sf-a1", "sf-a2x"]}

  setup do
    fx = F.provision!("r518-rr")
    _ = Sandbox.checkin(Repo)
    {:ok, fx: Map.put(fx, :items, F.seed_items!(fx))}
  end

  # ---- helpers ------------------------------------------------------------------------------

  defp child_values(item_id) do
    base = %{"name" => "c", "scope_node" => "sf-a"}
    if item_id == :omit, do: base, else: Map.put(base, "item_id", item_id)
  end

  defp attrs(extra) do
    Map.merge(
      %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()},
      Map.new(extra)
    )
  end

  defp create_child(fx, item_id, scope) do
    Records.create_record(
      attrs(entity_type: "scoped_child", field_values: child_values(item_id), scope: scope),
      fx.schema_name
    )
  end

  defp update_child(fx, record_id, item_id, scope) do
    Records.update_record(
      attrs(
        entity_type: "scoped_child",
        record_id: record_id,
        field_values: child_values(item_id),
        scope: scope
      ),
      fx.schema_name
    )
  end

  defp definition(fks) do
    %EntityDefinition{
      name: "ref_probe",
      definition_json: %{
        "foreign_keys" =>
          for(
            {field, target} <- fks,
            do: %{"field" => to_string(field), "references_entity" => target}
          )
      }
    }
  end

  defp lookups(sql), do: Enum.count(sql, &(&1 =~ "entity_scoped_item" and &1 =~ "ANY("))

  # ===========================================================================================
  describe "T-W8 (f) Records with a scoped set" do
    test "create: an out-of-scope, NULL-scope, nonexistent or malformed reference is :scope_refused and writes nothing; in-scope and omitted succeed",
         %{fx: fx} do
      before = W.counts(fx)

      for ref <- [
            fx.items.b.record_id,
            fx.items.none.record_id,
            Ecto.UUID.generate(),
            "not-a-uuid"
          ] do
        assert create_child(fx, ref, @in_a) == {:error, :scope_refused}, inspect(ref)
      end

      assert W.counts(fx) == before
      assert {:ok, _} = create_child(fx, fx.items.a.record_id, @in_a)
      assert {:ok, _} = create_child(fx, :omit, @in_a)
    end

    test "a refused reference is decided BEFORE the transaction opens (no begin statement), for create and update",
         %{fx: fx} do
      {:ok, %{record: child}} = create_child(fx, fx.items.a.record_id, :all)

      {create_result, create_sql} =
        W.statements(fn -> create_child(fx, fx.items.b.record_id, @in_a) end)

      {update_result, update_sql} =
        W.statements(fn -> update_child(fx, child.record_id, fx.items.b.record_id, @in_a) end)

      assert create_result == {:error, :scope_refused}
      assert update_result == {:error, :scope_refused}
      refute "begin" in create_sql
      refute "begin" in update_sql
    end

    test "update: the reference of the new document is checked; an UNCHANGED reference that left the set is refused too (fail closed)",
         %{fx: fx} do
      {:ok, %{record: child}} = create_child(fx, fx.items.a1.record_id, :all)
      before = W.counts(fx)

      assert update_child(fx, child.record_id, fx.items.b.record_id, @in_a) ==
               {:error, :scope_refused}

      assert update_child(fx, child.record_id, Ecto.UUID.generate(), @in_a) ==
               {:error, :scope_refused}

      assert W.counts(fx) == before

      assert W.stored_values(fx, "scoped_child", child.record_id)["item_id"] ==
               fx.items.a1.record_id

      narrow = {:nodes, ["sf-a"]}

      assert update_child(fx, child.record_id, fx.items.a1.record_id, narrow) ==
               {:error, :scope_refused}

      assert {:ok, _} = update_child(fx, child.record_id, fx.items.a.record_id, narrow)
    end

    test "scope :all is unchanged: an out-of-scope reference is written; a nonexistent one is a raw error, NOT :scope_refused (pre-existing, issue #2832)",
         %{fx: fx} do
      assert {:ok, _} = create_child(fx, fx.items.b.record_id, :all)
      assert {:error, reason} = create_child(fx, Ecto.UUID.generate(), :all)
      refute reason == :scope_refused
    end
  end

  # ===========================================================================================
  describe "ScopedWrites.check_references/4" do
    test "a column-declared target resolves through its scope; one statement per field, for in-scope, out-of-scope and absent ids alike",
         %{fx: fx} do
      d = definition(m: "scoped_item")

      results =
        for id <- [fx.items.a.record_id, fx.items.b.record_id, Ecto.UUID.generate()] do
          {verdict, sql} =
            W.statements(fn ->
              ScopedWrites.check_references(d, %{"m" => id}, @in_a, fx.schema_name)
            end)

          {verdict, lookups(sql)}
        end

      assert results == [{:ok, 1}, {:refused, 1}, {:refused, 1}]
    end

    test "a :tenant_wide target needs only existence; an undeclared target is refused with NO lookup statement",
         %{fx: fx} do
      master = F.create!(fx.schema_name, "scoped_master", %{"name" => "m"})
      plain = F.create_plain_undeclared!(fx, fx.items)
      schema = fx.schema_name
      wide = definition(m: "scoped_master")

      assert ScopedWrites.check_references(wide, %{"m" => master.record_id}, @in_a, schema) == :ok

      assert ScopedWrites.check_references(wide, %{"m" => Ecto.UUID.generate()}, @in_a, schema) ==
               :refused

      {verdict, sql} =
        W.statements(fn ->
          ScopedWrites.check_references(
            definition(m: "plain_undeclared"),
            %{"m" => plain.record_id},
            @in_a,
            schema
          )
        end)

      assert verdict == :refused
      refute Enum.any?(sql, &(&1 =~ "ANY("))
    end

    test "null and absent values are skipped; malformed values are refused; both without a statement; :none refuses a reference; :all reads nothing",
         %{fx: fx} do
      d = definition(m: "scoped_item")
      schema = fx.schema_name

      for fv <- [%{}, %{"m" => nil}] do
        assert {:ok, []} =
                 W.statements(fn -> ScopedWrites.check_references(d, fv, @in_a, schema) end)
      end

      for bad <- [5, "", "x", ["a"], %{}] do
        assert {:refused, []} =
                 W.statements(fn ->
                   ScopedWrites.check_references(d, %{"m" => bad}, @in_a, schema)
                 end)
      end

      assert ScopedWrites.check_references(d, %{"m" => fx.items.a.record_id}, :none, schema) ==
               :refused

      assert {:ok, []} =
               W.statements(fn ->
                 ScopedWrites.check_references(
                   d,
                   %{"m" => Ecto.UUID.generate()},
                   :all,
                   schema
                 )
               end)
    end

    test "every field is evaluated (no short-circuit): two fields cost two statements even when the first is refused",
         %{fx: fx} do
      d = definition(m: "scoped_item", n: "scoped_item")

      {verdict, sql} =
        W.statements(fn ->
          ScopedWrites.check_references(
            d,
            %{"m" => fx.items.b.record_id, "n" => fx.items.a.record_id},
            @in_a,
            fx.schema_name
          )
        end)

      assert verdict == :refused
      assert lookups(sql) == 2
    end

    test "a definition without foreign_keys needs no statement", %{fx: fx} do
      assert {:ok, []} =
               W.statements(fn ->
                 ScopedWrites.check_references(
                   %EntityDefinition{definition_json: %{}},
                   %{"x" => 1},
                   @in_a,
                   fx.schema_name
                 )
               end)
    end
  end

  describe "ScopedLookup.all_in_scope?/4 and check_batch_references/4" do
    test "all-or-nothing over the distinct ids with ONE statement; deleted is not in the predicate; [], :all and :none need none",
         %{fx: fx} do
      schema = fx.schema_name
      in_a = [fx.items.a.record_id, fx.items.a1.record_id]

      {ok?, sql} =
        W.statements(fn ->
          ScopedLookup.all_in_scope?("scoped_item", in_a ++ in_a, @in_a, schema)
        end)

      assert ok?
      assert lookups(sql) == 1

      {mixed?, sql} =
        W.statements(fn ->
          ScopedLookup.all_in_scope?(
            "scoped_item",
            in_a ++ [fx.items.b.record_id],
            @in_a,
            schema
          )
        end)

      refute mixed?
      assert lookups(sql) == 1

      assert {:ok, _} =
               Records.delete_record(
                 attrs(
                   entity_type: "scoped_item",
                   record_id: fx.items.a1.record_id,
                   scope: :all
                 ),
                 schema
               )

      assert ScopedLookup.all_in_scope?("scoped_item", [fx.items.a1.record_id], @in_a, schema)

      assert {true, []} =
               W.statements(fn ->
                 ScopedLookup.all_in_scope?("scoped_item", [], @in_a, schema)
               end)

      assert {true, []} =
               W.statements(fn ->
                 ScopedLookup.all_in_scope?("scoped_item", in_a, :all, schema)
               end)

      assert {false, []} =
               W.statements(fn ->
                 ScopedLookup.all_in_scope?("scoped_item", in_a, :none, schema)
               end)
    end

    test "check_batch_references: ONE statement whatever the size; a bad entry anywhere, a malformed value or a non-map entry refuses the whole batch",
         %{fx: fx} do
      schema = fx.schema_name
      entry = fn ref -> %{"field_values" => %{"item_id" => ref}} end

      good = [
        entry.(fx.items.a.record_id),
        entry.(fx.items.a1.record_id),
        entry.(nil),
        %{"field_values" => %{}}
      ]

      {verdict, sql} =
        W.statements(fn ->
          ScopedWrites.check_batch_references("scoped_child", good, @in_a, schema)
        end)

      assert verdict == :ok
      assert lookups(sql) == 1

      for position <- 0..4, bad <- [fx.items.b.record_id, Ecto.UUID.generate(), "x", 5] do
        batch = List.insert_at(good, position, entry.(bad))

        assert ScopedWrites.check_batch_references("scoped_child", batch, @in_a, schema) ==
                 :refused,
               "#{inspect(bad)} @ #{position}"
      end

      for odd <- ["str", nil, 7, %{"record_id" => "x"}, %{"field_values" => 5}] do
        assert ScopedWrites.check_batch_references("scoped_child", [odd], @in_a, schema) ==
                 :refused
      end

      assert ScopedWrites.check_batch_references("no_such_type", good, @in_a, schema) == :refused

      assert ScopedWrites.check_batch_references(
               "scoped_child",
               [entry.(Ecto.UUID.generate())],
               :all,
               schema
             ) == :ok
    end
  end

  # ===========================================================================================
  describe "T-W8 (g) the foreign-key backstop" do
    # another connection locks the REFERENCED row; the writer passes every pre-check and blocks
    # on the foreign key of its INSERT; the holder removes the referenced row and commits
    defp fk_race(fx, target_key, writer_fun) do
      parent = self()
      schema = fx.schema_name
      target = Ecto.UUID.dump!(fx.items[target_key].record_id)

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s|SELECT 1 FROM "#{schema}".entity_scoped_item WHERE record_id = $1 FOR UPDATE|,
              [target]
            )

            send(parent, :locked)

            receive do
              :go -> :ok
            after
              20_000 -> flunk("never released")
            end

            Repo.query!(~s|DELETE FROM "#{schema}".entity_scoped_item WHERE record_id = $1|, [
              target
            ])
          end)
        end)

      assert_receive :locked, 10_000
      writer = Task.async(writer_fun)
      assert S.lock_waiter?("entity_scoped_child"), "the writer never queued on the foreign key"
      send(holder.pid, :go)
      assert {:ok, _} = Task.await(holder, 20_000)
      Task.await(writer, 30_000)
    end

    test "the referenced row LEAVES the scope after the pre-check (the type's sequence lock is held elsewhere): the in-transaction recheck refuses, nothing is written",
         %{fx: fx} do
      # make sure the type's registry and sequence rows exist
      assert {:ok, _} = create_child(fx, fx.items.a.record_id, :all)

      parent = self()
      schema = fx.schema_name
      target = Ecto.UUID.dump!(fx.items.a2x.record_id)

      %{rows: [[instance_id]]} =
        Repo.query!(
          ~s|SELECT instance_id FROM "#{schema}".entity_type_instances WHERE entity_type = 'scoped_child'|
        )

      before = W.counts(fx)

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!(
              ~s|SELECT 1 FROM "#{schema}".instance_sequence WHERE instance_id = $1 FOR UPDATE|,
              [instance_id]
            )

            send(parent, :locked)

            receive do
              :go -> :ok
            after
              20_000 -> flunk("never released")
            end

            Repo.query!(
              ~s|UPDATE "#{schema}".entity_scoped_item SET scope_node = 'sf-b' WHERE record_id = $1|,
              [target]
            )
          end)
        end)

      assert_receive :locked, 10_000
      ref = fx.items.a2x.record_id
      writer = Task.async(fn -> create_child(fx, ref, @in_a) end)
      assert S.lock_waiter?("instance_sequence"), "the writer never queued on the sequence lock"
      send(holder.pid, :go)
      assert {:ok, _} = Task.await(holder, 20_000)

      assert Task.await(writer, 30_000) == {:error, :scope_refused}
      assert W.counts(fx) == before
    end

    test "a scoped writer gets {:error, :scope_refused} (never the raw database error) and nothing is written",
         %{fx: fx} do
      before = W.counts(fx)
      ref = fx.items.a2x.record_id

      assert fk_race(fx, :a2x, fn -> create_child(fx, ref, @in_a) end) == {:error, :scope_refused}
      assert W.counts(fx) == before
    end

    test "the same race with scope :all is a constant reference violation (issue #2832)", %{
      fx: fx
    } do
      ref = fx.items.a2x.record_id

      assert {:error, {:record_payload_invalid, [violation]}} =
               fk_race(fx, :a2x, fn -> create_child(fx, ref, :all) end)

      assert violation.rule == :reference
      assert violation.path == ["item_id"]
      assert violation.message == "referenced record does not exist"
      refute inspect(violation) =~ ref
    end

    test "T-8/T-5: a tenant-wide create or update with a nonexistent reference is a constant violation and writes nothing",
         %{fx: fx} do
      {:ok, %{record: child}} = create_child(fx, fx.items.a.record_id, :all)
      before = W.counts(fx)
      bad = Ecto.UUID.generate()

      for result <- [
            create_child(fx, bad, :all),
            update_child(fx, child.record_id, bad, :all)
          ] do
        assert {:error, {:record_payload_invalid, [violation]}} = result
        assert violation.rule == :reference
        assert violation.path == ["item_id"]
        assert violation.message == "referenced record does not exist"
        refute inspect(violation) =~ bad
      end

      assert W.counts(fx) == before

      assert W.stored_values(fx, "scoped_child", child.record_id)["item_id"] ==
               fx.items.a.record_id

      # the same ids for a scoped caller stay the generic refusal, never the 422 shape
      assert create_child(fx, bad, @in_a) == {:error, :scope_refused}
      assert update_child(fx, child.record_id, bad, @in_a) == {:error, :scope_refused}
    end

    test "T-9: a tenant-wide write with an existing reference still succeeds", %{fx: fx} do
      assert {:ok, _} = create_child(fx, fx.items.b.record_id, :all)
    end
  end
end
