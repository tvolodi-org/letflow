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
  end
end
