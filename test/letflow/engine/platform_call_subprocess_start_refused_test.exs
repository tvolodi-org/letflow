defmodule Letflow.Engine.PlatformCallSubProcessStartRefusedTest do
  @moduledoc """
  The SUB-PROCESS hole in the start fence of the platform-call authority rule
  (T-2588, "Register a tenant" pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (e)).

  The exploit the security gate showed: `Engine.create/2` checked only the
  PARENT's graph, so a platform PROCESS_OPERATOR could start an ordinary parent
  whose SUB_PROCESS child names an ACTIVE definition carrying `tenant.create`.
  The child was resolved and started directly -- the child's own start
  permission was never checked, and the child inherits the parent's start
  variables.

  The rule:

    * the start fence of a definition covers the SUB_PROCESS children it names
      (the child inherits the parent's variables, so the child needs the same
      authority as a direct start); a caller without it gets the answer for an
      UNKNOWN definition (INV-5) and nothing is written;

    * the child activation FAILS CLOSED: a child whose own graph carries a
      `platform_call` is refused, because the server-side caller that started
      the parent is not propagated to the child activation (gap G3/G17 own that
      wiring). The refusal is the unknown-definition answer, never a crash.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2588-subproc")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    operator = Fx.user!(tenant.schema_name, "operator")

    %{tenant: tenant, admin: admin, operator: operator}
  end

  defp create_call do
    Fx.call("tenant.create", %{
      "slug" => %{"var" => "slug"},
      "name" => %{"const" => "Acme"}
    })
  end

  # The CHILD: the platform call sits BEHIND a human task, so the child's own
  # activation stops there (the step library of gap G1 does not dispatch a
  # platform call yet -- that is gap G1's work, not this rule's).
  defp child_graph do
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

  # The PARENT: an ordinary definition that starts the child.
  defp parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "sub"},
        %{"id" => "e2", "source" => "sub", "target" => "end"}
      ]
    }
  end

  defp activator(ctx) do
    Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)
  end

  # The child, ACTIVE (so the parent's SUB_PROCESS node resolves it), and the
  # parent, ACTIVE too.
  defp active_pair(ctx) do
    child = Fx.definition!(ctx.tenant.schema_name, child_graph(), "pcf-sub-child")

    assert {:ok, _} =
             Definitions.activate(child.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    parent =
      Fx.definition!(ctx.tenant.schema_name, parent_graph("pcf-sub-child"), "pcf-sub-parent")

    assert {:ok, _} =
             Definitions.activate(parent.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    {child, parent}
  end

  defp instance_count(schema_name) do
    Repo.aggregate(from(p in InstanceProjection, select: p.instance_id), :count,
      prefix: schema_name
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
      prefix: ctx.tenant.schema_name,
      auth_context: auth_context
    )
  end

  test "a platform PROCESS_OPERATOR cannot start a parent whose child calls tenant.create", ctx do
    {_child, parent} = active_pair(ctx)
    before = instance_count(ctx.tenant.schema_name)

    auth_context = %{
      user_id: ctx.operator.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    }

    # The INV-5 answer for an unknown definition: the caller learns nothing
    # about the parent or the child.
    assert {:error, :definition_not_found} = start(parent, ctx, auth_context, "pcf-sub-1")

    assert instance_count(ctx.tenant.schema_name) == before
  end

  test "no child instance is written: the child's activation fails closed", ctx do
    {_child, parent} = active_pair(ctx)
    before = instance_count(ctx.tenant.schema_name)

    auth_context = %{
      user_id: ctx.admin.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PLATFORM_ADMIN"]
    }

    # The holder passes the start fence of the PARENT; the CHILD's own
    # activation fails closed, because the server-side caller is not propagated
    # to it yet (gap G3/G17).
    assert {:error, reason} = start(parent, ctx, auth_context, "pcf-sub-2")

    assert inspect(reason) =~ "platform_call"

    assert instance_count(ctx.tenant.schema_name) == before
  end

  test "an ordinary child (no platform call) still starts as before", ctx do
    child =
      Fx.definition!(
        ctx.tenant.schema_name,
        %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
        },
        "pcf-sub-plain-child"
      )

    assert {:ok, _} =
             Definitions.activate(child.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    parent =
      Fx.definition!(
        ctx.tenant.schema_name,
        parent_graph("pcf-sub-plain-child"),
        "pcf-sub-plain-parent"
      )

    assert {:ok, _} =
             Definitions.activate(parent.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    auth_context = %{
      user_id: ctx.operator.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    }

    assert {:ok, result} = start(parent, ctx, auth_context, "pcf-sub-3")
    assert result.status == :active
  end
end
