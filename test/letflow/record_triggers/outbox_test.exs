defmodule Letflow.RecordTriggers.OutboxTest do
  @moduledoc """
  REQ-606 / GH #3411 part 1 (decision 0067 D1/D4, slice T-2): the same-transaction insert of a record
  trigger into `record_trigger_outbox`, loop suppression (chain and depth cap), flag-off no-op,
  rollback and replay, lineage that cannot be forged from attrs, and tenant isolation.

  Test ids follow the design: F (flag), I (insert per entry point), R (rollback, replay, step order),
  L (lineage), G (forgery), T (tenant). The backlog cap and the HTTP answers are part 2.

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the flag is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Letflow.Audit.Entry
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
  alias Letflow.EventStore.Event
  alias Letflow.RecordTriggers.Outbox
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @actor "00000000-0000-4000-8000-0000000000a6"
  @type_name "r606_item"
  @other_type "r606_other"

  setup do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end

      Application.delete_env(:letflow, :record_trigger_depth_cap)
    end)

    tenant = Letflow.Support.ScriptTaskFixture.tenant!("r606")
    schema = tenant.schema_name
    {:ok, _} = EventTypes.seed!(schema)
    for type <- [@type_name, @other_type], do: define!(schema, type)
    {:ok, schema: schema, tenant: tenant}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp define!(schema, name) do
    fields =
      for f <- ~w(label note trigger_lineage depth chain),
          do: %{name: f, type: :string, required: f == "label"}

    {:ok, row} =
      Definitions.create_definition(
        %{definition: %{name: name, display_name: name, fields: fields}, created_by: @actor},
        schema
      )

    {:ok, _} = Definitions.activate_definition(row.name, @actor, "r606", schema)
  end

  defp create(schema, overrides \\ %{}, opts \\ []) do
    attrs =
      Map.merge(
        %{
          entity_type: @type_name,
          field_values: %{"label" => "a"},
          actor_id: @actor,
          idempotency_key: Ecto.UUID.generate()
        },
        overrides
      )

    Records.create_record(attrs, schema, :tenant, opts)
  end

  defp update(schema, record_id, label, opts \\ [], overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          entity_type: @type_name,
          record_id: record_id,
          field_values: %{"label" => label},
          actor_id: @actor,
          idempotency_key: Ecto.UUID.generate()
        },
        overrides
      )

    Records.update_record(attrs, schema, :tenant, opts)
  end

  defp created!(schema, overrides \\ %{}) do
    {:ok, %{record: record}} = create(schema, overrides)
    record
  end

  defp rows(schema), do: RF.outbox_rows(schema)

  defp event_seq(schema, record_id, event_type) do
    Repo.one!(
      from(e in Event,
        where:
          e.event_type == ^event_type and fragment("?->>'record_id' = ?", e.payload, ^record_id),
        select: e.sequence_number
      ),
      prefix: schema
    )
  end

  defp audits(schema, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)

  defp collect_queries(fun) do
    ref = make_ref()
    id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach(
      id,
      [:letflow, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:query, ref, metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {:query, ^ref, query} -> drain(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp step_command(type, line_key) do
    %{
      kind: :create,
      entity_type: type,
      field_values: %{"label" => "line"},
      actor_id: @actor,
      source: %StepSource{
        kind: "process_step",
        instance_id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        node_id: "n",
        definition_id: Ecto.UUID.generate(),
        definition_version: "1",
        line_index: line_key,
        activator_id: Ecto.UUID.generate()
      }
    }
  end

  defp names(multi), do: multi |> Multi.to_list() |> Enum.map(&elem(&1, 0))

  defp assert_pending_row(row, binding, record_id, event, seq) do
    assert row.status == :pending
    assert row.attempt == 0
    assert row.depth == 0
    assert row.chain == []
    assert row.event == event
    assert row.record_id == record_id
    assert row.binding_id == binding.id
    assert row.entity_type == @type_name

    assert {row.script_key, row.script_version, row.script_sha256} ==
             {binding.script_key, binding.script_version, binding.script_sha256}

    assert row.source_seq == seq
    assert row.actor_id == @actor
  end

  # ── F flag ──────────────────────────────────────────────────────────────────────────────────

  describe "F flag" do
    test "F1 flag off: no row, no read of the binding or outbox table, same results", %{
      schema: schema
    } do
      for event <- ~w(created updated deleted), do: RF.bind!(schema, @type_name, event)
      Application.put_env(:letflow, :record_triggers_enabled, false)

      {{:ok, %{record: record, is_duplicate: false}}, q1} =
        collect_queries(fn -> create(schema) end)

      {{:ok, %{is_duplicate: false}}, q2} =
        collect_queries(fn -> update(schema, record.record_id, "b") end)

      {{:ok, %{is_duplicate: false}}, q3} =
        collect_queries(fn ->
          Records.delete_record(
            %{
              entity_type: @type_name,
              record_id: record.record_id,
              actor_id: @actor,
              idempotency_key: Ecto.UUID.generate()
            },
            schema,
            :tenant
          )
        end)

      {{:ok, %{outcome: :created}}, q4} =
        collect_queries(fn ->
          Records.upsert_record_by_external_ref(
            %{
              entity_type: @type_name,
              external_ref: %{"system" => "s", "id" => "1"},
              field_values: %{"label" => "u"},
              actor_id: @actor,
              idempotency_key: Ecto.UUID.generate()
            },
            schema,
            :tenant,
            []
          )
        end)

      assert rows(schema) == []

      for q <- q1 ++ q2 ++ q3 ++ q4 do
        refute q =~ "record_trigger_bindings"
        refute q =~ "record_trigger_outbox"
      end
    end

    test "F2 flag on, no matching binding: no row", %{schema: schema} do
      RF.bind!(schema, @other_type, "created")
      created!(schema)
      assert rows(schema) == []
    end
  end

  # ── I insert per entry point ────────────────────────────────────────────────────────────────

  describe "I same-transaction insert" do
    test "I1 create_record inserts one pending row", %{schema: schema} do
      binding = RF.bind!(schema, @type_name, "created")
      record = created!(schema)
      [row] = rows(schema)

      assert_pending_row(
        row,
        binding,
        record.record_id,
        :created,
        event_seq(schema, record.record_id, "ENTITY_RECORD_CREATED")
      )
    end

    test "I2 update_record raises updated", %{schema: schema} do
      binding = RF.bind!(schema, @type_name, "updated")
      record = created!(schema)
      assert rows(schema) == []
      {:ok, _} = update(schema, record.record_id, "b")
      [row] = rows(schema)

      assert_pending_row(
        row,
        binding,
        record.record_id,
        :updated,
        event_seq(schema, record.record_id, "ENTITY_RECORD_UPDATED")
      )
    end

    test "I3 delete_record raises deleted", %{schema: schema} do
      binding = RF.bind!(schema, @type_name, "deleted")
      record = created!(schema)

      {:ok, _} =
        Records.delete_record(
          %{
            entity_type: @type_name,
            record_id: record.record_id,
            actor_id: @actor,
            idempotency_key: Ecto.UUID.generate()
          },
          schema,
          :tenant
        )

      [row] = rows(schema)

      assert_pending_row(
        row,
        binding,
        record.record_id,
        :deleted,
        event_seq(schema, record.record_id, "ENTITY_RECORD_DELETED")
      )
    end

    test "I4 upsert raises created on insert and updated on update", %{schema: schema} do
      created_b = RF.bind!(schema, @type_name, "created")
      updated_b = RF.bind!(schema, @type_name, "updated")

      upsert = fn label ->
        Records.upsert_record_by_external_ref(
          %{
            entity_type: @type_name,
            external_ref: %{"system" => "s", "id" => "7"},
            field_values: %{"label" => label},
            actor_id: @actor,
            idempotency_key: Ecto.UUID.generate()
          },
          schema,
          :tenant,
          []
        )
      end

      {:ok, %{outcome: :created, record: record}} = upsert.("one")
      {:ok, %{outcome: :unchanged}} = upsert.("one")
      assert [%{event: :created, binding_id: b1}] = rows(schema)
      assert b1 == created_b.id
      {:ok, %{outcome: :updated}} = upsert.("two")
      assert [_, %{event: :updated, binding_id: b2, record_id: rid}] = rows(schema)
      assert {b2, rid} == {updated_b.id, record.record_id}
    end

    test "I5 command_multi inserts a created row at depth 0", %{schema: schema} do
      binding = RF.bind!(schema, @type_name, "created")
      {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
      {:ok, multi} = Records.command_multi(step_command(@type_name, 0), schema, :tenant)
      assert {:ok, changes} = Repo.transaction(multi)
      assert %{inserted: 1, suppressed: 0} = changes[{:line, 0, :enqueue_trigger}]
      [row] = rows(schema)

      assert {row.event, row.depth, row.chain, row.status, row.binding_id} ==
               {:created, 0, [], :pending, binding.id}

      assert row.source_seq == changes[{:line, 0, :assign_sequence}]
    end

    test "I6 a binding on another event or type yields no row", %{schema: schema} do
      RF.bind!(schema, @type_name, "updated")
      RF.bind!(schema, @other_type, "created")
      created!(schema)
      assert rows(schema) == []
    end

    test "I7 bindings on all three events: one write, one row", %{schema: schema} do
      for event <- ~w(created updated deleted), do: RF.bind!(schema, @type_name, event)
      created!(schema)
      assert [%{event: :created}] = rows(schema)
    end
  end

  # ── R rollback, replay, order ───────────────────────────────────────────────────────────────

  describe "R rollback and replay" do
    test "R1 a later failing step leaves no row and no record", %{schema: schema} do
      RF.bind!(schema, @type_name, "created")
      {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
      {:ok, multi} = Records.command_multi(step_command(@type_name, 0), schema, :tenant)
      failing = Multi.run(multi, :boom, fn _repo, _changes -> {:error, :boom} end)
      assert {:error, :boom, :boom, _} = Repo.transaction(failing)
      assert rows(schema) == []
      assert Repo.aggregate(Letflow.Entities.Record.Latest, :count, prefix: schema) == 0
    end

    test "R2 a version conflict leaves no new row", %{schema: schema} do
      RF.bind!(schema, @type_name, "updated")
      record = created!(schema)
      {:ok, _} = update(schema, record.record_id, "b")
      before = length(rows(schema))
      stale = %{expected_last_event_global_seq: record.last_event_global_seq}
      assert {:error, :record_version_conflict} = update(schema, record.record_id, "c", [], stale)
      assert length(rows(schema)) == before
    end

    test "R3 a failing insert rolls the write back", %{schema: schema} do
      RF.bind!(schema, @type_name, "created")
      Repo.query!(~s(ALTER TABLE "#{schema}".record_trigger_outbox RENAME TO outbox_moved))

      try do
        ExUnit.CaptureLog.capture_log(fn -> send(self(), {:r, create(schema)}) end)
        assert_received {:r, {:error, :trigger_enqueue_failed}}
        assert Repo.aggregate(Letflow.Entities.Record.Latest, :count, prefix: schema) == 0

        {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
        {:ok, multi} = Records.command_multi(step_command(@type_name, 0), schema, :tenant)
        log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:m, Repo.transaction(multi)}) end)

        assert_received {:m,
                         {:error, {:line, 0, :enqueue_trigger}, :trigger_enqueue_failed, _} =
                           failure}

        assert {:entity_write_failed, 0, :enqueue_trigger} = Records.interpret_in_multi(failure)
        assert log =~ "record trigger enqueue failed"
        refute log =~ "outbox_moved"
      after
        Repo.query!(~s(ALTER TABLE "#{schema}".outbox_moved RENAME TO record_trigger_outbox))
      end
    end

    test "R4 a replay with the same idempotency key inserts no second row", %{schema: schema} do
      RF.bind!(schema, @type_name, "created")
      key = Ecto.UUID.generate()
      {:ok, %{is_duplicate: false}} = create(schema, %{idempotency_key: key})
      assert {:ok, %{is_duplicate: true}} = create(schema, %{idempotency_key: key})
      assert length(rows(schema)) == 1
    end

    test "R5a command_multi: the step sits after the sequence and before the record write", %{
      schema: schema
    } do
      RF.bind!(schema, @type_name, "created")
      {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
      {:ok, multi} = Records.command_multi(step_command(@type_name, 0), schema, :tenant)
      order = names(multi)
      IO.inspect(order, label: "R5a Multi.to_list names")
      idx = &Enum.find_index(order, fn n -> n == {:line, 0, &1} end)
      assert idx.(:assign_sequence) < idx.(:enqueue_trigger)
      assert idx.(:enqueue_trigger) < idx.(:upsert_record_latest)
    end

    test "R5b hooked type: sequence, outbox insert, audit row, record write, no row lock", %{
      schema: schema,
      tenant: tenant
    } do
      %{} = Letflow.Support.ScriptTaskFixture.with_hmac!(tenant)
      RF.bind!(schema, @type_name, "created")

      manifest = %{
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string"}}
        },
        "output_schema" => %{
          "type" => "object",
          "properties" => %{"note" => %{"type" => "string"}},
          "additionalProperties" => false
        },
        "derived_fields" => ["note"],
        "fail_codes" => ["x"],
        "limits" => %{"timeout_ms" => 5_000}
      }

      rule =
        Letflow.Support.ScriptTaskFixture.published!(
          schema,
          "r606_hook",
          ~s|return { note = "N:" .. ctx.input.label }|,
          manifest,
          hook_kind: "entity_write"
        )

      pin = %{
        "script_key" => rule.key,
        "script_version" => rule.version,
        "script_sha256" => rule.sha256
      }

      actor = %{user_id: Ecto.UUID.generate(), credential: :oidc, trace_id: "r606"}
      assert {:ok, _} = Letflow.EntityTypeHooks.bind(schema, @type_name, pin, actor)

      assert {:ok, _} = EntityTypeInstance.get_or_create(@type_name, schema)
      {{:ok, _}, queries} = collect_queries(fn -> create(schema) end)

      IO.inspect(Enum.map(queries, &String.slice(&1, 0, 110)),
        label: "R5b queries",
        limit: :infinity
      )

      pos = fn pattern -> Enum.find_index(queries, &(&1 =~ pattern)) end
      seq = pos.("UPDATE \"#{schema}\".\"instance_sequence\"")
      read = pos.("record_trigger_bindings")
      insert = pos.("INSERT INTO \"#{schema}\".\"record_trigger_outbox\"")
      audit = pos.("INSERT INTO \"#{schema}\".\"audit_entries\"")
      latest = pos.("INSERT INTO \"#{schema}\".\"entity_record_latest\"")
      assert Enum.all?([seq, read, insert, audit, latest])
      assert seq < read and read < insert and insert < audit and audit < latest

      window = Enum.slice(queries, read..insert)
      refute Enum.any?(window, &(&1 =~ ~r/FOR (UPDATE|SHARE|NO KEY UPDATE)/))
    end
  end

  # ── L lineage ───────────────────────────────────────────────────────────────────────────────

  describe "L lineage and loop suppression" do
    setup %{schema: schema} do
      {:ok, binding: RF.bind!(schema, @type_name, "created"), other: Ecto.UUID.generate()}
    end

    test "L1 depth 0 chain [A] inserts depth 1 chain [A]", %{schema: s, other: a} do
      {:ok, _} = create(s, %{}, trigger_lineage: %{depth: 0, chain: [a]})
      assert [%{depth: 1, chain: [^a]}] = rows(s)
    end

    test "L2 the binding in the chain suppresses; audit entry and counter", %{
      schema: s,
      binding: b
    } do
      handler = attach_counter()
      {:ok, %{record: record}} = create(s, %{}, trigger_lineage: %{depth: 0, chain: [b.id]})
      assert rows(s) == []
      assert Repo.get_by(Letflow.Entities.Record.Latest, [record_id: record.record_id], prefix: s)
      assert [entry] = audits(s, "trigger_loop_suppressed")
      assert entry.resource_id == b.id
      assert entry.after_state == %{"binding_id" => b.id, "depth" => 1, "reason" => "in_chain"}
      assert_received {:suppressed, %{count: 1}, %{reason: "in_chain"}}
      :telemetry.detach(handler)
    end

    test "L3 depth 3 chain [A] exceeds the cap", %{schema: s, other: a, binding: b} do
      handler = attach_counter()
      {:ok, _} = create(s, %{}, trigger_lineage: %{depth: 3, chain: [a]})
      assert rows(s) == []
      assert [entry] = audits(s, "trigger_loop_suppressed")
      assert entry.after_state == %{"binding_id" => b.id, "depth" => 4, "reason" => "depth_cap"}
      assert_received {:suppressed, %{count: 1}, %{reason: "depth_cap"}}
      :telemetry.detach(handler)
    end

    test "L4 depth 2 chain [A] inserts depth 3", %{schema: s, other: a} do
      {:ok, _} = create(s, %{}, trigger_lineage: %{depth: 2, chain: [a]})
      assert [%{depth: 3, chain: [^a]}] = rows(s)
    end

    test "L5 a root write has depth 0 and an empty chain", %{schema: s} do
      {:ok, _} = create(s)
      assert [%{depth: 0, chain: []}] = rows(s)
    end

    test "L6 update_record/4 inserts and suppresses", %{schema: s, other: a, binding: b} do
      RF.bind!(s, @type_name, "updated")
      record = created!(s)
      {:ok, _} = update(s, record.record_id, "b", trigger_lineage: %{depth: 0, chain: [a]})
      assert [_, %{event: :updated, depth: 1, chain: [^a]}] = rows(s)
      before = length(rows(s))

      upd =
        Repo.one!(from(x in Letflow.RecordTriggers.Binding, where: x.event == :updated),
          prefix: s
        )

      {:ok, _} = update(s, record.record_id, "c", trigger_lineage: %{depth: 0, chain: [upd.id]})
      assert length(rows(s)) == before
      assert [%{resource_id: id}] = audits(s, "trigger_loop_suppressed")
      assert id == upd.id
      refute id == b.id
    end

    test "L7 upsert /4 takes the lineage; bad options still raise", %{schema: s, other: a} do
      attrs = %{
        entity_type: @type_name,
        external_ref: %{"system" => "s", "id" => "9"},
        field_values: %{"label" => "x"},
        actor_id: @actor,
        idempotency_key: Ecto.UUID.generate()
      }

      assert {:ok, %{outcome: :created}} =
               Records.upsert_record_by_external_ref(attrs, s, :tenant,
                 trigger_lineage: %{depth: 1, chain: [a]}
               )

      assert [%{depth: 2, chain: [^a]}] = rows(s)

      assert_raise ArgumentError, fn ->
        Records.upsert_record_by_external_ref(attrs, s, :tenant, bogus: 1)
      end

      assert_raise ArgumentError, fn ->
        Records.upsert_record_by_external_ref(attrs, s, :tenant, schema_checked: "yes")
      end

      assert_raise ArgumentError, fn -> create(s, %{}, bogus: 1) end

      assert_raise ArgumentError, fn ->
        create(s, %{}, trigger_lineage: %{depth: -1, chain: []})
      end

      assert_raise ArgumentError, fn -> create(s, %{}, trigger_lineage: %{depth: 0}) end

      assert_raise ArgumentError, fn ->
        create(s, %{}, trigger_lineage: %{depth: 0, chain: ["nope"]})
      end
    end

    test "L8 the depth cap comes from config and falls back to 3", %{schema: s, other: a} do
      Application.put_env(:letflow, :record_trigger_depth_cap, 1)
      {:ok, _} = create(s, %{}, trigger_lineage: %{depth: 1, chain: [a]})
      assert rows(s) == []
      {:ok, _} = create(s, %{}, trigger_lineage: %{depth: 0, chain: [a]})
      assert [%{depth: 1}] = rows(s)
      Application.put_env(:letflow, :record_trigger_depth_cap, "many")
      assert Outbox.depth_cap() == 3
    end

    test "L9 a failing suppression audit rolls the write back", %{schema: s, binding: b} do
      Repo.query!(~s(ALTER TABLE "#{s}".audit_entries RENAME TO audit_moved))

      try do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            send(self(), {:r, create(s, %{}, trigger_lineage: %{depth: 0, chain: [b.id]})})
          end)

        assert_received {:r, {:error, :trigger_enqueue_failed}}
        assert log =~ "record trigger enqueue failed"
        assert Repo.aggregate(Letflow.Entities.Record.Latest, :count, prefix: s) == 0
      after
        Repo.query!(~s(ALTER TABLE "#{s}".audit_moved RENAME TO audit_entries))
      end
    end

    defp attach_counter do
      id = {__MODULE__, make_ref()}
      parent = self()

      :telemetry.attach(
        id,
        [:letflow, :record_triggers, :loop_suppressed],
        fn _e, m, meta, _ -> send(parent, {:suppressed, m, meta}) end,
        nil
      )

      id
    end
  end

  # ── G forgery ───────────────────────────────────────────────────────────────────────────────

  describe "G lineage cannot be forged from attrs" do
    test "G1 direct create/update with lineage-named attrs and fields writes a depth 0 row", %{
      schema: s
    } do
      b = RF.bind!(s, @type_name, "created")
      RF.bind!(s, @type_name, "updated")
      forged = %{depth: 3, chain: [b.id]}

      fields = %{
        "label" => "a",
        "trigger_lineage" => "x",
        "depth" => "3",
        "chain" => b.id
      }

      assert {:ok, %{record: record}} =
               create(s, %{field_values: fields, trigger_lineage: forged, depth: 3, chain: [b.id]})

      assert {:ok, _} =
               update(s, record.record_id, "z", [], %{
                 field_values: fields,
                 trigger_lineage: forged,
                 depth: 3,
                 chain: [b.id]
               })

      assert [%{event: :created, depth: 0, chain: []}, %{event: :updated, depth: 0, chain: []}] =
               rows(s)
    end

    test "G5/G6 a step line (the path of HandlerWrites and StepWrites) with lineage-named fields",
         %{
           schema: s
         } do
      b = RF.bind!(s, @type_name, "created")
      {:ok, _} = EntityTypeInstance.get_or_create(@type_name, s)

      command = %{
        step_command(@type_name, 0)
        | field_values: %{
            "label" => "a",
            "trigger_lineage" => "x",
            "depth" => "3",
            "chain" => b.id
          }
      }

      {:ok, multi} = Records.command_multi(command, s, :tenant)
      assert {:ok, _} = Repo.transaction(multi)
      assert [%{event: :created, depth: 0, chain: []}] = rows(s)
    end

    test "G7 only records.ex, outbox.ex and the worker's apply.ex mention the lineage in lib/" do
      hits =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "trigger_lineage"))
        |> Enum.sort()

      assert hits == [
               "lib/letflow/entities/records.ex",
               "lib/letflow/record_triggers/apply.ex",
               "lib/letflow/record_triggers/outbox.ex"
             ]
    end
  end

  # ── T tenant ────────────────────────────────────────────────────────────────────────────────

  describe "T tenant isolation" do
    test "T1 a write in A inserts only in A's schema", %{schema: a} do
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "r606b")
      b = tenant_b.schema_name
      {:ok, _} = EventTypes.seed!(b)
      define!(b, @type_name)
      RF.bind!(a, @type_name, "created")
      created!(a)
      assert length(rows(a)) == 1
      assert rows(b) == []

      RF.bind!(b, @type_name, "created")
      created!(a)
      assert length(rows(a)) == 2
      assert rows(b) == []
    end
  end
end
