defmodule Letflow.Definitions.PlatformCallActivationAuthorityTest do
  @moduledoc """
  S1 of the platform-call authority rule (T-2588, "Register a tenant" pilot, gap
  G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  decision (b)): the ACTIVATION fence.

  A `platform_call` step -- a SERVICE_TASK bound to a platform function of the
  compiled catalogue -- may be switched on only by someone who holds the
  ENTRY'S permission (`:TenantsManage` for the tenant family) in the platform
  tenant. The rule replaces the owner stamp for catalogue calls: the signed
  `activated_by` document is the authority, and the check runs on every path
  that signs it: activate, version rollback and promotion apply.

  The threat S1 names: a `PROCESS_DESIGNER` of the platform tenant (holds
  `DefinitionsWrite`, not `TenantsManage`) adds `tenant.create` to a draft and
  activates it.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2588-s1")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)
    designer = Fx.user!(tenant.schema_name, "designer")

    %{tenant: tenant, admin: admin, designer: designer}
  end

  defp activator(user, roles) do
    Activator.from_auth_context(%{user_id: user.id, roles: roles}, true)
  end

  defp create_call do
    Fx.call("tenant.create", %{
      "slug" => %{"var" => "slug"},
      "name" => %{"const" => "Acme"}
    })
  end

  test "S1a: a PROCESS_DESIGNER of the platform tenant cannot activate a platform_call version",
       ctx do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(create_call()), "pcf-s1a")

    assert {:error, {:platform_calls_invalid, [violation]}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx.designer, ["PROCESS_DESIGNER"])
             )

    assert %{node_id: "call", index: 0, code: :platform_call_permission_required} = violation

    row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
    assert row.status == :draft
    assert row.activated_by == nil
  end

  test "S1b: a PLATFORM_ADMIN activates it, and the signed document carries the entry permission",
       ctx do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(create_call()), "pcf-s1b")

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx.admin, ["PLATFORM_ADMIN"])
             )

    row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
    assert row.status == :active

    assert %{
             "user_id" => user_id,
             "permissions" => permissions,
             "platform_functions" => ["tenant.create"]
           } = row.activated_by

    assert user_id == ctx.admin.id
    assert "TenantsManage" in permissions
  end

  test "S1c: no activator at all is refused (a module-code activation cannot switch a platform call on)",
       ctx do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(create_call()), "pcf-s1c")

    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_activator_required}]}} =
             Definitions.activate(draft.id, prefix: ctx.tenant.schema_name)
  end

  test "S1d: a function outside the catalogue is refused, whatever the activator holds", ctx do
    draft =
      Fx.definition!(
        ctx.tenant.schema_name,
        Fx.graph(Fx.call("tenant.delete_everything", %{})),
        "pcf-s1d"
      )

    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_function_unknown}]}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx.admin, ["PLATFORM_ADMIN"])
             )
  end

  test "S1e: the rollback path runs the same check: a version a designer may not switch on stays inactive",
       ctx do
    key = "pcf-s1e"

    v1 = Fx.definition!(ctx.tenant.schema_name, Fx.graph(create_call()), key)

    assert {:ok, _} =
             Definitions.activate(v1.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx.admin, ["PLATFORM_ADMIN"])
             )

    # a second version carrying the same platform call, switched on by the platform admin
    v2 = Fx.version!(ctx.tenant.schema_name, Fx.graph(create_call()), key, "2")

    assert {:ok, _} =
             Definitions.activate(v2.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx.admin, ["PLATFORM_ADMIN"])
             )

    # rolling back to v1 is a switch-on too: a designer may not do it
    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_permission_required}]}} =
             Definitions.rollback_definition_version(key, "1", Ecto.UUID.generate(),
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx.designer, ["PROCESS_DESIGNER"]),
               permission_checker: fn _actor, _tenant -> true end,
               event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
             )

    assert %{status: :active, version: "2"} =
             Repo.get!(ProcessDefinition, v2.id, prefix: ctx.tenant.schema_name)
  end
end
