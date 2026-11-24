defmodule Letflow.Engine.PlatformStepRunnerTest do
  @moduledoc """
  T-2703 (pilot gap G1 remainder): the engine RUNS a platform step.

  A definition with a `platform_call` node starts through `Letflow.Engine.create/2` (the engine arms
  the `platform_step_dispatches` row inside its own transaction and parks the instance on the
  node), `Letflow.Engine.PlatformStepRunner` runs the due rows outside every transaction under the
  authority rule of decision 0094, and the instance continues with the declared outputs.

  | ID | What it proves |
  |---|---|
  | R1 | a platform_call definition starts and COMPLETES; the outputs are merged |
  | R2 | the row is armed once per entry; the instance waits on the node until the runner ran |
  | R3 | an authority fence refusal puts the instance in ERROR: EXECUTION_ERROR + DLQ entry |
  | R4 | the retry resumes the instance exactly once (a second retry moves nothing) |
  | R5 | a crash between the claim and the result is taken over after the lease; a live lease is not |
  | R6 | a foreign (company) tenant schema never runs; a company tenant cannot hold a call |
  | R7 | the key of another instance's call is refused, never resumed |
  | R8 | the config parse: route kind and conflicting routes |
  | R9 | a `given_up` row whose failure landing never ran is landed by the sweep, once |
  | R10 | a node that declares entity lines is refused at activation |
  | R12 | a result older than a day is still applied / landed by the sweep |
  | R11 | a loop back to a completed platform_call node runs it again and completes |
  | R13 | an apply refusal is LANDED (ERROR + EXECUTION_ERROR + DLQ), its retry runs nothing; an outstanding row of a cancelled instance is left alone; the sweep pages past its limit |
  | R14 | a duplicate arm of the SAME visit (row pending / running / advanced-not-applied / given_up, also two processes at once) is the same row and the function runs once; the visit counts APPLIED visits, not rows |
  | R15 | a result whose hop chain has no matching edge is landed as the PLATFORM failure (platform_step DLQ entry), and the G7 retry resumes it |

  The state x event table these rows prove is in `docs/platform-steps.md` ("The state machine
  of a platform_call dispatch").

  `async: false`: the platform tenant pin is application configuration, which is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Dlq
  alias Letflow.Engine
  alias Letflow.Engine.PlatformStepRunner
  alias Letflow.Engine.ServiceTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.GroupMember
  alias Letflow.Instances.StepRetry
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @function "platform.validate_registration"

  setup do
    tenants = PlatformFx.three_tenants!()
    PlatformFx.pin!(tenants.p.tenant_id)
    prefix = tenants.p.schema_name

    admin = Fx.user!(prefix, "admin")
    Fx.platform_admin!(prefix, admin)

    %{platform: tenants.p, company: tenants.a, prefix: prefix, admin: admin}
  end

  defp call do
    Fx.call(@function, %{
      "slug" => %{"var" => "slug"},
      "display_name" => %{"const" => "Acme Ltd"},
      "email" => %{"const" => "admin@acme.test"}
    })
  end

  defp activated(ctx) do
    draft =
      Fx.definition!(ctx.prefix, Fx.graph(call()), "t2703-#{System.unique_integer([:positive])}")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id, prefix: ctx.prefix, activator: activator)

    draft
  end

  defp start(ctx, definition, slug) do
    Engine.create(
      %{
        definition_name: definition.name,
        initial_variables: %{"slug" => slug},
        actor_id: ctx.admin.id,
        idempotency_key: "t2703-#{Ecto.UUID.generate()}"
      },
      prefix: ctx.prefix,
      auth_context: %{
        user_id: ctx.admin.id,
        tenant_id: ctx.platform.tenant_id,
        roles: ["PLATFORM_ADMIN"]
      }
    )
  end

  defp projection(ctx, instance_id),
    do: Repo.get_by!(InstanceProjection, [instance_id: instance_id], prefix: ctx.prefix)

  defp rows(ctx, instance_id),
    do:
      Repo.all(from(d in StepDispatch, where: d.instance_id == ^instance_id), prefix: ctx.prefix)

  defp event_count(ctx, instance_id, type) do
    Repo.aggregate(
      from(e in Event, where: e.instance_id == ^instance_id and e.event_type == ^type),
      :count,
      prefix: ctx.prefix
    )
  end

  # The activator's platform role binding (a group membership) is removed, and put back later.
  defp lose_permission(ctx) do
    members =
      Repo.all(from(gm in GroupMember, where: gm.user_id == ^ctx.admin.id), prefix: ctx.prefix)

    Fx.revoke_platform_roles!(ctx.prefix, ctx.admin)
    members
  end

  defp restore_permission(ctx, members) do
    for gm <- members do
      %GroupMember{}
      |> Ecto.Changeset.change(%{group_id: gm.group_id, user_id: gm.user_id})
      |> Repo.insert!(prefix: ctx.prefix)
    end
  end

  # ── R1, R2 ────────────────────────────────────────────────────────────────

  test "R1/R2: the definition starts, waits on the node, runs and completes", ctx do
    definition = activated(ctx)

    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme")

    # R2: the engine armed ONE row and parked the instance on the node; nothing ran yet.
    assert [%StepDispatch{status: :pending, node_id: "call", function_name: @function} = row] =
             rows(ctx, instance_id)

    assert row.inputs["slug"] == "acme"
    assert %{status: :active, current_nodes: ["call"]} = projection(ctx, instance_id)

    # R1: one cycle runs it and the instance continues to the END.
    assert %{claimed: 1, advanced: 1, failed: 0, applied: 1} =
             PlatformStepRunner.run_due(ctx.prefix)

    assert [%StepDispatch{status: :advanced}] = rows(ctx, instance_id)
    done = projection(ctx, instance_id)
    assert done.status == :completed
    assert done.variables["normalized_slug"] == "acme"
    assert done.variables["email_domain"] == "acme.test"
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1

    # A second cycle finds nothing to do and moves nothing.
    assert %{claimed: 0, applied: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  # ── R3, R4 ────────────────────────────────────────────────────────────────

  test "R3/R4: a refused step is ERROR with a DLQ entry; the retry resumes exactly once", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-retry")

    # The activator lost its permission since the activation: the fence refuses at the attempt.
    lost = lose_permission(ctx)

    assert %{claimed: 1, advanced: 0, failed: 1} = PlatformStepRunner.run_due(ctx.prefix)

    errored = projection(ctx, instance_id)
    assert errored.status == :error
    assert errored.error_detail["error_type"] == "platform_step_failed"
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1
    assert [%StepDispatch{status: :given_up, last_failure_kind: kind}] = rows(ctx, instance_id)
    assert is_binary(kind)

    # The DLQ entry carries the type G7's retry listens to and names the node.
    {:ok, %{items: entries}} =
      Dlq.list(%{instance_id: instance_id, cursor: nil, page_size: 20}, prefix: ctx.prefix)

    assert [entry] =
             Enum.filter(entries, &(&1.entry_type == StepRetry.platform_step_entry_type()))

    assert entry.reference_id == "call"
    assert entry.instance_id == instance_id

    # No personal datum of the call is in the EXECUTION_ERROR event.
    error_event =
      Repo.one!(
        from(e in Event,
          where: e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR"
        ),
        prefix: ctx.prefix
      )

    refute inspect(error_event.payload) =~ "admin@acme.test"

    # While the permission is still lost the retry is refused again and the instance stays ERROR.
    assert {:error, _reason} = StepRetry.retry_step(instance_id, prefix: ctx.prefix)
    assert projection(ctx, instance_id).status == :error

    # The permission is back: the retry runs the step and RESUMES the instance, once.
    restore_permission(ctx, lost)
    assert {:ok, %{status: "advanced"}} = StepRetry.retry_step(instance_id, prefix: ctx.prefix)

    resumed = projection(ctx, instance_id)
    assert resumed.status == :completed
    assert resumed.error_detail == nil
    assert resumed.variables["normalized_slug"] == "acme-retry"
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1

    # A second retry (the DLQ entry's own, or the instance's) finds the work done and moves
    # nothing: no failed step is left, and the entry's retry answers `already_final`.
    assert {:error, :step_not_found} = StepRetry.retry_step(instance_id, prefix: ctx.prefix)

    assert {:ok, %{status: "already_final"}} =
             StepRetry.retry_entry(entry, prefix: ctx.prefix)

    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  # ── R5 ────────────────────────────────────────────────────────────────────

  test "R5: a crash after the claim is taken over once the lease expired, not before", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-lease")
    [row] = rows(ctx, instance_id)

    # The run that held the row died: it is `running` and its lease is still in the future.
    future = DateTime.add(DateTime.utc_now(), 600, :second)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^row.id),
      [set: [status: :running, attempt_index: 1, next_attempt_at: future]],
      prefix: ctx.prefix
    )

    # A live lease is a body in flight: nothing is due, nothing runs a second time.
    assert %{claimed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert projection(ctx, instance_id).status == :active

    # The lease expires: the next cycle takes the row over, runs it and resumes the instance.
    past = DateTime.add(DateTime.utc_now(), -5, :second)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^row.id),
      [set: [next_attempt_at: past]],
      prefix: ctx.prefix
    )

    assert %{claimed: 1, advanced: 1, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert projection(ctx, instance_id).status == :completed
    assert [%StepDispatch{status: :advanced, attempt_index: 2}] = rows(ctx, instance_id)
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  test "R5: a result written but never applied is applied by the sweep, once", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-sweep")
    [row] = rows(ctx, instance_id)

    # The dispatcher committed its result, the engine's apply never ran (a crash between them).
    assert {:ok, {:advanced, _outputs}} =
             Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(row.id, ctx.prefix)

    assert projection(ctx, instance_id).status == :active

    assert %{applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert projection(ctx, instance_id).status == :completed
    assert %{applied: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  # ── R6 ────────────────────────────────────────────────────────────────────

  test "R6: a company tenant's schema never runs and cannot hold a call", ctx do
    assert {:error, :not_platform_tenant} = PlatformStepRunner.run_due(ctx.company.schema_name)

    # A company tenant may not carry a platform call at all (decision 0094): the definition is
    # refused with the ONE fixed code, so there is no company-tenant call to run.
    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_not_allowed}]}} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "t2703-co-#{System.unique_integer([:positive])}",
                 version: "1",
                 graph: Fx.graph(call()),
                 created_by: Ecto.UUID.generate()
               },
               [],
               prefix: ctx.company.schema_name
             )

    # An unlisted function has no row: the dispatcher refuses it at the arming.
    assert {:error, :platform_function_unknown} =
             Letflow.PlatformFunctions.Dispatcher.arm(
               prefix: ctx.prefix,
               instance_id: Ecto.UUID.generate(),
               definition_id: Ecto.UUID.generate(),
               node_id: "call",
               function: "tenant.drop_everything",
               inputs: %{}
             )
  end

  # ── R7 ────────────────────────────────────────────────────────────────────

  test "R7: the call of ANOTHER instance is never resumed by this one", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: first}} = start(ctx, definition, "acme-twice")

    # The same slug is the same call (the key): the first instance owns the row, the second start
    # is refused and writes nothing.
    assert {:error, _reason} = start(ctx, definition, "acme-twice")
    assert [%StepDispatch{instance_id: ^first}] = Repo.all(StepDispatch, prefix: ctx.prefix)
  end

  # ── R8 ────────────────────────────────────────────────────────────────────

  test "R8: the config parse knows the platform route and refuses a second route" do
    node = fn attrs ->
      %Letflow.Definitions.Graph.Node{id: "call", node_type: :SERVICE_TASK, attributes: attrs}
    end

    assert {:ok,
            %ServiceTask.Config{route_kind: :platform_call, platform_call: %{"function" => "f"}}} =
             ServiceTask.parse_config_from_node_attributes(
               node.(%{"platform_call" => %{"function" => "f"}})
             )

    assert {:error, :conflicting_routes} =
             ServiceTask.parse_config_from_node_attributes(
               node.(%{"platform_call" => %{"function" => "f"}, "endpoint" => "http://x"})
             )

    # Entity or module lines are a second route too: refused at entry, before anything is armed.
    for key <- ["entity_writes", "module_writes"] do
      assert {:error, :conflicting_routes} =
               ServiceTask.parse_config_from_node_attributes(
                 node.(%{"platform_call" => %{"function" => "f"}, key => [%{}]})
               )
    end
  end

  # ── R9 ────────────────────────────────────────────────────────────────────

  test "R9: a given_up row whose landing never ran is landed by the sweep, once", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-landing")
    [row] = rows(ctx, instance_id)

    lose_permission(ctx)

    # The dispatcher gave the row up and committed; the engine's landing never ran (a death
    # between the two commits).
    assert {:error, _reason} =
             Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(row.id, ctx.prefix)

    assert [%StepDispatch{status: :given_up}] = rows(ctx, instance_id)
    assert projection(ctx, instance_id).status == :active
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 0

    assert %{failed: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert projection(ctx, instance_id).status == :error
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1

    # A second cycle moves nothing: one event, one DLQ entry.
    assert %{failed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1
  end

  # ── R10 ───────────────────────────────────────────────────────────────────

  test "R10: a platform_call node that declares entity lines is refused at activation", ctx do
    Letflow.EntityWritesFixture.define_type!(ctx.prefix, "stock_move", %{})
    lines = [Letflow.EntityWritesFixture.line("stock_move", %{"label" => %{"const" => "x"}})]

    draft =
      Fx.definition!(
        ctx.prefix,
        Fx.graph(call(), %{"entity_writes" => lines}),
        "t2703-lines-#{System.unique_integer([:positive])}"
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    # Refused at activation: the platform route plans no lines, so the function never runs.
    assert {:error, {:platform_calls_invalid, [violation]}} =
             Definitions.activate(draft.id, prefix: ctx.prefix, activator: activator)

    assert %{code: :conflicting_platform_call_routes} = violation
  end

  # ── R12 ───────────────────────────────────────────────────────────────────

  test "R12: a result older than a day is still applied and a given_up row still landed", ctx do
    old = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)

    definition = activated(ctx)
    assert {:ok, %{instance_id: applied_id}} = start(ctx, definition, "acme-old-applied")
    [row] = rows(ctx, applied_id)

    assert {:ok, {:advanced, _outputs}} =
             Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(row.id, ctx.prefix)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^row.id),
      [set: [dispatched_at: old]],
      prefix: ctx.prefix
    )

    assert %{applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert projection(ctx, applied_id).status == :completed

    assert {:ok, %{instance_id: given_up_id}} = start(ctx, definition, "acme-old-given-up")
    [row2] = rows(ctx, given_up_id)
    lose_permission(ctx)

    assert {:error, _reason} =
             Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(row2.id, ctx.prefix)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^row2.id),
      [set: [dispatched_at: old]],
      prefix: ctx.prefix
    )

    assert %{failed: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert projection(ctx, given_up_id).status == :error
  end

  # ── R11 ───────────────────────────────────────────────────────────────────

  test "R11: a loop that passes the platform_call node twice completes", ctx do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"platform_call" => call()}
        },
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "ht"},
        %{"id" => "e3", "source" => "ht", "target" => "xg"},
        %{
          "id" => "e4",
          "source" => "xg",
          "target" => "call",
          "condition" => "variables.again == true"
        },
        %{"id" => "e5", "source" => "xg", "target" => "end", "is_default" => true}
      ]
    }

    step = call()

    schemas =
      (Map.to_list(step["reads"]) ++ Map.to_list(step["writes"]) ++ [{"again", "boolean"}])
      |> Enum.map(fn {key, type} -> %{variable_key: key, json_schema: %{"type" => type}} end)

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph,
        "t2703-loop-#{System.unique_integer([:positive])}",
        schemas
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id, prefix: ctx.prefix, activator: activator)

    assert {:ok, %{instance_id: instance_id}} = start(ctx, draft, "acme-loop")

    complete_task = fn again ->
      task =
        Repo.one!(
          from(t in Letflow.Engine.Task,
            where: t.instance_id == ^instance_id and t.status == :pending
          ),
          prefix: ctx.prefix
        )

      assert {:ok, _result} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{"again" => again},
                   actor_id: ctx.admin.id,
                   idempotency_key: "t2703-loop-#{Ecto.UUID.generate()}"
                 },
                 prefix: ctx.prefix
               )
    end

    # first visit
    assert %{advanced: 1, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert %{current_nodes: ["ht"]} = projection(ctx, instance_id)
    complete_task.(true)

    # second visit: a row of its own, parked on the node, then run and applied
    assert %{current_nodes: ["call"], status: :active} = projection(ctx, instance_id)
    assert length(rows(ctx, instance_id)) == 2
    assert %{claimed: 1, advanced: 1, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert %{current_nodes: ["ht"]} = projection(ctx, instance_id)
    complete_task.(false)

    assert projection(ctx, instance_id).status == :completed
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 2
  end

  # ── R13 ───────────────────────────────────────────────────────────────────

  # The instance's pinned graph gains entity lines on the call node AFTER the arm: the shape of a
  # graph that was activated before the activation fence refused such a node.
  defp add_lines_to_pinned_graph(ctx, instance_id) do
    snapshot =
      Repo.get!(Letflow.Definitions.InstanceDefinitionSnapshot, instance_id, prefix: ctx.prefix)

    nodes =
      Enum.map(snapshot.graph["nodes"], fn
        %{"id" => "call"} = node ->
          put_in(node, ["attributes", "entity_writes"], [%{"type" => "stock_move"}])

        node ->
          node
      end)

    snapshot
    |> Ecto.Changeset.change(graph: Map.put(snapshot.graph, "nodes", nodes))
    |> Repo.update!(prefix: ctx.prefix)
  end

  test "R13: an apply refusal is landed as a recoverable failure, never a parked instance", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-refused")
    add_lines_to_pinned_graph(ctx, instance_id)

    assert %{claimed: 1, advanced: 1, applied: 0, failed: 1} =
             PlatformStepRunner.run_due(ctx.prefix)

    errored = projection(ctx, instance_id)
    assert errored.status == :error
    assert errored.error_detail["error_type"] == "platform_step_failed"
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 0

    error_event =
      Repo.one!(
        from(e in Event,
          where: e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR"
        ),
        prefix: ctx.prefix
      )

    assert inspect(error_event.payload) =~ "apply_refused"
    assert inspect(error_event.payload) =~ "lines_not_planned"
    refute inspect(error_event.payload) =~ "admin@acme.test"

    {:ok, %{items: entries}} =
      Dlq.list(%{instance_id: instance_id, cursor: nil, page_size: 20}, prefix: ctx.prefix)

    assert [entry] =
             Enum.filter(entries, &(&1.entry_type == StepRetry.platform_step_entry_type()))

    assert entry.reference_id == "call"

    # Landed: the next cycles read nothing, and nothing lands twice.
    assert %{claimed: 0, applied: 0, failed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1

    # The retry finds the step done (it never runs the function again), the apply is refused
    # again with a typed code, and the instance stays in ERROR.
    [%StepDispatch{attempt_index: attempts}] = rows(ctx, instance_id)
    assert {:error, code} = StepRetry.retry_entry(entry, prefix: ctx.prefix)
    assert is_atom(code)
    assert [%StepDispatch{status: :advanced, attempt_index: ^attempts}] = rows(ctx, instance_id)
    assert projection(ctx, instance_id).status == :error
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 0

    # The landing itself is idempotent.
    [row] = rows(ctx, instance_id)

    assert {:ok, :error_set} =
             Engine.fail_platform_step_apply(row.id, ctx.prefix, {:entity_write_failed, 0, :x})

    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1
  end

  test "R13: a fault is not a refusal: the closed classification of the apply answers" do
    for reason <- [
          :platform_step_apply_failed,
          :platform_step_not_found,
          :instance_not_found,
          {:instance_not_active, :cancelled},
          {:unknown_token_id, "call"}
        ] do
      assert Engine.platform_apply_refusal(reason) == :skip
    end

    assert {:land, "lines_not_planned"} =
             Engine.platform_apply_refusal({:entity_write_failed, 0, :not_planned})

    assert {:land, "transition_failed"} =
             Engine.platform_apply_refusal({:transition_failed, {:any, "term"}})

    # A term never becomes the code (INV-4).
    assert {:land, "apply_refused"} = Engine.platform_apply_refusal({:other, "admin@acme.test"})
  end

  test "R13: an outstanding row of a cancelled instance is left alone", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-cancelled")
    [row] = rows(ctx, instance_id)

    assert {:ok, {:advanced, _outputs}} =
             Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(row.id, ctx.prefix)

    assert {:ok, _cancelled} =
             Engine.cancel_instance(
               instance_id,
               %{actor_id: ctx.admin.id, idempotency_key: "t2703-cancel-#{row.id}"},
               prefix: ctx.prefix
             )

    assert %{applied: 0, failed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert projection(ctx, instance_id).status == :cancelled
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 0
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 0
  end

  test "R13: the sweep pages past its limit, oldest first", ctx do
    definition = activated(ctx)

    ids =
      for n <- 1..3 do
        assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-page-#{n}")
        [row] = rows(ctx, instance_id)

        assert {:ok, {:advanced, _outputs}} =
                 Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(row.id, ctx.prefix)

        instance_id
      end

    # A limit of one row per page: the three outstanding rows are reached in one cycle.
    assert %{applied: 3} = PlatformStepRunner.run_due(ctx.prefix, 1)
    for id <- ids, do: assert(projection(ctx, id).status == :completed)
  end

  # ── R14 ───────────────────────────────────────────────────────────────────

  # The engine's own arming entry point, called again for the node the instance waits on: the
  # shape of a replayed engine transaction or a double entry of the same visit.
  defp arm_again(ctx, row) do
    Engine.arm_platform_step(
      Repo,
      %{instance_id: row.instance_id, function: row.function_name, inputs: row.inputs},
      row.node_id,
      ctx.prefix
    )
  end

  # The function's executions: every claim of a row is one run of the function (`attempt_index`).
  defp executions(ctx, instance_id),
    do: rows(ctx, instance_id) |> Enum.map(& &1.attempt_index) |> Enum.sum()

  test "R14: a duplicate arm of the same visit is the same row in every state, run once", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-dup")
    [%StepDispatch{id: id} = row] = rows(ctx, instance_id)

    # pending: N arms, also from two processes at once.
    for _ <- 1..3, do: assert({:ok, %StepDispatch{id: ^id}} = arm_again(ctx, row))

    for {:ok, armed} <-
          Task.await_many(for(_ <- 1..2, do: Task.async(fn -> arm_again(ctx, row) end))),
        do: assert(armed.id == id)

    assert [%StepDispatch{id: ^id, status: :pending}] = rows(ctx, instance_id)

    # running (a claim whose run is in flight): the same row, nothing new is due.
    future = DateTime.add(DateTime.utc_now(), 600, :second)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^id),
      [set: [status: :running, attempt_index: 1, next_attempt_at: future]],
      prefix: ctx.prefix
    )

    assert {:ok, %StepDispatch{id: ^id}} = arm_again(ctx, row)
    assert %{claimed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert length(rows(ctx, instance_id)) == 1

    # advanced but not yet applied: the same row; the sweep applies it once.
    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^id),
      [set: [status: :pending, attempt_index: 0, next_attempt_at: DateTime.utc_now()]],
      prefix: ctx.prefix
    )

    assert {:ok, {:advanced, _outputs}} =
             Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(id, ctx.prefix)

    assert {:ok, %StepDispatch{id: ^id, status: :advanced}} = arm_again(ctx, row)

    for {:ok, armed} <-
          Task.await_many(for(_ <- 1..2, do: Task.async(fn -> arm_again(ctx, row) end))),
        do: assert(armed.id == id)

    assert %{claimed: 0, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert [%StepDispatch{id: ^id}] = rows(ctx, instance_id)
    assert executions(ctx, instance_id) == 1
    assert projection(ctx, instance_id).status == :completed
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  test "R14: a duplicate arm of a given_up row is the same row; nothing runs again", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-dup-failed")
    [%StepDispatch{id: id} = row] = rows(ctx, instance_id)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^id),
      [set: [status: :given_up, attempt_index: 1, last_failure_kind: "function_error"]],
      prefix: ctx.prefix
    )

    for _ <- 1..2, do: assert({:ok, %StepDispatch{id: ^id}} = arm_again(ctx, row))

    assert %{claimed: 0, failed: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert [%StepDispatch{id: ^id, status: :given_up}] = rows(ctx, instance_id)
    assert executions(ctx, instance_id) == 1
    assert projection(ctx, instance_id).status == :error
  end

  test "R14: only an applied visit makes the next arm a new visit", ctx do
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-visit")
    [%StepDispatch{id: id} = row] = rows(ctx, instance_id)

    assert %{applied: 1} = PlatformStepRunner.run_due(ctx.prefix)

    # The first visit was applied: an arrival at the node now is a genuine loop-back, a new call.
    assert {:ok, %StepDispatch{id: second}} = arm_again(ctx, row)
    refute second == id
    assert {:ok, %StepDispatch{id: ^second}} = arm_again(ctx, row)
    assert length(rows(ctx, instance_id)) == 2
  end

  # ── R15 ───────────────────────────────────────────────────────────────────

  defp no_edge_graph(default?) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"platform_call" => call()}
        },
        %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" =>
        [
          %{"id" => "e1", "source" => "start", "target" => "call"},
          %{"id" => "e2", "source" => "call", "target" => "xg"},
          %{
            "id" => "e3",
            "source" => "xg",
            "target" => "end",
            "condition" => "variables.normalized_slug == \"never\""
          }
        ] ++
          if(default?,
            do: [%{"id" => "e4", "source" => "xg", "target" => "end", "is_default" => true}],
            else: []
          )
    }
  end

  defp put_pinned_graph(ctx, instance_id, graph) do
    Letflow.Definitions.InstanceDefinitionSnapshot
    |> Repo.get!(instance_id, prefix: ctx.prefix)
    |> Ecto.Changeset.change(graph: graph)
    |> Repo.update!(prefix: ctx.prefix)
  end

  test "R15: no matching edge after the step is the platform failure; the retry resumes", ctx do
    step = call()

    schemas =
      (Map.to_list(step["reads"]) ++ Map.to_list(step["writes"]))
      |> Enum.map(fn {key, type} -> %{variable_key: key, json_schema: %{"type" => type}} end)

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        no_edge_graph(true),
        "t2703-noedge-#{System.unique_integer([:positive])}",
        schemas
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, _} = Definitions.activate(draft.id, prefix: ctx.prefix, activator: activator)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, draft, "acme-noedge")

    # Activation refuses a gateway without a default edge (`:no_default_route`), so the pinned
    # graph loses it after the start: the shape of a graph activated before that rule, and the
    # path `Transition` still answers `:no_matching_edge` on.
    put_pinned_graph(ctx, instance_id, no_edge_graph(false))

    assert %{claimed: 1, advanced: 1, applied: 0, failed: 1} =
             PlatformStepRunner.run_due(ctx.prefix)

    errored = projection(ctx, instance_id)
    assert errored.status == :error
    assert errored.error_detail["error_type"] == "platform_step_failed"
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1
    # The apply rolled back: no completion recorded, so the retry is not answered `already_final`.
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 0

    error_event =
      Repo.one!(
        from(e in Event,
          where: e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR"
        ),
        prefix: ctx.prefix
      )

    assert inspect(error_event.payload) =~ "no_matching_edge"
    refute inspect(error_event.payload) =~ "admin@acme.test"

    {:ok, %{items: entries}} =
      Dlq.list(%{instance_id: instance_id, cursor: nil, page_size: 20}, prefix: ctx.prefix)

    # Exactly one DLQ entry, of the platform step's type (never the ordinary "event" type).
    assert [entry] = entries
    assert entry.entry_type == StepRetry.platform_step_entry_type()
    assert entry.reference_id == "call"

    # The operator repairs the graph (a default edge); the G7 retry resumes the instance once,
    # without running the function again.
    put_pinned_graph(ctx, instance_id, no_edge_graph(true))

    assert {:ok, %{kind: :platform}} = StepRetry.retry_entry(entry, prefix: ctx.prefix)
    assert projection(ctx, instance_id).status == :completed
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
    assert executions(ctx, instance_id) == 1

    assert {:ok, %{status: "already_final"}} = StepRetry.retry_entry(entry, prefix: ctx.prefix)
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end
end
