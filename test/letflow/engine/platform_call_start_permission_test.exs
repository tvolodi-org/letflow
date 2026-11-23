defmodule Letflow.Engine.PlatformCallStartPermissionTest do
  @moduledoc """
  S4 and S5 of the platform-call authority rule (T-2588, "Register a tenant"
  pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)): the
  START permission of a definition that calls a platform function.

  The start variables of such a definition are TRUSTED inputs (the person who
  starts it chooses the values the platform function reads), so the start needs
  the same authority the activation does: the catalogue entry's permission
  (`:TenantsManage` for the tenant family), in the platform tenant.

  The answer for everybody else is the answer for an UNKNOWN definition
  (INV-5): the start refuses and nothing is written -- a company tenant's
  administrator may not even learn that the definition exists.

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
    tenant = Fx.tenant!("t2588-start")
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

  # START -> HUMAN_TASK -> SERVICE_TASK (the platform call) -> END: the call sits
  # BEHIND the human task, so the instance starts (the step library of gap G1 does
  # not dispatch the platform call yet -- that is gap G1's work, not this rule's).
  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"platform_call" => create_call()}
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

  defp active_definition(ctx) do
    draft = Fx.definition!(ctx.tenant.schema_name, graph(), "pcf-start")

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator
             )

    draft
  end

  defp start(definition, ctx, auth_context, key) do
    Engine.create(
      %{
        definition_id: definition.id,
        initial_variables: %{"slug" => "acme"},
        actor_id: Map.get(auth_context, :user_id, Ecto.UUID.generate()),
        idempotency_key: key
      },
      prefix: ctx.tenant.schema_name,
      auth_context: auth_context
    )
  end

  test "S5-a: a platform user WITHOUT the permission gets the answer for an unknown definition",
       ctx do
    definition = active_definition(ctx)

    operator = Fx.user!(ctx.tenant.schema_name, "operator")

    auth_context = %{
      user_id: operator.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    }

    assert {:error, :definition_not_found} = start(definition, ctx, auth_context, "pcf-start-1")
  end

  test "S4-a: a company tenant's administrator gets the answer for an unknown definition", ctx do
    definition = active_definition(ctx)

    company = Fx.tenant!("t2588-start-company")

    auth_context = %{
      user_id: Ecto.UUID.generate(),
      tenant_id: company.tenant_id,
      roles: ["TENANT_ADMIN"]
    }

    assert {:error, :definition_not_found} = start(definition, ctx, auth_context, "pcf-start-2")
  end

  test "S4-b: no caller at all (module code) may start it", ctx do
    definition = active_definition(ctx)

    assert {:error, :definition_not_found} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{"slug" => "acme"},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "pcf-start-3"
               },
               prefix: ctx.tenant.schema_name
             )
  end

  test "S5-b: a PLATFORM_ADMIN starts it", ctx do
    definition = active_definition(ctx)

    auth_context = %{
      user_id: ctx.admin.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    assert {:ok, result} = start(definition, ctx, auth_context, "pcf-start-4")
    assert result.status == :active
  end

  test "S5-c: an ordinary definition still starts without any of this", ctx do
    draft =
      Fx.definition!(
        ctx.tenant.schema_name,
        %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
        },
        "pcf-start-plain"
      )

    assert {:ok, _} =
             Definitions.activate(draft.id, prefix: ctx.tenant.schema_name)

    assert {:ok, _result} =
             Engine.create(
               %{
                 definition_id: draft.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "pcf-start-5"
               },
               prefix: ctx.tenant.schema_name
             )

    assert Repo.aggregate(Letflow.Definitions.ProcessDefinition, :count,
             prefix: ctx.tenant.schema_name
           ) > 0
  end
end
