defmodule Letflow.PlatformFunctions.DispatcherRetryTest do
  @moduledoc """
  The MANUAL retry of a platform step (pilot gap G7, T-2603 -- the "Register a
  tenant" pilot, owner item 7: "step failures visible and retryable").

  What the tests prove:

    * the manual retry is NOT stopped by the ATTEMPT CAP: the cap bounds how
      often the lease of a CRASHED run may be taken over, and an operator who
      asks for one more try gets exactly ONE attempt -- the attempt count
      keeps growing, so the step log shows the whole history of the step;
    * the LEASE still stops it: a row whose lease has NOT expired is a body in
      flight, and the retry is refused with `platform_step_in_flight` (the body
      does not run a second time);
    * the IDEMPOTENCY of the call is untouched: a row that already ran is not
      run again (the stored outputs come back, the attempt count does not
      grow);
    * a row of ANOTHER tenant is invisible (INV-1/INV-5).

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  @function "platform.validate_registration"

  setup do
    tenant = Fx.tenant!("t2603-disp-retry")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin}
  end

  defp call do
    Fx.call(@function, %{
      "slug" => %{"var" => "slug"},
      "display_name" => %{"const" => "Acme Ltd"},
      "email" => %{"const" => "admin@acme.test"}
    })
  end

  defp inputs do
    %{"slug" => "acme", "display_name" => "Acme Ltd", "email" => "admin@acme.test"}
  end

  defp activated(ctx) do
    draft =
      Fx.definition!(
        ctx.tenant.schema_name,
        Fx.graph(call()),
        "pcf-t2603-disp-#{Ecto.UUID.generate()}"
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id, prefix: ctx.tenant.schema_name, activator: activator)

    Repo.get!(Definitions.ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
  end

  defp arm(ctx, definition) do
    {:ok, %{status: :armed, dispatch: row}} =
      Dispatcher.arm(
        prefix: ctx.tenant.schema_name,
        instance_id: Ecto.UUID.generate(),
        definition_id: definition.id,
        node_id: "call",
        function: @function,
        inputs: inputs()
      )

    row
  end

  defp reload(ctx, row), do: Repo.get!(StepDispatch, row.id, prefix: ctx.tenant.schema_name)

  # ── the tests ──────────────────────────────────────────────────────────────

  test "a manual retry is not stopped by the attempt cap", ctx do
    definition = activated(ctx)
    row = arm(ctx, definition)

    # The call has used up its whole automatic budget: the row is armed and
    # its attempt count is at the cap, so the AUTOMATIC claim gives it up.
    exhausted =
      row
      |> StepDispatch.claim_changeset(%{
        status: :pending,
        attempt_index: Dispatcher.max_attempts(),
        next_attempt_at: DateTime.utc_now()
      })
      |> Repo.update!(prefix: ctx.tenant.schema_name)

    # The AUTOMATIC path gives up on such a row...
    assert {:error, :platform_step_max_attempts} =
             Dispatcher.attempt_dispatch(exhausted.id, ctx.tenant.schema_name)

    # ...but the MANUAL retry of an operator runs it once more.
    assert {:ok, %{status: :advanced, outputs: outputs}} =
             Dispatcher.retry_failed_step(exhausted.id, ctx.tenant.schema_name)

    assert outputs["normalized_slug"] == "acme"

    reloaded = reload(ctx, exhausted)
    assert reloaded.status == :advanced
    assert reloaded.last_failure_kind == nil
    # The attempt count KEPT growing: the step log shows the whole history.
    assert reloaded.attempt_index == Dispatcher.max_attempts() + 1
  end

  test "a manual retry of a row that is in flight is refused", ctx do
    definition = activated(ctx)
    row = arm(ctx, definition)

    # The row is RUNNING with a lease that has not expired: a body is in
    # flight right now.
    running =
      row
      |> StepDispatch.claim_changeset(%{
        status: :running,
        attempt_index: 1,
        next_attempt_at: DateTime.add(DateTime.utc_now(), Dispatcher.lease_ms(), :millisecond)
      })
      |> Repo.update!(prefix: ctx.tenant.schema_name)

    assert {:error, :platform_step_in_flight} =
             Dispatcher.retry_failed_step(running.id, ctx.tenant.schema_name)

    reloaded = reload(ctx, running)
    assert reloaded.status == :running
    assert reloaded.outputs == nil
  end

  test "a manual retry of a step that already ran changes nothing", ctx do
    definition = activated(ctx)
    row = arm(ctx, definition)

    assert {:ok, {:advanced, outputs}} =
             Dispatcher.attempt_dispatch(row.id, ctx.tenant.schema_name)

    assert {:ok, %{status: :already_final, outputs: replayed}} =
             Dispatcher.retry_failed_step(row.id, ctx.tenant.schema_name)

    assert replayed == outputs

    reloaded = reload(ctx, row)
    # The body did NOT run a second time.
    assert reloaded.attempt_index == 1
    assert reloaded.status == :advanced
  end

  test "a row of another tenant is invisible", ctx do
    definition = activated(ctx)
    row = arm(ctx, definition)

    company = Fx.tenant!("t2603-disp-company")

    assert {:error, :platform_step_not_found} =
             Dispatcher.retry_failed_step(row.id, company.schema_name)

    # The platform tenant's own row is untouched.
    reloaded = reload(ctx, row)
    assert reloaded.status == :pending
    assert reloaded.outputs == nil
  end

  test "an id that is not an id answers the uniform refusal", ctx do
    assert {:error, :platform_step_not_found} =
             Dispatcher.retry_failed_step("not-a-uuid", ctx.tenant.schema_name)
  end
end
