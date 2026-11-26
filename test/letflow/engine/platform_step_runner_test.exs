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
  | R14 | a duplicate arm of the SAME visit (row pending / running / advanced-not-applied / given_up; sequential, and two processes at once, each in its own transaction on its own connection) is the same row and the function body runs once (its calls are traced, not inferred from `attempt_index`); the visit counts APPLIED visits, not rows |
  | R15 | a result whose hop chain has no matching edge is landed as the PLATFORM failure (platform_step DLQ entry), and the G7 retry resumes it |
  | R16 | the cancel of an instance closes its pending and running calls; the claim refuses a call whose instance has ended (also a manual retry): the function never runs |
  | R17 | a loop straight back to the node (call -> gateway -> call, inside one apply) arms a NEW visit each cycle, and each visit runs once |

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

  @function_body {Letflow.PlatformFunctions.Impl.ValidateRegistration, :run, 1}

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

  # The REAL runs of the function body: every call of it, in any process (the test process too),
  # is traced to a counting process (the product has no counter). Calls made for other instances
  # are not counted for this one.
  defp trace_function_runs do
    {module, _function, _arity} = @function_body
    # A pattern set on a module that is not loaded yet matches nothing (0): load it first.
    Code.ensure_loaded!(module)
    counter = spawn_link(fn -> count_runs(%{}) end)
    Process.put(:function_run_counter, counter)
    assert :erlang.trace_pattern(@function_body, true, [:global]) == 1
    :erlang.trace(:all, true, [:call, {:tracer, counter}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern(@function_body, false, [:global])
    end)
  end

  defp count_runs(counts) do
    receive do
      {:trace, _pid, :call, {_mod, :run, [%{dispatch: %{instance_id: id}}]}} ->
        count_runs(Map.update(counts, id, 1, &(&1 + 1)))

      {:count, from, id} ->
        send(from, {:runs, id, Map.get(counts, id, 0)})
        count_runs(counts)

      _other ->
        count_runs(counts)
    end
  end

  # How many times the body ran for this instance since the trace started. `trace_delivered`
  # first: every trace message generated so far is in the counter's mailbox before it is asked.
  defp function_runs(instance_id) do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5_000 -> flunk("the call trace was not delivered")
    end

    send(Process.get(:function_run_counter), {:count, self(), instance_id})

    receive do
      {:runs, ^instance_id, n} -> n
    after
      5_000 -> flunk("the run counter did not answer")
    end
  end

  # Two arms of the same visit from two processes, each in its OWN transaction on its OWN
  # connection (the fixtures run the sandbox in `:auto` mode; the backend pids are asserted to
  # differ). Both transactions are open before either arms; neither commits before one of them
  # has armed, so the two arms overlap (a second INSERT waits on the first one's row lock).
  defp concurrent_arms(ctx, row) do
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Repo.transaction(fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:in_tx, self(), backend})
            receive do: (:go -> :ok)
            armed = arm_again(ctx, row)
            send(parent, {:armed, self()})
            receive do: (:commit -> :ok)
            armed
          end)
        end)
      end

    backends =
      for _ <- tasks do
        receive do
          {:in_tx, _pid, backend} -> backend
        after
          5_000 -> flunk("a concurrent arm never opened its transaction")
        end
      end

    assert length(Enum.uniq(backends)) == 2

    for task <- tasks, do: send(task.pid, :go)

    receive do
      {:armed, _pid} -> :ok
    after
      5_000 -> flunk("no concurrent arm finished")
    end

    for task <- tasks, do: send(task.pid, :commit)

    for {:ok, armed} <- Task.await_many(tasks, 10_000), do: armed
  end

  defp assert_one_row(ctx, instance_id, id, results) do
    for result <- results, do: assert({:ok, %StepDispatch{id: ^id}} = result)
    assert [%StepDispatch{id: ^id}] = rows(ctx, instance_id)
  end

  test "R14a: duplicate arms of a PENDING visit: one row, the function runs once", ctx do
    trace_function_runs()
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-dup-pending")
    [%StepDispatch{id: id, status: :pending} = row] = rows(ctx, instance_id)

    assert_one_row(ctx, instance_id, id, for(_ <- 1..3, do: arm_again(ctx, row)))
    assert_one_row(ctx, instance_id, id, concurrent_arms(ctx, row))
    assert function_runs(instance_id) == 0

    assert %{claimed: 1, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert %{claimed: 0, applied: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 1
    assert projection(ctx, instance_id).status == :completed
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  test "R14b: duplicate arms of a RUNNING visit: one row, the function runs once", ctx do
    trace_function_runs()
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-dup-running")
    [%StepDispatch{id: id} = row] = rows(ctx, instance_id)

    # A claim whose run is in flight: `running` with a live lease.
    future = DateTime.add(DateTime.utc_now(), 600, :second)

    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^id),
      [set: [status: :running, attempt_index: 1, next_attempt_at: future]],
      prefix: ctx.prefix
    )

    assert_one_row(ctx, instance_id, id, [arm_again(ctx, row)])
    assert_one_row(ctx, instance_id, id, concurrent_arms(ctx, row))
    assert %{claimed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 0

    # The in-flight claim died: after its lease the row is taken over and runs once.
    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^id),
      [set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)]],
      prefix: ctx.prefix
    )

    assert %{claimed: 1, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert [%StepDispatch{id: ^id}] = rows(ctx, instance_id)
    assert function_runs(instance_id) == 1
    assert projection(ctx, instance_id).status == :completed
  end

  test "R14c: duplicate arms of an ADVANCED, not applied visit: no second run", ctx do
    trace_function_runs()
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-dup-advanced")
    [%StepDispatch{id: id} = row] = rows(ctx, instance_id)

    # The result committed; the apply never ran (a death between the two transactions).
    assert {:ok, {:advanced, _outputs}} =
             Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(id, ctx.prefix)

    assert function_runs(instance_id) == 1

    assert_one_row(ctx, instance_id, id, [arm_again(ctx, row)])
    assert_one_row(ctx, instance_id, id, concurrent_arms(ctx, row))
    assert [%StepDispatch{status: :advanced}] = rows(ctx, instance_id)

    assert %{claimed: 0, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 1
    assert projection(ctx, instance_id).status == :completed
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  test "R14d: duplicate arms of a FAILED (given_up) visit: no second run", ctx do
    trace_function_runs()
    definition = activated(ctx)
    # A slug the function refuses: a real function error, the row is given up.
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "X")
    [%StepDispatch{id: id} = row] = rows(ctx, instance_id)

    assert %{claimed: 1, failed: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert [%StepDispatch{id: ^id, status: :given_up}] = rows(ctx, instance_id)
    assert function_runs(instance_id) == 1

    assert_one_row(ctx, instance_id, id, [arm_again(ctx, row)])
    assert_one_row(ctx, instance_id, id, concurrent_arms(ctx, row))
    assert [%StepDispatch{status: :given_up}] = rows(ctx, instance_id)

    assert %{claimed: 0, failed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 1
    assert projection(ctx, instance_id).status == :error
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 1
  end

  test "R14e: only an applied visit makes the next arm a new visit", ctx do
    trace_function_runs()
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-visit")
    [%StepDispatch{id: id} = row] = rows(ctx, instance_id)

    assert %{applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 1

    # The first visit was applied: an arrival at the node now is a genuine loop-back, a new call.
    # Its FIRST arm comes from two processes at once (the real INSERT race on the new call_key):
    # one new row; arming that visit again keeps it.
    assert [{:ok, %StepDispatch{id: second}}, {:ok, %StepDispatch{id: second}}] =
             concurrent_arms(ctx, row)

    refute second == id
    assert {:ok, %StepDispatch{id: ^second}} = arm_again(ctx, row)
    assert length(rows(ctx, instance_id)) == 2

    # This instance COMPLETED with its first visit (call -> end): the arm above is the bare engine
    # entry point, so the claim fence (R16c) closes the new row instead of running it. The run of
    # a genuine loop-back visit is R11 (through a task) and R17 (straight back, in one apply).
    assert %{claimed: 1, advanced: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 1

    assert %StepDispatch{status: :given_up, last_failure_kind: "platform_step_instance_cancelled"} =
             Repo.get!(StepDispatch, second, prefix: ctx.prefix)
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
    trace_function_runs()
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
    assert function_runs(instance_id) == 1

    assert {:ok, %{status: "already_final"}} = StepRetry.retry_entry(entry, prefix: ctx.prefix)
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 1
  end

  # ── R16: the cancel of an instance stops its queued calls ────────────────

  defp cancel!(ctx, instance_id) do
    assert {:ok, _cancelled} =
             Engine.cancel_instance(
               instance_id,
               %{actor_id: ctx.admin.id, idempotency_key: "t2703-cancel-#{Ecto.UUID.generate()}"},
               prefix: ctx.prefix
             )
  end

  test "R16a: a call still PENDING when the instance is cancelled never runs", ctx do
    trace_function_runs()
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-cancel-pending")
    [%StepDispatch{id: id, status: :pending}] = rows(ctx, instance_id)

    cancel!(ctx, instance_id)

    assert [%StepDispatch{id: ^id, status: :given_up} = row] = rows(ctx, instance_id)
    assert row.last_failure_kind == "platform_step_instance_cancelled"
    assert %{claimed: 0, applied: 0, failed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 0
    assert projection(ctx, instance_id).status == :cancelled
    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 0
    assert event_count(ctx, instance_id, "EXECUTION_ERROR") == 0
  end

  test "R16b: an expired RUNNING claim of a cancelled instance is not taken over", ctx do
    trace_function_runs()
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-cancel-running")
    [%StepDispatch{id: id}] = rows(ctx, instance_id)

    # A claim that died: `running` with a lease that has expired (the takeover shape of R5).
    Repo.update_all(
      from(d in StepDispatch, where: d.id == ^id),
      [
        set: [
          status: :running,
          attempt_index: 1,
          next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
        ]
      ],
      prefix: ctx.prefix
    )

    cancel!(ctx, instance_id)

    assert [
             %StepDispatch{
               status: :given_up,
               last_failure_kind: "platform_step_instance_cancelled"
             }
           ] =
             rows(ctx, instance_id)

    assert %{claimed: 0, applied: 0, failed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 0
    assert projection(ctx, instance_id).status == :cancelled
  end

  test "R16c: the claim refuses a call whose instance has ended, whatever the row says", ctx do
    trace_function_runs()
    definition = activated(ctx)
    assert {:ok, %{instance_id: instance_id}} = start(ctx, definition, "acme-cancel-fence")
    [%StepDispatch{id: id}] = rows(ctx, instance_id)
    cancel!(ctx, instance_id)

    # A row that reaches a claim anyway (missed by the cancel, or re-armed by a retry): due again,
    # once pending and once as an expired running claim.
    for status <- [:pending, :running] do
      Repo.update_all(
        from(d in StepDispatch, where: d.id == ^id),
        [
          set: [
            status: status,
            last_failure_kind: nil,
            next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
          ]
        ],
        prefix: ctx.prefix
      )

      assert {:error, :platform_step_instance_cancelled} =
               Letflow.PlatformFunctions.Dispatcher.attempt_dispatch(id, ctx.prefix)

      assert [%StepDispatch{status: :given_up} = row] = rows(ctx, instance_id)
      assert row.last_failure_kind == "platform_step_instance_cancelled"
    end

    # The DLQ-style manual retry of the closed row is refused the same way.
    assert {:error, :platform_step_instance_cancelled} =
             Letflow.PlatformFunctions.Dispatcher.retry_failed_step(id, ctx.prefix)

    assert function_runs(instance_id) == 0
  end

  # ── R17: a loop straight back to the node, inside one apply ──────────────

  test "R17: call -> gateway -> the same call: each cycle is a new visit and a new run", ctx do
    trace_function_runs()

    graph = %{
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
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "xg"},
        %{
          "id" => "e3",
          "source" => "xg",
          "target" => "call",
          "condition" => "variables.normalized_slug == \"acme-gw\""
        },
        %{"id" => "e4", "source" => "xg", "target" => "end", "is_default" => true}
      ]
    }

    step = call()

    schemas =
      (Map.to_list(step["reads"]) ++ Map.to_list(step["writes"]))
      |> Enum.map(fn {key, type} -> %{variable_key: key, json_schema: %{"type" => type}} end)

    draft =
      Fx.definition_with_schemas!(
        ctx.prefix,
        graph,
        "t2703-gw-#{System.unique_integer([:positive])}",
        schemas
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id, prefix: ctx.prefix, activator: activator)

    assert {:ok, %{instance_id: instance_id}} = start(ctx, draft, "acme-gw")

    # Each cycle applies the current visit; the apply's hop chain goes straight back to the node
    # IN THE SAME TRANSACTION and arms the NEXT visit: a new row, pending, run by the next cycle.
    for cycle <- 1..2 do
      assert %{claimed: 1, advanced: 1, applied: 1} = PlatformStepRunner.run_due(ctx.prefix)
      assert function_runs(instance_id) == cycle
      assert %{current_nodes: ["call"], status: :active} = projection(ctx, instance_id)

      dispatches = rows(ctx, instance_id)
      assert length(dispatches) == cycle + 1
      assert Enum.count(dispatches, &(&1.status == :pending)) == 1
      assert Enum.count(dispatches, &(&1.status == :advanced)) == cycle
    end

    assert event_count(ctx, instance_id, "SERVICE_TASK_COMPLETED") == 2

    # The loop ends with the cancel (R16): its open visit never runs.
    cancel!(ctx, instance_id)
    assert %{claimed: 0} = PlatformStepRunner.run_due(ctx.prefix)
    assert function_runs(instance_id) == 2
  end
end
