defmodule Letflow.Engine.ScriptTaskEntityWritesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR C2b (design `gh2587-req499-pr-c-service-task-writes.md`, C-14, C-4 script
  half, C-8 script half): a SCRIPT-bound SERVICE_TASK apply composes the node's declared entity
  writes into the ONE CAS apply transaction.

  Real Lua scripts, real Postgres, the real dispatcher (`run_claimed/2`). Each case starts from
  a normally activated script definition whose PINNED snapshot and recorded activator are then
  patched (the activation fence accepts `entity_writes` on a SERVICE_TASK node since C1; the
  patching lets a case tamper with the snapshot and the activator).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Entities.EventTypes
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore
  alias Letflow.Repo
  alias Letflow.Support.ChaosEntityPort
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    on_exit(&ChaosEntityPort.disarm!/0)
    t = F.tenant!("gh2587c-script")
    {:ok, _} = EventTypes.seed!(t.schema_name)
    activator = Fx.user!(t.schema_name, "activator")

    Fx.define_type!(t.schema_name, "amount_rec", %{
      fields: [%{name: "total", type: :integer, required: true}]
    })

    %{t: t, activator: activator}
  end

  defp good_lines do
    [
      Map.put(
        Fx.line("amount_rec", %{"total" => %{"var" => "total"}}),
        "output_record_id_var",
        "_sys.rec"
      )
    ]
  end

  # a line whose required `total` has no source in the variables
  defp refusing_lines, do: [Fx.line("amount_rec", %{"total" => %{"var" => "missing_var"}})]

  defp bound!(t, activator, lines) do
    schema = t.schema_name
    b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2})

    snapshot = Repo.get!(InstanceDefinitionSnapshot, b.instance_id, prefix: schema)

    nodes =
      Enum.map(snapshot.graph["nodes"], fn
        %{"id" => "svc", "attributes" => attrs} = node ->
          %{node | "attributes" => Map.put(attrs, "entity_writes", lines)}

        node ->
          node
      end)

    {1, _} =
      from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^b.instance_id)
      |> Repo.update_all([set: [graph: %{snapshot.graph | "nodes" => nodes}]], prefix: schema)

    record =
      Activator.build_record(
        Activator.from_auth_context(%{user_id: activator.id, roles: ["TENANT_ADMIN"]}, false),
        [{"amount_rec", "create"}],
        DateTime.utc_now()
      )

    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^b.definition.id)
      |> Repo.update_all([set: [activated_by: record]], prefix: schema)

    b
  end

  defp records(schema), do: Fx.records(schema, "amount_rec")

  describe "C1: the real activation path accepts a script-bound node" do
    test "activate (fence lifted) -> start -> run: the records commit with the recorded authority",
         %{t: t, activator: activator} do
      schema = t.schema_name
      key = "k#{System.unique_integer([:positive])}"
      rule = F.published!(schema, key, F.doubling_source(), F.closed_manifest())

      graph =
        update_in(F.script_graph(key, rule.version), ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "svc", "attributes" => attrs} = node ->
              %{node | "attributes" => Map.put(attrs, "entity_writes", good_lines())}

            node ->
              node
          end)
        end)

      draft = F.draft_definition!(schema, graph, [])

      assert {:error, {:entity_writes_invalid, [%{node_id: "svc", index: 0}]}} =
               Letflow.Definitions.activate(draft.id, prefix: schema)

      auth = Activator.from_auth_context(%{user_id: activator.id, roles: ["TENANT_ADMIN"]}, false)

      assert {:ok, %{definition: active}} =
               Letflow.Definitions.activate(draft.id, prefix: schema, activator: auth)

      assert %{"authorized" => [%{"entity_type" => "amount_rec", "op" => "create"}]} =
               active.activated_by

      instance_id = F.start!(schema, active, %{"amount" => 2}, Ecto.UUID.generate())

      assert {row, {:ok, :applied}} = F.run_next!(schema)
      assert [rec] = records(schema)
      assert rec.field_values == %{"total" => 4}
      assert F.projection(schema, instance_id).status == :completed

      # the authority is the ACTIVATOR's (recorded by the real activation); the platform actor is
      # only the event actor
      [event] = Fx.entity_events(schema)
      assert event.actor_id == EventStore.platform_actor_id()
      assert event.metadata["source.activator_id"] == activator.id
      assert event.metadata["source.dispatch_id"] == row.id
    end
  end

  describe "C-14: success" do
    test "records, SYS, APPLIED, SCRIPT_TASK_COMPLETED, the run record and the row commit together",
         %{t: t, activator: activator} do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())

      assert {row, {:ok, :applied}} = F.run_next!(schema)

      assert [rec] = records(schema)
      assert rec.field_values == %{"total" => 4}

      projection = F.projection(schema, b.instance_id)
      assert projection.status == :completed
      assert projection.variables["_sys.rec"] == rec.record_id

      types = Fx.instance_event_types(schema, b.instance_id)
      sys = Enum.find_index(types, &(&1 == "INSTANCE_SYS_VARIABLES_SET"))
      applied = Enum.find_index(types, &(&1 == "TASK_ENTITY_WRITES_APPLIED"))
      completed = Enum.find_index(types, &(&1 == "SCRIPT_TASK_COMPLETED"))
      assert sys < applied and applied < completed
      assert "SCRIPT_RUN_RECORDED" in types

      [applied_payload] = F.payloads(schema, b.instance_id, "TASK_ENTITY_WRITES_APPLIED")
      assert applied_payload["dispatch_id"] == row.id
      assert applied_payload["task_id"] == nil

      [event] = Fx.entity_events(schema)
      assert event.actor_id == EventStore.platform_actor_id()
      assert event.idempotency_key == "sys:step:#{row.id}:0"
      assert event.metadata["source.dispatch_id"] == row.id
      assert event.metadata["source.activator_id"] == activator.id

      done = F.reload(schema, row)
      assert {done.status, done.outcome} == {:applied, "ok"}

      assert [audit] = Fx.audit_rows(schema, "entity_write.process_step")
      assert audit.actor_id == EventStore.platform_actor_id()
      assert audit.after_state["dispatch_id"] == row.id
    end

    test "a second apply of the same claim is stale and writes nothing (the CAS)", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())
      {:ok, row} = ScriptTaskDispatcher.claim_next(schema)

      result =
        {:ok, %{"total" => 4},
         %{
           row: row,
           phase: :ran,
           outcome: :ok,
           detail: nil,
           fail_code: nil,
           hmac: nil,
           stats: nil
         }}

      assert Engine.apply_script_task_result(F.claim(row), result, schema) == {:ok, :applied}
      assert Engine.apply_script_task_result(F.claim(row), result, schema) == {:ok, :stale}
      assert length(records(schema)) == 1
      assert F.projection(schema, b.instance_id).status == :completed
    end
  end

  describe "C-8 / C-14: a refusal lands ERROR through the CAS apply, never a second run" do
    test "row failed with entity_write_refused, ERROR + DLQ, the run record kept, zero records",
         %{t: t, activator: activator} do
      schema = t.schema_name
      b = bound!(t, activator, refusing_lines())

      assert {row, {:ok, :failed}} = F.run_next!(schema)

      done = F.reload(schema, row)

      assert {done.status, done.outcome, done.outcome_detail} ==
               {:failed, "script_rejected", "entity_write_refused"}

      assert records(schema) == []
      assert Fx.step_idempotency_count(schema) == 0
      assert F.projection(schema, b.instance_id).status == :error
      assert F.dlq_count(schema) == 1

      types = Fx.instance_event_types(schema, b.instance_id)
      assert Enum.count(types, &(&1 == "EXECUTION_ERROR")) == 1
      assert Enum.count(types, &(&1 == "SCRIPT_RUN_RECORDED")) == 1
      refute "SCRIPT_TASK_COMPLETED" in types
      refute "TASK_ENTITY_WRITES_APPLIED" in types

      assert [refused] = Fx.audit_rows(schema, "entity_write.refused")
      assert refused.after_state["code"] == "validation_failed"
      assert refused.after_state["dispatch_id"] == row.id

      # no second run: the row is terminal
      assert F.reload(schema, row).finished_at != nil
    end

    test "a deactivated activator lands ERROR entity_write_refused", %{t: t, activator: activator} do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())

      {1, _} =
        from(u in Letflow.Identity.User, where: u.id == ^activator.id)
        |> Repo.update_all([set: [status: :inactive]], prefix: schema)

      assert {row, {:ok, :failed}} = F.run_next!(schema)
      assert F.reload(schema, row).outcome_detail == "entity_write_refused"
      assert records(schema) == []
      assert F.projection(schema, b.instance_id).status == :error
    end
  end

  describe "C-3 / C-14: contention is re-applied inside the engine" do
    test "one contention failure is re-applied; the apply then commits exactly once", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      bound!(t, activator, good_lines())
      counter = ChaosEntityPort.arm!(:deadlock_detected, 1)

      assert {row, {:ok, :applied}} = F.run_next!(schema)

      assert :counters.get(counter, 1) == 2
      assert length(records(schema)) == 1
      assert F.reload(schema, row).status == :applied
    end

    test "exhaustion lands the row failed with entity_write_contention", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())
      counter = ChaosEntityPort.arm!(:lock_not_available, :infinity)

      assert {row, {:ok, :failed}} = F.run_next!(schema)

      assert :counters.get(counter, 1) == 3
      assert records(schema) == []
      assert F.reload(schema, row).outcome_detail == "entity_write_contention"
      assert F.projection(schema, b.instance_id).status == :error
      assert F.dlq_count(schema) == 1
    end
  end

  describe "C-14: the lease bounds the re-apply loop" do
    test "with too little lease left no attempt starts: the landing runs once, no record", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())
      {:ok, row} = ScriptTaskDispatcher.claim_next(schema)

      # 5 s of lease left: below the 15 s attempt gate (and the 2 s margin)
      {1, _} =
        from(d in ScriptTaskDispatcher.ScriptTaskDispatch, where: d.id == ^row.id)
        |> Repo.update_all(
          [set: [lease_expires_at: DateTime.add(DateTime.utc_now(), 5, :second)]],
          prefix: schema
        )

      assert ScriptTaskDispatcher.run_claimed(F.reload(schema, row), schema) == {:ok, :failed}

      assert records(schema) == []
      assert F.reload(schema, row).outcome_detail == "entity_write_contention"
      assert F.projection(schema, b.instance_id).status == :error
    end

    test "sweep first, late apply second: exactly one winner, the late apply is stale", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())
      {:ok, row} = ScriptTaskDispatcher.claim_next(schema)

      F.expire_lease!(schema, row)
      assert %{swept: 1} = ScriptTaskDispatcher.sweep_expired_leases(schema, 64)

      result =
        {:ok, %{"total" => 4},
         %{
           row: row,
           phase: :ran,
           outcome: :ok,
           detail: nil,
           fail_code: nil,
           hmac: nil,
           stats: nil
         }}

      assert Engine.apply_script_task_result(F.claim(row), result, schema) == {:ok, :stale}

      assert records(schema) == []

      assert Enum.count(
               Fx.instance_event_types(schema, b.instance_id),
               &(&1 == "SCRIPT_RUN_RECORDED")
             ) == 1

      assert F.reload(schema, row).outcome == "timeout"
    end

    test "late apply first (lease already expired), sweep second: one landing, the sweep finds nothing",
         %{t: t, activator: activator} do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())
      {:ok, row} = ScriptTaskDispatcher.claim_next(schema)
      F.expire_lease!(schema, row)

      result =
        {:ok, %{"total" => 4},
         %{
           row: row,
           phase: :ran,
           outcome: :ok,
           detail: nil,
           fail_code: nil,
           hmac: nil,
           stats: nil
         }}

      # no budget left: the engine goes straight to its landing, through the same CAS
      assert Engine.apply_script_task_result(F.claim(row), result, schema) == {:ok, :failed}
      assert %{swept: 0} = ScriptTaskDispatcher.sweep_expired_leases(schema, 64)

      assert records(schema) == []

      assert Enum.count(
               Fx.instance_event_types(schema, b.instance_id),
               &(&1 == "SCRIPT_RUN_RECORDED")
             ) == 1

      assert F.reload(schema, row).outcome_detail == "entity_write_contention"
    end
  end

  describe "a failed script run never reaches the entity step" do
    test "a script failure is the plain incident: no plan, no entity event", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      b = bound!(t, activator, good_lines())
      {:ok, row} = ScriptTaskDispatcher.claim_next(schema)

      facts = %{
        row: row,
        phase: :ran,
        outcome: :script_error,
        detail: nil,
        fail_code: nil,
        hmac: nil,
        stats: nil
      }

      assert Engine.apply_script_task_result(
               F.claim(row),
               {:failed, :script_error, nil, facts},
               schema
             ) == {:ok, :failed}

      assert records(schema) == []
      refute "TASK_ENTITY_WRITES_APPLIED" in Fx.instance_event_types(schema, b.instance_id)
      assert F.reload(schema, row).outcome == "script_error"
    end
  end

  # Counts the CAS locks (`SELECT ... FOR UPDATE` on script_task_dispatches) of one
  # `run_claimed/2`. Each engine apply attempt takes exactly one.
  defp cas_locks(queries) do
    Enum.count(queries, fn %{query: sql} ->
      sql =~ "FOR UPDATE" and sql =~ "script_task_dispatches"
    end)
  end

  # Counts the apply attempts that reached the entity port: each one reports one `multi/3` call
  # (`ChaosEntityPort.record!/0`). Independent of how many statements an attempt issues.
  defp port_multi_calls(acc \\ 0) do
    receive do
      {:port_call, :multi, _ctx} -> port_multi_calls(acc + 1)
    after
      0 -> acc
    end
  end

  defp runner_calls(acc \\ 0) do
    receive do
      {:script_runner_called, _pid, _in_tx} -> runner_calls(acc + 1)
    after
      0 -> acc
    end
  end

  describe "I-C3 / T1: the script runs once; the dispatcher follow-up is never invoked" do
    test "a re-applied contention: one run, one apply call, the row applied", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      bound!(t, activator, good_lines())
      F.count_runner_calls!()
      counter = ChaosEntityPort.arm!(:lock_not_available, 1)

      {row, {result, cas, attempts}} = run_counted(schema)

      # attempt 1 (rolled back) + attempt 2; no follow-up: every apply attempt the port sees is
      # one CAS, and the attempts are exactly the contended runs the port itself counted
      assert result == {:ok, :applied}
      assert attempts == :counters.get(counter, 1)
      assert cas == attempts
      assert runner_calls() == 1
      assert F.reload(schema, row).status == :applied
    end

    test "a refusal landing: one run, ONE apply call (no follow-up), the row failed", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      bound!(t, activator, refusing_lines())
      F.count_runner_calls!()

      {row, {result, cas, attempts}} = run_counted(schema)

      # one apply attempt, then its landing (one CAS of its own); a dispatcher follow-up would
      # add a second apply, which is one more CAS than the attempts plus the landing
      assert result == {:ok, :failed}
      assert attempts == 1
      assert cas == attempts + 1
      assert runner_calls() == 1
      assert F.reload(schema, row).outcome_detail == "entity_write_refused"
    end

    test "exhausted contention: one run, ONE apply call, the row failed", %{
      t: t,
      activator: activator
    } do
      schema = t.schema_name
      bound!(t, activator, good_lines())
      F.count_runner_calls!()
      ChaosEntityPort.arm!(:lock_not_available, :infinity)

      {row, {result, cas, attempts}} = run_counted(schema)

      # the bounded re-applies (every attempt the port sees) + one landing; a dispatcher
      # follow-up would add one more apply
      assert result == {:ok, :failed}
      assert attempts == 3
      assert cas == attempts + 1
      assert runner_calls() == 1
      assert F.reload(schema, row).outcome_detail == "entity_write_contention"
    end

    defp run_counted(schema) do
      assert {:ok, row} = ScriptTaskDispatcher.claim_next(schema)
      ChaosEntityPort.record!()

      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          ScriptTaskDispatcher.run_claimed(row, schema)
        end)

      {row, {result, cas_locks(queries), port_multi_calls()}}
    end
  end

  describe "T4 / D-C.9: the lease governs the deadline and the guard budget (m-N2)" do
    defp set_lease!(schema, row, seconds) do
      {1, _} =
        from(d in ScriptTaskDispatcher.ScriptTaskDispatch, where: d.id == ^row.id)
        |> Repo.update_all(
          [
            set: [
              lease_expires_at:
                DateTime.add(DateTime.utc_now(), round(seconds * 1000), :millisecond)
            ]
          ],
          prefix: schema
        )
    end

    defp guard_budget_with_lease(t, activator, seconds) do
      schema = t.schema_name
      bound!(t, activator, good_lines())
      {:ok, row} = ScriptTaskDispatcher.claim_next(schema)
      set_lease!(schema, row, seconds)
      ChaosEntityPort.record!()

      outcome = ScriptTaskDispatcher.run_claimed(F.reload(schema, row), schema)

      budget =
        receive do
          {:port_call, :multi, ctx} -> ctx.guard_budget_ms
        after
          0 -> :no_attempt
        end

      {outcome, budget, row}
    end

    test "a full lease: the guard is the 10 s cap minus nothing the lease did not take", %{
      t: t,
      activator: activator
    } do
      # 40 s lease: min(20 s, 38 s) = 20 s budget, guard = min(10 s, 12 s) = 10 s
      assert {{:ok, :applied}, 10_000, _row} = guard_budget_with_lease(t, activator, 40)
    end

    test "a 20 s lease: deadline = lease - 2 s (about 18 s), guard about 10 s minus the elapsed time",
         %{t: t, activator: activator} do
      {outcome, budget, _row} = guard_budget_with_lease(t, activator, 20)
      assert outcome == {:ok, :applied}
      # min(10 s, ~18 s - 8 s) is strictly below the 10 s cap only because the lease, not the
      # 20 s total, bounds the budget
      assert budget in 8_000..10_000
    end

    test "a 18 s lease: deadline about 16 s clears the 15 s gate; guard about 8 s", %{
      t: t,
      activator: activator
    } do
      {outcome, budget, _row} = guard_budget_with_lease(t, activator, 18)
      assert outcome == {:ok, :applied}
      assert budget in 6_000..8_000
    end

    test "a 16 s lease: deadline about 14 s is under the 15 s gate: no attempt, one landing", %{
      t: t,
      activator: activator
    } do
      {outcome, budget, row} = guard_budget_with_lease(t, activator, 16)
      assert outcome == {:ok, :failed}
      assert budget == :no_attempt
      assert F.reload(t.schema_name, row).outcome_detail == "entity_write_contention"
      assert records(t.schema_name) == []
    end

    test "the port context of a script apply: dispatch origin, sentinel actor, activator subject",
         %{t: t, activator: activator} do
      schema = t.schema_name
      bound!(t, activator, good_lines())
      ChaosEntityPort.record!()

      assert {row, {:ok, :applied}} = F.run_next!(schema)

      assert_received {:port_call, :multi, ctx}
      assert ctx.origin == {:dispatch, row.id}
      assert ctx.actor_id == EventStore.platform_actor_id()
      assert ctx.subject_id == activator.id
    end
  end
end
