defmodule Letflow.Engine.ServiceTaskEntityWritesSentinelTest do
  @moduledoc """
  GH #2587 / REQ-499 PR C, C-1 (design `gh2587-req499-pr-c-service-task-writes.md` D-C.4, F-C11,
  OQ-C6; decision 0054 AC 22 / N8): the SENTINEL PROOF, the first commit of C2 and a hard gate.

  A SERVICE_TASK completion has no human completer, so the entity event's `actor_id` is
  `EventStore.platform_actor_id()` (a uuid that is not a row in `users`) and the activator is
  recorded in `source.activator_id` only. The sentinel has never been used on an ENTITY-type
  stream. This test creates a record through `Records.command_multi/3` with the sentinel as actor
  on a synthetic type stream and proves that every layer accepts it and every reader reads it
  without resolving `actor_id` to a user:

    * the event row, `entity_record_latest`, the synthetic projection and the `Records` result;
    * the record read back through the entity QUERY path (`Compiler` / `Allowlist` / `Cursor`);
    * the tenant audit entry with the sentinel actor and `activator_id` in `after_state`.

  OQ-C6 fallback: if any layer refuses, C2 STOPS (the activation fence stays closed) and the
  design reopens; this test would then assert the stable code instead of success (the fence has
  since been lifted in C1).

  Real Postgres, `async: false` (tenant provisioning switches the sandbox to `:auto`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.StepSource
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection

  @type_name "stock_move"

  setup do
    base = Fx.tenant_case!("gh2587c-sentinel")
    Fx.define_type!(base.schema, @type_name, %{})
    {:ok, _instance_id} = EntityTypeInstance.get_or_create(@type_name, base.schema)
    {:ok, base}
  end

  test "the sentinel is not a user row (the premise of the proof)", %{schema: schema} do
    sentinel = EventStore.platform_actor_id()
    assert {:error, _} = Letflow.Identity.get_user(sentinel, prefix: schema)
  end

  test "C-1: a record written with the platform sentinel as actor is accepted and readable", %{
    schema: schema,
    user: activator
  } do
    sentinel = EventStore.platform_actor_id()
    dispatch_id = Ecto.UUID.generate()

    {:ok, source} =
      StepSource.new(%{
        instance_id: Ecto.UUID.generate(),
        dispatch_id: dispatch_id,
        node_id: "svc",
        definition_id: Ecto.UUID.generate(),
        definition_version: "1.0.0",
        line_index: 0,
        activator_id: activator.id
      })

    command = %{
      kind: :create,
      entity_type: @type_name,
      field_values: %{"label" => "from a service task"},
      actor_id: sentinel,
      source: source
    }

    assert {:ok, multi} = Records.command_multi(command, schema, :tenant)
    assert {:ok, changes} = Repo.transaction(multi)

    # the Records result: the Latest row and the event the line steps produced
    assert %Latest{record_id: record_id} = changes[{:line, 0, :upsert_record_latest}]
    assert %{global_seq: seq} = changes[{:line, 0, :insert_event}]

    # the event row
    [event] =
      Repo.all(from(e in Event, where: e.event_type == "ENTITY_RECORD_CREATED"), prefix: schema)

    assert event.actor_id == sentinel
    assert event.idempotency_key == "sys:step:" <> dispatch_id <> ":0"
    assert event.metadata["source.dispatch_id"] == dispatch_id
    assert event.metadata["source.activator_id"] == activator.id
    refute Map.has_key?(event.metadata, "source.task_id")
    assert event.global_seq == seq

    # entity_record_latest
    [latest] = Fx.records(schema, @type_name)
    assert latest.record_id == record_id
    assert latest.field_values == %{"label" => "from a service task"}
    assert latest.last_event_global_seq == seq

    # the synthetic type stream's projection moved
    {:ok, synthetic_id} = EntityTypeInstance.fetch_instance_id(@type_name, schema)
    projection = Repo.get!(InstanceProjection, synthetic_id, prefix: schema)
    assert projection.last_event_seq >= 1

    # a read through the entity QUERY path resolves nothing about the actor
    request = %{entity_type: @type_name}
    assert {:ok, compiled} = Compiler.compile(request, schema, :all)
    assert {:ok, allowlist} = Allowlist.load(@type_name, schema)
    assert {:ok, page} = Cursor.paginate(request, compiled, allowlist, %{page_size: 10}, schema)
    assert [item] = page.items
    assert item.record_id == record_id
    assert item.field_values["label"] == "from a service task"

    # the tenant audit entry with the sentinel actor and the activator in after_state
    assert {:ok, _entry} =
             Audit.insert_entry(
               Repo,
               %{
                 actor_id: sentinel,
                 action: "entity_write.process_step",
                 resource_type: "entity_record",
                 resource_id: record_id,
                 before_state: nil,
                 after_state: %{
                   "entity_type" => @type_name,
                   "record_id" => record_id,
                   "dispatch_id" => dispatch_id,
                   "activator_id" => activator.id
                 },
                 trace_id: nil
               },
               schema
             )

    [row] = Fx.audit_rows(schema, "entity_write.process_step")
    assert row.actor_id == sentinel
    assert row.after_state["activator_id"] == activator.id
    assert {:ok, :valid} = Audit.verify_chain(schema)
  end
end
