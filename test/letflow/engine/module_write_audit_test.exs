defmodule Letflow.Engine.ModuleWriteAuditTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design sections 4.4, 9, 11 rows "Audit and event shape",
  "Idempotency key", "Actor and scope", "Replay never re-runs"): what a successful handler
  completion leaves behind.

    * each handler `create/3` is one entity event whose `actor_id` is the COMPLETER and whose
      `source.*` metadata is the 8 declarative keys plus `source.handler_module`,
      `source.handler_name` and `source.write_ordinal`; `source.line_index` is the call's
      DECLARED index and `source.activator_id` the recorded activator;
    * each write's idempotency key is `sys:step:<task>:<line_index>:<ordinal>` (ordinals 1..n);
    * ONE `TASK_ENTITY_WRITES_APPLIED` event whose lines carry `handler_module`, `handler` and
      `write_ordinal` for handler writes, and no field value; the history response projects
      each line to `line_index` and `entity_type` only;
    * one `entity_write.process_step` audit entry per write, with the three handler keys;
    * declarative line bytes are unchanged when the node also has handler lines;
    * replay (reconstruction) never calls the entity port: no handler runs, nothing is written;
    * a retry of a committed completion is `task_not_pending` and writes nothing more.

  `async: false`: the module install, tenant provisioning and the port double are process-wide.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Engine.Reconstruction
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Support.ScriptTaskFixture

  defmodule SpyPort do
    @moduledoc false
    # Tells the registered test pid about every write-side port call, then delegates.
    @behaviour Letflow.Engine.EntityPort

    defp tell(msg) do
      case Application.get_env(:letflow, :spy_port_pid) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end

    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

    @impl true
    def authorize_module_writes(lines, ctx) do
      tell(:port_authorize)
      EntityPortImpl.authorize_module_writes(lines, ctx)
    end

    @impl true
    def prepare(lines, ctx) do
      tell(:port_prepare)
      EntityPortImpl.prepare(lines, ctx)
    end

    @impl true
    def validate_lines(lines, ctx), do: EntityPortImpl.validate_lines(lines, ctx)

    @impl true
    def multi(multi, lines, ctx) do
      tell(:port_multi)
      EntityPortImpl.multi(multi, lines, ctx)
    end

    @impl true
    def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
  end

  defp step_keys(schema) do
    Repo.all(
      from(i in "event_idempotency",
        where: like(i.idempotency_key, "sys:step:%"),
        order_by: i.idempotency_key,
        select: i.idempotency_key
      ),
      prefix: schema
    )
  end

  defp decode(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode(payload) when is_map(payload), do: payload

  # A completion by a user who is NOT the activator.
  defp distinct_completer(ctx) do
    completer = Fx.user!(ctx.schema, "completer2")
    Map.merge(ctx, %{activator: ctx.user, user: completer})
  end

  describe "entity events: actor and source metadata" do
    test "the completer is the actor, the activator is provenance, the handler keys are exact" do
      ctx = distinct_completer(Mw.case!("gh2590-r4b-au-meta", :module))
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

      assert [ledger, balance] = Fx.entity_events(ctx.schema)
      assert ledger.actor_id == ctx.user.id
      assert balance.actor_id == ctx.user.id

      expected = fn ordinal ->
        %{
          "source.kind" => "process_step",
          "source.instance_id" => ctx.instance_id,
          "source.task_id" => ctx.task.id,
          "source.node_id" => "ht",
          "source.definition_id" => ctx.definition.id,
          "source.definition_version" => ctx.definition.version,
          "source.line_index" => "0",
          "source.activator_id" => ctx.activator.id,
          "source.handler_module" => "fixture_ledger",
          "source.handler_name" => "post_entry",
          "source.write_ordinal" => Integer.to_string(ordinal)
        }
      end

      for {event, ordinal} <- [{ledger, 1}, {balance, 2}] do
        metadata = Map.take(event.metadata, Map.keys(expected.(ordinal)))
        assert metadata == expected.(ordinal)
      end

      refute Enum.any?(Map.keys(ledger.metadata), &(&1 == "source.dispatch_id"))
    end

    test "a MIXED node: the declarative line's metadata carries NO handler key; the handler's index is 1" do
      ctx = Mw.case!("gh2590-r4b-au-mixed", :mixed)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

      assert [declared, ledger, balance] = Fx.entity_events(ctx.schema)

      assert Map.take(declared.metadata, [
               "source.line_index",
               "source.handler_module",
               "source.handler_name",
               "source.write_ordinal"
             ]) == %{"source.line_index" => "0"}

      for {event, ordinal} <- [{ledger, "1"}, {balance, "2"}] do
        assert event.metadata["source.line_index"] == "1"
        assert event.metadata["source.write_ordinal"] == ordinal
      end
    end
  end

  describe "idempotency keys" do
    test "ordinals 1..n are exact, and a mixed node keeps the declarative key unchanged" do
      ctx = Mw.case!("gh2590-r4b-id-keys", :mixed)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

      task = ctx.task.id

      assert step_keys(ctx.schema) ==
               Enum.sort([
                 "sys:step:#{task}:0",
                 "sys:step:#{task}:1:1",
                 "sys:step:#{task}:1:2"
               ])
    end

    test "a pre-existing handler step key is idempotency_conflict, never success" do
      ctx = Mw.case!("gh2590-r4b-id-conflict", :module)
      started = hd(Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_STARTED"))

      Repo.insert_all(
        "event_idempotency",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            idempotency_key: "sys:step:#{ctx.task.id}:0:1",
            event_id: Ecto.UUID.dump!(started.event_id),
            event_created_at: started.created_at,
            inserted_at: DateTime.utc_now()
          }
        ],
        prefix: ctx.schema
      )

      assert {:error, {:entity_write_refused, 0, :idempotency_conflict}} =
               Fx.complete(ctx, %{"label" => "L1"})

      assert Fx.all_records(ctx.schema) == []
      assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    end
  end

  describe "the APPLIED event, the history response and the audit trail" do
    test "one v2 APPLIED event; handler lines carry the handler keys and no field value" do
      ctx = Mw.case!("gh2590-r4b-au-applied", :mixed)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "secret-value-1"})

      assert [applied] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      payload = decode(applied.payload)
      refute inspect(payload) =~ "secret-value"
      assert applied.metadata in [nil, %{}]

      assert [
               %{"line_index" => 0, "entity_type" => "stock_move"} = declared,
               %{"line_index" => 1, "entity_type" => "fxl_ledger"} = ledger,
               %{"line_index" => 1, "entity_type" => "fxl_balance"} = balance
             ] = payload["lines"]

      refute Map.has_key?(declared, "handler")
      refute Map.has_key?(declared, "write_ordinal")

      for {line, ordinal} <- [{ledger, 1}, {balance, 2}] do
        assert line["handler_module"] == "fixture_ledger"
        assert line["handler"] == "post_entry"
        assert line["write_ordinal"] == ordinal
        assert is_binary(line["record_id"]) and is_integer(line["event_global_seq"])
      end
    end

    test "the lines_hash covers both attributes for a node with module_writes" do
      ctx = Mw.case!("gh2590-r4b-au-hash", :mixed)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

      [applied] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      node =
        Enum.find(ctx.definition.graph["nodes"], &(&1["id"] == "ht"))

      expected =
        Letflow.Entities.StepWrites.lines_hash(%{
          "entity_writes" => node["attributes"]["entity_writes"],
          "module_writes" => node["attributes"]["module_writes"]
        })

      assert decode(applied.payload)["lines_hash"] == expected
    end

    test "the audit trail has one entry per write with the handler keys; the chain verifies" do
      ctx = Mw.case!("gh2590-r4b-au-trail", :mixed)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

      entries = Fx.audit_rows(ctx.schema, "entity_write.process_step")
      assert length(entries) == 3

      by_type = Map.new(entries, &{&1.after_state["entity_type"], &1.after_state})
      refute Map.has_key?(by_type["stock_move"], "handler")
      assert by_type["fxl_ledger"]["handler_module"] == "fixture_ledger"
      assert by_type["fxl_ledger"]["handler"] == "post_entry"
      assert by_type["fxl_ledger"]["write_ordinal"] == 1
      assert by_type["fxl_balance"]["write_ordinal"] == 2
      assert by_type["fxl_ledger"]["line_index"] == 1

      for entry <- entries, do: refute(inspect(entry.after_state) =~ "L1")
      assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
    end

    test "the transaction commits the task, the records, the events and the audit together" do
      ctx = Mw.case!("gh2590-r4b-au-atomic", :module)
      assert {:ok, result} = Fx.complete(ctx, %{"label" => "L1"})
      assert result.instance_status == :completed

      assert length(Fx.records(ctx.schema, "fxl_ledger")) == 1
      assert length(Fx.records(ctx.schema, "fxl_balance")) == 1
      assert length(Fx.entity_events(ctx.schema)) == 2
      assert length(Fx.audit_rows(ctx.schema, "entity_write.process_step")) == 2

      assert [_one] =
               Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      assert [_one] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_COMPLETED")
      assert Fx.task!(ctx.schema, ctx.task.id).status == :completed
    end
  end

  describe "replay and retry" do
    test "a retry of a committed completion is task_not_pending and writes nothing more" do
      ctx = Mw.case!("gh2590-r4b-rp-retry", :module)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      before = {length(Fx.all_records(ctx.schema)), step_keys(ctx.schema)}

      assert {:error, {:task_not_pending, :completed}} = Fx.complete(ctx, %{"label" => "L1"})
      assert {length(Fx.all_records(ctx.schema)), step_keys(ctx.schema)} == before
    end

    test "reconstruction never reaches the entity port: no handler runs, nothing is written" do
      ctx = Mw.case!("gh2590-r4b-rp-replay", :module)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})

      ScriptTaskFixture.put_env!(:entity_port, SpyPort)
      ScriptTaskFixture.put_env!(:spy_port_pid, self())
      before = {length(Fx.all_records(ctx.schema)), step_keys(ctx.schema)}

      assert {:ok, %{instance_state: _state}} =
               Reconstruction.reconstruct_instance(ctx.instance_id, prefix: ctx.schema)

      refute_received :port_authorize
      refute_received :port_prepare
      refute_received :port_multi
      assert {length(Fx.all_records(ctx.schema)), step_keys(ctx.schema)} == before
    end

    test "a completion DOES reach the port (positive control for the spy)" do
      ctx = Mw.case!("gh2590-r4b-rp-spy", :module)
      ScriptTaskFixture.put_env!(:entity_port, SpyPort)
      ScriptTaskFixture.put_env!(:spy_port_pid, self())

      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      assert_received :port_authorize
      assert_received :port_prepare
      assert_received :port_multi
    end

    test "the history response drops the handler keys and the record ids" do
      ctx = Mw.case!("gh2590-r4b-rp-history", :module)
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      [record | _] = Fx.records(ctx.schema, "fxl_ledger")

      [applied] = Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")

      public =
        Letflow.Api.Response.public_event_payload(
          "TASK_ENTITY_WRITES_APPLIED",
          decode(applied.payload)
        )

      assert [
               %{"line_index" => 0, "entity_type" => "fxl_ledger"} = first,
               %{"line_index" => 0, "entity_type" => "fxl_balance"}
             ] = public["lines"]

      assert Map.keys(first) |> Enum.sort() == ["entity_type", "line_index"]
      refute inspect(public) =~ record.record_id
      refute inspect(public) =~ "fixture_ledger"
    end
  end
end
