defmodule Letflow.ModuleUpgrade.WriterTest do
  @moduledoc """
  REQ-683 (GH #3681, decision 0055 D3, slice 2b): `Letflow.ModuleUpgrade.Writer.migrate_record/5`.

  Test ids follow the design: W (writer steps), E (event type), K (idempotency key), L (live
  projection equals replay and rebuild), X (cross-tenant). The lock-order row (W5) is race-only
  and has no test: the order is in the writer's moduledoc and code (instance, sequence lock, row
  `FOR UPDATE`, decisions, append). Fresh tenants only; `async: false` (committed tenants).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Record.Projector
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.ModuleUpgrade.Capability
  alias Letflow.ModuleUpgrade.Writer
  alias Letflow.Support.RecordHistoryFixture, as: R
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @type_name R.type_name()

  setup do
    t = R.tenant!("w683")
    record_id = R.record!(t, %{"title" => "case"})
    {:ok, cap} = Capability.new(t.tenant_id, "up-1", "plan-1", t.author.id)
    %{t: t, cap: cap, record_id: record_id}
  end

  defp migrate(cap, record_id, after_values, step \\ "s1"),
    do: Writer.migrate_record(cap, @type_name, record_id, after_values, step)

  defp migrated(schema) do
    Repo.all(
      from(e in Event, where: e.event_type == "ENTITY_RECORD_MIGRATED", order_by: e.global_seq),
      prefix: schema
    )
  end

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp latest(schema, record_id), do: Latest.get(record_id, @type_name, schema)

  describe "E: the event type" do
    test "E1: record_event_names/0 lists the four names in registration order" do
      assert EventTypes.record_event_names() ==
               ~w(ENTITY_RECORD_CREATED ENTITY_RECORD_UPDATED ENTITY_RECORD_DELETED ENTITY_RECORD_MIGRATED)

      assert {"ENTITY_RECORD_MIGRATED", 1} in EventTypes.seed_versions()
    end

    test "E2: the registered schema rejects an extra property and a missing key", %{t: t} do
      {:ok, instance_id} =
        Letflow.Entities.EntityTypeInstance.fetch_instance_id(@type_name, t.schema_name)

      good = %{
        "entity_type" => @type_name,
        "record_id" => Ecto.UUID.generate(),
        "entity_def_version" => "aa",
        "upgrade_id" => "u",
        "step_id" => "s",
        "plan_hash" => "p",
        "before" => %{},
        "after" => %{}
      }

      for bad <- [Map.put(good, "extra", 1), Map.delete(good, "plan_hash")] do
        attrs = %{
          instance_id: instance_id,
          event_type: "ENTITY_RECORD_MIGRATED",
          payload: Jason.encode!(bad),
          actor_id: t.author.id,
          idempotency_key: Ecto.UUID.generate()
        }

        before = event_count(t.schema_name)

        refused? =
          case EventStore.append_multi(Ecto.Multi.new(), attrs, prefix: t.schema_name) do
            {:ok, multi} -> match?({:error, _, _, _}, Repo.transaction(multi))
            {:error, _} -> true
          end

        assert refused?
        assert event_count(t.schema_name) == before
      end
    end
  end

  describe "W: the writer" do
    test "W1: a first argument that is not a capability raises FunctionClauseError", %{
      t: t,
      record_id: record_id
    } do
      not_a_capability = %{prefix: t.schema_name}

      assert_raise FunctionClauseError, fn ->
        apply(Writer, :migrate_record, [
          not_a_capability,
          @type_name,
          record_id,
          %{"title" => "x"},
          "s1"
        ])
      end
    end

    test "W2: joins an open transaction; a rollback leaves no event and the row unchanged", %{
      t: t,
      cap: cap,
      record_id: record_id
    } do
      other = R.record!(t, %{"title" => "other"})
      before = event_count(t.schema_name)

      assert {:error, :undo} =
               Repo.transaction(fn ->
                 assert {:ok, :appended} = migrate(cap, record_id, %{"title" => "a"})
                 assert {:ok, :appended} = migrate(cap, other, %{"title" => "b"})
                 Repo.rollback(:undo)
               end)

      assert event_count(t.schema_name) == before
      assert {:ok, %{field_values: %{"title" => "case"}}} = latest(t.schema_name, record_id)
      assert {:ok, %{field_values: %{"title" => "other"}}} = latest(t.schema_name, other)
    end

    test "W3: an x_ key is refused before any query", %{t: t, cap: cap, record_id: record_id} do
      before = event_count(t.schema_name)
      assert {:error, :x_key_not_writable} = migrate(cap, record_id, %{"x_note" => "n"})
      assert event_count(t.schema_name) == before
    end

    test "W4: an entity type with no synthetic instance is :entity_type_not_found", %{
      cap: cap,
      record_id: record_id
    } do
      assert {:error, :entity_type_not_found} =
               Writer.migrate_record(cap, "no_such_type", record_id, %{"a" => 1}, "s1")
    end

    test "W6: a missing record is :record_not_found; a deleted one is skipped", %{
      t: t,
      cap: cap,
      record_id: record_id
    } do
      assert {:error, :record_not_found} = migrate(cap, Ecto.UUID.generate(), %{"title" => "x"})

      :ok = R.delete!(t, record_id)
      before = event_count(t.schema_name)
      assert {:ok, :skipped_deleted} = migrate(cap, record_id, %{"title" => "x"})
      assert event_count(t.schema_name) == before
    end

    test "W7: equal values and an empty after map are :unchanged and append nothing", %{
      t: t,
      cap: cap,
      record_id: record_id
    } do
      before = event_count(t.schema_name)
      assert {:ok, :unchanged} = migrate(cap, record_id, %{"title" => "case"})
      assert {:ok, :unchanged} = migrate(cap, record_id, %{})
      assert event_count(t.schema_name) == before
    end

    test "W8: a change appends one event with the eight payload keys and applies it", %{
      t: t,
      cap: cap,
      record_id: record_id
    } do
      {:ok, row} = latest(t.schema_name, record_id)

      assert {:ok, :appended} = migrate(cap, record_id, %{"title" => "new", "secret" => "z"})
      assert [event] = migrated(t.schema_name)
      assert event.actor_id == t.author.id

      assert Enum.sort(Map.keys(event.payload)) ==
               Enum.sort(
                 ~w(entity_type record_id entity_def_version upgrade_id step_id plan_hash before after)
               )

      assert event.payload["before"] == %{"title" => "case", "secret" => nil}
      assert event.payload["after"] == %{"title" => "new", "secret" => "z"}
      assert event.payload["upgrade_id"] == "up-1"
      assert event.payload["plan_hash"] == "plan-1"
      assert event.payload["step_id"] == "s1"

      assert event.payload["entity_def_version"] ==
               Base.encode16(row.entity_def_version, case: :lower)

      assert {:ok, after_row} = latest(t.schema_name, record_id)
      assert after_row.field_values == %{"title" => "new", "secret" => "z"}
      assert after_row.entity_def_version == row.entity_def_version
      assert after_row.last_event_global_seq == event.global_seq
    end
  end

  describe "K: idempotency key" do
    test "K1: the same call twice gives one event; the key is module_upgrade: + 64 hex", %{
      t: t,
      cap: cap,
      record_id: record_id
    } do
      assert {:ok, :appended} = migrate(cap, record_id, %{"title" => "new"})
      assert {:ok, :unchanged} = migrate(cap, record_id, %{"title" => "new"})
      assert [event] = migrated(t.schema_name)
      assert event.idempotency_key =~ ~r/\Amodule_upgrade:[0-9a-f]{64}\z/
      assert byte_size(event.idempotency_key) == 79
    end
  end

  describe "L: the live projection equals replay and rebuild" do
    test "L1: promoted and unpromoted fields, latest and per-type row equal replay and rebuild",
         %{
           t: t,
           cap: cap
         } do
      type = "inv683"

      assert {:ok, _definition} =
               Definitions.create_definition(
                 %{
                   definition: %{
                     name: type,
                     display_name: "Invoice",
                     fields: [
                       %{name: "amount", type: :string, queried: true},
                       %{name: "notes", type: :string}
                     ]
                   },
                   created_by: t.author.id
                 },
                 t.schema_name
               )

      assert {:ok, _} =
               Definitions.activate_definition(type, t.author.id, "go-live", t.schema_name)

      assert {:ok, [promotion]} =
               TenantProvisioning.register_column_promotion(
                 type,
                 "amount",
                 %{pg_type: "text", nullable: true},
                 [t.tenant_id]
               )

      on_exit(fn ->
        Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^t.tenant_id))
      end)

      assert {:ok, _} = TenantProvisioning.run_column_promotion(promotion.id)
      assert {:ok, _} = TenantProvisioning.backfill_column_promotion(promotion.id)
      assert {:ok, _} = TenantProvisioning.activate_column_promotion(promotion.id)
      {:ok, table} = TenantProvisioning.table_name_for_entity_type(type)

      assert {:ok, %{record: created}} =
               Records.create_record(
                 %{
                   entity_type: type,
                   field_values: %{"amount" => "1", "notes" => "n"},
                   actor_id: t.author.id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 t.schema_name
               )

      record_id = created.record_id

      assert {:ok, :appended} =
               Writer.migrate_record(
                 cap,
                 type,
                 record_id,
                 %{"amount" => "2", "notes" => "m"},
                 "s1"
               )

      assert [event] = migrated(t.schema_name)

      {:ok, live} = Latest.get(record_id, type, t.schema_name)
      per_type = per_type_row(t.schema_name, table, record_id)

      assert live.field_values == %{"amount" => "2", "notes" => "m"}
      assert live.entity_def_version == created.entity_def_version
      assert live.last_event_global_seq == event.global_seq
      assert per_type.amount == "2"
      assert per_type.field_values == live.field_values
      assert per_type.last_event_global_seq == event.global_seq

      assert {:ok, snapshot} = Projector.replay_record(type, record_id, t.schema_name)
      assert snapshot.field_values == live.field_values
      assert snapshot.entity_def_version == live.entity_def_version
      assert snapshot.last_event_global_seq == live.last_event_global_seq

      assert {:ok, _} = Projector.rebuild_projection(t.schema_name, entity_type: type)
      {:ok, rebuilt} = Latest.get(record_id, type, t.schema_name)
      assert rebuilt.field_values == live.field_values
      assert rebuilt.entity_def_version == live.entity_def_version
      assert rebuilt.last_event_global_seq == live.last_event_global_seq
      assert per_type_row(t.schema_name, table, record_id) == per_type
    end
  end

  describe "X: tenant isolation" do
    test "X1: a capability for A cannot reach a record that exists only in B", %{
      t: a,
      cap: cap_a
    } do
      b = R.tenant!("w683b")
      record_b = R.record!(b, %{"title" => "b-only"})
      {:ok, b_before} = latest(b.schema_name, record_b)
      a_events = event_count(a.schema_name)
      b_events = event_count(b.schema_name)

      assert {:error, :record_not_found} = migrate(cap_a, record_b, %{"title" => "hacked"})

      assert event_count(a.schema_name) == a_events
      assert event_count(b.schema_name) == b_events
      assert {:ok, b_after} = latest(b.schema_name, record_b)
      assert b_after.field_values == b_before.field_values
      assert b_after.last_event_global_seq == b_before.last_event_global_seq
    end
  end

  defp per_type_row(schema, table, record_id) do
    sql = """
    SELECT "amount", "field_values", "last_event_global_seq"
    FROM "#{schema}"."#{table}" WHERE record_id = ($1::text)::uuid
    """

    %Postgrex.Result{rows: [[amount, fv, seq]]} = Repo.query!(sql, [record_id])
    %{amount: amount, field_values: fv, last_event_global_seq: seq}
  end
end
