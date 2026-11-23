defmodule Letflow.Definitions.RegisterTenantStartPermissionTest do
  @moduledoc """
  S5 of the pilot's authority rule, proved for the PER-DEFINITION start
  permission (T-2591, "Register a tenant" pilot, gap G3; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  **Threat.** A platform user without `TenantsManage` starts the pilot's
  registration definition with chosen start variables (they are TRUSTED inputs:
  the values the platform functions read).

  **Mitigation.** The definition DECLARES its start permission
  (`process_definitions.start_permission`), the ONE start function
  (`Letflow.Engine.create/2`) checks it, and a declaration that is WEAKER than
  the permission the definition's own catalogue calls require is refused at
  activation -- a declaration may not look like a guard while granting less
  than the step needs.

  The answer for everybody else is the answer for an UNKNOWN definition
  (INV-5): the start refuses and nothing is written.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenants = PlatformFx.three_tenants!()
    PlatformFx.pin!(tenants.p.tenant_id)

    admin = Fx.user!(tenants.p.schema_name, "admin")
    Fx.platform_admin!(tenants.p.schema_name, admin)

    %{platform: tenants.p, company: tenants.a, admin: admin}
  end

  # START -> HUMAN_TASK -> SERVICE_TASK (the platform call) -> END: the call sits
  # BEHIND the human task, so the instance STARTS and the test is about the
  # start's authority, not about the step's dispatch.
  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" =>
              Fx.call("tenant.create", %{
                "slug" => %{"var" => "slug"},
                "name" => %{"const" => "Acme"}
              })
          }
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "call"},
        %{"id" => "e3", "source" => "call", "target" => "end"}
      ]
    }
  end

  # The variable schemas of the step's typed mapping: the variables the step
  # reads and the one it writes.
  defp schemas do
    [
      %{variable_key: "slug", json_schema: %{"type" => "string"}},
      %{variable_key: "tenant_id", json_schema: %{"type" => "string"}}
    ]
  end

  # A DRAFT that declares `start_permission` (nil = no declaration).
  defp draft(ctx, name, start_permission) do
    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: name,
          version: "1",
          graph: graph(),
          created_by: Ecto.UUID.generate(),
          start_permission: start_permission
        },
        schemas(),
        prefix: ctx.platform.schema_name
      )

    definition
  end

  defp activator(ctx) do
    Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)
  end

  defp activate(definition, ctx) do
    Definitions.activate(definition.id,
      prefix: ctx.platform.schema_name,
      activator: activator(ctx)
    )
  end

  defp start(definition, ctx, auth_context, key) do
    Engine.create(
      %{
        definition_id: definition.id,
        initial_variables: %{"slug" => "acme"},
        actor_id: Map.get(auth_context, :user_id, Ecto.UUID.generate()),
        idempotency_key: key
      },
      prefix: ctx.platform.schema_name,
      auth_context: auth_context
    )
  end

  test "S5-a: a platform user WITHOUT the declared permission gets the answer for an unknown definition",
       ctx do
    definition = draft(ctx, "rt-start-perm-1", "TenantsManage")
    assert {:ok, %{already_active: false}} = activate(definition, ctx)

    operator = Fx.user!(ctx.platform.schema_name, "operator")

    auth_context = %{
      user_id: operator.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    }

    assert {:error, :definition_not_found} =
             start(definition, ctx, auth_context, "rt-start-perm-1")
  end

  test "S5-b: activation of a WEAKER start_permission than the catalogue call requires is refused",
       ctx do
    # `:InstancesStart` is held by PROCESS_OPERATOR and TENANT_ADMIN as well, so
    # it grants less than `:TenantsManage` (PLATFORM_ADMIN only).
    definition = draft(ctx, "rt-start-perm-2", "InstancesStart")

    assert {:error, {:start_permission_invalid, violation}} = activate(definition, ctx)
    assert violation.code == :start_permission_too_weak
    assert violation.declared == "InstancesStart"
    assert violation.required == "TenantsManage"

    # The refusal leaves the version a DRAFT: nothing was switched on.
    assert %Definitions.ProcessDefinition{status: :draft} =
             Repo.get(Definitions.ProcessDefinition, definition.id,
               prefix: ctx.platform.schema_name
             )
  end

  test "S5-c: the PLATFORM_ADMIN starts it, and the declaration is stored on the version", ctx do
    definition = draft(ctx, "rt-start-perm-3", "TenantsManage")
    assert {:ok, %{already_active: false}} = activate(definition, ctx)

    auth_context = %{
      user_id: ctx.admin.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    assert {:ok, result} = start(definition, ctx, auth_context, "rt-start-perm-3")
    assert result.status == :active

    assert %Definitions.ProcessDefinition{start_permission: "TenantsManage"} =
             Repo.get(Definitions.ProcessDefinition, definition.id,
               prefix: ctx.platform.schema_name
             )
  end

  test "S5-d: a declaration of an unknown permission name is refused at the write path", ctx do
    assert {:error, {:start_permission_invalid, violation}} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "rt-start-perm-4",
                 version: "1",
                 graph: graph(),
                 created_by: Ecto.UUID.generate(),
                 start_permission: "NotAPermission"
               },
               schemas(),
               prefix: ctx.platform.schema_name
             )

    assert violation.code == :start_permission_unknown
  end

  test "S5-e: the DECLARED permission alone holds a definition with no catalogue call", ctx do
    # A definition with no platform_call has no derived requirement, so the
    # declaration is the ONLY one: a caller without it is refused, and a caller
    # with it starts.
    plain_graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }

    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: "rt-start-perm-5",
          version: "1",
          graph: plain_graph,
          created_by: Ecto.UUID.generate(),
          start_permission: "TenantsManage"
        },
        [],
        prefix: ctx.platform.schema_name
      )

    assert {:ok, %{already_active: false}} = activate(definition, ctx)

    operator = Fx.user!(ctx.platform.schema_name, "operator")

    refused = %{
      user_id: operator.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    }

    assert {:error, :definition_not_found} = start(definition, ctx, refused, "rt-start-perm-5")

    allowed = %{
      user_id: ctx.admin.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    assert {:ok, _result} = start(definition, ctx, allowed, "rt-start-perm-6")
  end
end
