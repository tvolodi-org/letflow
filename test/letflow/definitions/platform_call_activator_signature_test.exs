defmodule Letflow.Definitions.PlatformCallActivatorSignatureTest do
  @moduledoc """
  S9 of the platform-call authority rule (T-2588, "Register a tenant" pilot, gap
  G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  decision (b)): the RUN-TIME authority of a platform call.

  The threat S9 names: an `activated_by` document is edited in the database, or
  the activator lost `TenantsManage` since the version was switched on.

  The rule: the signature is checked at EVERY call (as `ActivatedBy` does for
  the entity-write path), and a permission lost since the activation makes the
  definition stale -- the call is refused and the row is flagged
  `needs_reactivation`, so the existing reactivation path (REQ-515) heals it.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.PlatformFunctions.Guard
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2588-s9")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin}
  end

  defp create_call do
    Fx.call("tenant.create", %{
      "slug" => %{"var" => "slug"},
      "name" => %{"const" => "Acme"}
    })
  end

  defp activated(ctx) do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(create_call()), "pcf-s9")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
  end

  defp authorize(row, ctx) do
    Guard.authorize_dispatch(
      definition: row,
      prefix: ctx.tenant.schema_name,
      tenant_id: ctx.tenant.tenant_id,
      function: "tenant.create"
    )
  end

  test "S9a: a call of a properly activated definition is authorized", ctx do
    row = activated(ctx)

    assert :ok = authorize(row, ctx)
    assert row.needs_reactivation_at == nil
  end

  test "S9b: a tampered MAC is refused", ctx do
    row = activated(ctx)

    tampered = put_in(row.activated_by, ["signature", "mac"], String.duplicate("a", 64))

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^row.id),
        [set: [activated_by: tampered]],
        prefix: ctx.tenant.schema_name
      )

    stored = Repo.get!(ProcessDefinition, row.id, prefix: ctx.tenant.schema_name)

    assert {:error, :platform_call_signature_invalid} = authorize(stored, ctx)
  end

  test "S9c: a document whose permission list was edited is refused", ctx do
    row = activated(ctx)

    tampered = put_in(row.activated_by, ["permissions"], ["DefinitionsActivate"])

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^row.id),
        [set: [activated_by: tampered]],
        prefix: ctx.tenant.schema_name
      )

    stored = Repo.get!(ProcessDefinition, row.id, prefix: ctx.tenant.schema_name)

    assert {:error, :platform_call_signature_invalid} = authorize(stored, ctx)
  end

  test "S9d: a revoked role refuses the call and flags the definition needs_reactivation", ctx do
    row = activated(ctx)

    Fx.revoke_platform_roles!(ctx.tenant.schema_name, ctx.admin)

    assert {:error, :platform_call_needs_reactivation} = authorize(row, ctx)

    stored = Repo.get!(ProcessDefinition, row.id, prefix: ctx.tenant.schema_name)
    assert stored.needs_reactivation_at != nil
    assert stored.needs_reactivation_reason == "activator_lost_catalogue_permission"
  end

  test "S9e: an unknown function is refused (the catalogue has no run-time entry)", ctx do
    row = activated(ctx)

    assert {:error, :platform_call_function_unknown} =
             Guard.authorize_dispatch(
               definition: row,
               prefix: ctx.tenant.schema_name,
               tenant_id: ctx.tenant.tenant_id,
               function: "tenant.not_in_the_catalogue"
             )
  end

  # ── the same two refusals THROUGH THE DISPATCHER (T-2589, gap G1a) ─────────────────────

  defp validation_call do
    Fx.call("platform.validate_registration", %{
      "slug" => %{"var" => "slug"},
      "display_name" => %{"const" => "Acme Ltd"},
      "email" => %{"const" => "admin@acme.test"}
    })
  end

  defp activated_validation(ctx, name) do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(validation_call()), name)

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
  end

  defp arm_validation(ctx, definition) do
    Dispatcher.arm(
      prefix: ctx.tenant.schema_name,
      instance_id: Ecto.UUID.generate(),
      definition_id: definition.id,
      node_id: "call",
      function: "platform.validate_registration",
      inputs: %{
        "slug" => "acme",
        "display_name" => "Acme Ltd",
        "email" => "admin@acme.test"
      }
    )
  end

  test "S9f: the DISPATCHER refuses a tampered mac and the function never runs", ctx do
    row = activated_validation(ctx, "pcf-s9f")

    tampered = put_in(row.activated_by, ["signature", "mac"], String.duplicate("a", 64))

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^row.id),
        [set: [activated_by: tampered]],
        prefix: ctx.tenant.schema_name
      )

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm_validation(ctx, row)

    assert {:error, :platform_call_signature_invalid} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_signature_invalid"
    assert stored.outputs == nil
  end

  test "S9g: the DISPATCHER refuses a revoked role and flags the definition needs_reactivation",
       ctx do
    row = activated_validation(ctx, "pcf-s9g")

    Fx.revoke_platform_roles!(ctx.tenant.schema_name, ctx.admin)

    assert {:ok, %{status: :armed, dispatch: dispatch}} = arm_validation(ctx, row)

    assert {:error, :platform_call_needs_reactivation} =
             Dispatcher.attempt_dispatch(dispatch.id, ctx.tenant.schema_name)

    stored_definition = Repo.get!(ProcessDefinition, row.id, prefix: ctx.tenant.schema_name)
    assert stored_definition.needs_reactivation_at != nil
    assert stored_definition.needs_reactivation_reason == "activator_lost_catalogue_permission"

    stored = Repo.get!(StepDispatch, dispatch.id, prefix: ctx.tenant.schema_name)
    assert stored.status == :given_up
    assert stored.last_failure_kind == "platform_call_needs_reactivation"
    assert stored.outputs == nil
  end
end
