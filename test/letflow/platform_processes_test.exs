defmodule Letflow.PlatformProcessesTest do
  @moduledoc """
  The ONE start of the pilot's registration PROCESS (T-2591, "Register a tenant"
  pilot, gap G3; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  `Letflow.PlatformProcesses.start_register_tenant/2` starts the active version of
  `platform.register_tenant` in the PLATFORM tenant with the form's values as
  the start variables, through the ONE start function
  (`Letflow.Engine.create/2`) -- so the definition's start permission is checked
  against the caller and everybody else gets the answer for an UNKNOWN
  definition (INV-5).

  This file proves the seam itself: the variables the start carries, the
  instance it produces and the refusal of a caller without the permission. The
  route that calls it (`POST /api/v1/onboarding`) is wired to it in the slice
  that also ships the definition: until the platform tenant holds an active
  `platform.register_tenant`, the route cannot start it, and the old direct
  path is the only way to register a tenant (see the summary of T-2591).

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.PlatformProcesses
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenants = PlatformFx.three_tenants!()
    PlatformFx.pin!(tenants.p.tenant_id)

    admin = Fx.user!(tenants.p.schema_name, "admin")
    Fx.platform_admin!(tenants.p.schema_name, admin)

    %{platform: tenants.p, company: tenants.a, admin: admin}
  end

  # The pilot's registration definition, in the platform tenant, active, with the
  # declared start permission. The graph is START -> HUMAN_TASK -> END: the
  # definition's platform steps are the step library's business (gap G1), this
  # file is about the START.
  defp register_tenant_definition(ctx) do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }

    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: PlatformProcesses.register_tenant_definition_name(),
          version: "1",
          graph: graph,
          created_by: Ecto.UUID.generate(),
          start_permission: "TenantsManage"
        },
        [],
        prefix: ctx.platform.schema_name
      )

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert {:ok, %{already_active: false}} =
             Definitions.activate(definition.id,
               prefix: ctx.platform.schema_name,
               activator: activator
             )

    definition
  end

  defp form do
    %{
      slug: "acme-pp",
      name: "Acme PP",
      hostname: "acme-pp.example.com",
      realm_id: nil,
      admin_email: nil
    }
  end

  defp start(auth_context) do
    PlatformProcesses.start_register_tenant(form(),
      actor_id: auth_context.user_id,
      idempotency_key: "pp-start-#{Ecto.UUID.generate()}",
      auth_context: auth_context
    )
  end

  test "the pilot's process starts in the platform tenant with the form's values", ctx do
    register_tenant_definition(ctx)

    auth_context = %{
      user_id: ctx.admin.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    assert {:ok, result} = start(auth_context)
    assert is_binary(result.instance_id)
    assert result.status == :active

    # The start variables are the form's values, under the names the catalogue's
    # tenant family declares.
    assert result.variables["slug"] == "acme-pp"
    assert result.variables["name"] == "Acme PP"
    assert result.variables["hostname"] == "acme-pp.example.com"
  end

  test "a value the caller did not send is OMITTED, never sent as a nil" do
    assert %{"slug" => "s"} =
             PlatformProcesses.register_tenant_variables(%{slug: "s", name: nil, hostname: ""})
  end

  test "a platform user WITHOUT the start permission gets the answer for an unknown definition",
       ctx do
    register_tenant_definition(ctx)

    operator = Fx.user!(ctx.platform.schema_name, "operator")

    auth_context = %{
      user_id: operator.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    }

    assert {:error, :definition_not_found} = start(auth_context)
  end

  test "a company tenant's administrator gets the answer for an unknown definition", ctx do
    register_tenant_definition(ctx)

    auth_context = %{
      user_id: Ecto.UUID.generate(),
      tenant_id: ctx.company.tenant_id,
      roles: ["TENANT_ADMIN"]
    }

    assert {:error, :definition_not_found} = start(auth_context)
  end

  # T-2591 (the security gate's INV-8 finding): the seam answers a TYPED error
  # when the caller omits a required option. It never raises: the next slice
  # calls it from a route, and a route that forgets an option must not answer a
  # 500.
  test "a missing actor or idempotency key is a typed error, never a raise" do
    assert {:error, :missing_actor_id} =
             PlatformProcesses.start_register_tenant(form(),
               idempotency_key: "pp-missing-actor",
               auth_context: %{user_id: Ecto.UUID.generate(), roles: []}
             )

    assert {:error, :missing_idempotency_key} =
             PlatformProcesses.start_register_tenant(form(),
               actor_id: Ecto.UUID.generate(),
               auth_context: %{user_id: Ecto.UUID.generate(), roles: []}
             )
  end
end
