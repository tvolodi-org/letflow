defmodule Letflow.Definitions.StartPermissionScopeTest do
  @moduledoc """
  The SCOPE of the per-definition start permission (T-2591, "Register a tenant"
  pilot, gap G3; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  The first attempt's security gate found four holes in the rule, and this file
  is their regression proof:

    * SF-04 -- a SUB_PROCESS child's own DECLARED permission was dropped on the
      child start path: the parent started a child that a direct start would
      have refused;
    * the DECLARED atom was evaluated with `Authorization.evaluate_access/2`,
      whose `:MetricsRead` and `:MyAccessRead` branches allow every caller: a
      declaration that looks like a guard while granting everybody;
    * the ACTIVATION fence derived the requirement from the definition's OWN
      graph, while the start check folds the children in: the fence was
      narrower than the check it guards;
    * the start read no grant overlay, while the route's own authorization read
      one: the two decisions read different facts.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.StartPermission
  alias Letflow.Engine
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenants = PlatformFx.three_tenants!()
    PlatformFx.pin!(tenants.p.tenant_id)

    admin = Fx.user!(tenants.p.schema_name, "admin")
    Fx.platform_admin!(tenants.p.schema_name, admin)

    %{platform: tenants.p, company: tenants.a, admin: admin}
  end

  # ---------------------------------------------------------------------
  # Graphs
  # ---------------------------------------------------------------------

  # START -> END: a definition with no platform call and no derived requirement.
  defp plain_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  # START -> SUB_PROCESS(child) -> END.
  defp parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sp"},
        %{"id" => "e2", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK -> SERVICE_TASK(the platform call) -> END: the call sits
  # BEHIND the human task, so an instance that starts never dispatches the step.
  defp call_graph do
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

  # The variable schemas of the platform-call step's typed mapping.
  defp schemas do
    [
      %{variable_key: "slug", json_schema: %{"type" => "string"}},
      %{variable_key: "tenant_id", json_schema: %{"type" => "string"}}
    ]
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp draft(ctx, name, graph, start_permission) do
    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: name,
          version: "1",
          graph: graph,
          created_by: Ecto.UUID.generate(),
          start_permission: start_permission
        },
        schemas_for(graph),
        prefix: ctx.platform.schema_name
      )

    definition
  end

  # A definition whose step mapping is empty (no platform call).
  defp schemas_for(graph) do
    if Enum.any?(
         graph["nodes"],
         &Map.has_key?(get_in(&1, ["attributes", "platform_call"]) || %{}, "function")
       ) do
      schemas()
    else
      []
    end
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

  # ---------------------------------------------------------------------
  # SF-04: the child's own DECLARED permission joins the parent's start
  # ---------------------------------------------------------------------

  test "SF-04: a child's DECLARED permission is part of the parent's start requirement" do
    empty_graph = %{"nodes" => [], "edges" => []}
    parent = %{graph: empty_graph, start_permission: nil}
    child = %{graph: empty_graph, start_permission: "InstancesStart"}

    task_worker = %{user_id: "u-1", tenant_id: "tenant-a", roles: ["TASK_WORKER"]}
    tenant_admin = %{user_id: "u-2", tenant_id: "tenant-a", roles: ["TENANT_ADMIN"]}

    # The child on its own: the declaration is the whole requirement.
    assert {:error, :not_found} = StartPermission.check(child, task_worker)
    assert :ok = StartPermission.check(child, tenant_admin)

    # The same child through its parent: the parent needs the same authority,
    # because the child inherits the parent's start variables.
    assert {:error, :not_found} = StartPermission.check(parent, task_worker, [child])
    assert :ok = StartPermission.check(parent, tenant_admin, [child])
  end

  test "SF-04: the ONE start function refuses a TASK_WORKER whose child declares the permission",
       ctx do
    child = draft(ctx, "rt-sf04-child", plain_graph(), "InstancesStart")
    assert {:ok, %{already_active: false}} = activate(child, ctx)

    parent = draft(ctx, "rt-sf04-parent", parent_graph(child.name), nil)
    assert {:ok, %{already_active: false}} = activate(parent, ctx)

    worker = Fx.user!(ctx.platform.schema_name, "worker")

    refused = %{
      user_id: worker.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["TASK_WORKER"]
    }

    assert {:error, :definition_not_found} = start(parent, ctx, refused, "rt-sf04-worker")

    admin = Fx.user!(ctx.platform.schema_name, "tenant-admin")

    allowed = %{
      user_id: admin.id,
      tenant_id: ctx.platform.tenant_id,
      roles: ["TENANT_ADMIN"]
    }

    assert {:ok, _result} = start(parent, ctx, allowed, "rt-sf04-admin")
  end

  # ---------------------------------------------------------------------
  # The DECLARED atom is read with the ROLE MATRIX
  # ---------------------------------------------------------------------

  test "a declaration of a role-agnostic atom is not a guard that grants everybody", ctx do
    definition = draft(ctx, "rt-metrics", plain_graph(), "MetricsRead")
    assert {:ok, %{already_active: false}} = activate(definition, ctx)

    nobody = %{
      user_id: Ecto.UUID.generate(),
      tenant_id: ctx.platform.tenant_id,
      roles: []
    }

    assert {:error, :definition_not_found} = start(definition, ctx, nobody, "rt-metrics")
  end

  # ---------------------------------------------------------------------
  # The activation fence reads the CHILDREN too
  # ---------------------------------------------------------------------

  test "the activation fence refuses a parent whose CHILD needs a stronger permission", ctx do
    child = draft(ctx, "rt-fence-child", call_graph(), nil)
    assert {:ok, %{already_active: false}} = activate(child, ctx)

    parent = draft(ctx, "rt-fence-parent", parent_graph(child.name), "InstancesStart")

    assert {:error, {:start_permission_invalid, violation}} = activate(parent, ctx)
    assert violation.code == :start_permission_too_weak
    assert violation.declared == "InstancesStart"
    assert violation.required == "TenantsManage"
  end

  # ---------------------------------------------------------------------
  # The start reads the tenant's grant overlay
  # ---------------------------------------------------------------------

  test "the start reads the tenant's grant overlay, the facts the route resolved", ctx do
    definition = draft(ctx, "rt-overlay", plain_graph(), "AssetsRead")
    assert {:ok, %{already_active: false}} = activate(definition, ctx)

    storekeeper = %{
      user_id: Ecto.UUID.generate(),
      tenant_id: ctx.platform.tenant_id,
      roles: ["STOREKEEPER"]
    }

    # Without the overlay the storekeeper holds no asset atom at all.
    assert {:error, :definition_not_found} =
             start(definition, ctx, storekeeper, "rt-overlay-none")

    granted = Map.put(storekeeper, :role_overlay, %{STOREKEEPER: [:AssetsRead]})
    assert {:ok, _result} = start(definition, ctx, granted, "rt-overlay-granted")
  end
end
