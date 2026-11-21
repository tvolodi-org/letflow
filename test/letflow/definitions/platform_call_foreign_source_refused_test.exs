defmodule Letflow.Definitions.PlatformCallForeignSourceRefusedTest do
  @moduledoc """
  The source-class rule of the platform-call authority rule (T-2588, "Register a
  tenant" pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`, decision (b)).

  The exploit the security gate showed: the activation fence compared the
  catalogue call's trusted variables with the HUMAN TASK completer inputs only.
  A preceding inline HTTP SERVICE_TASK (or a script-bound one, or a
  SUB_PROCESS) merges its own output into the SAME instance variables, so it
  could overwrite the value `tenant.create` reads -- a foreign source the
  T-2430 rule does not see.

  The rule: a definition that carries a WRITE-LIKE catalogue call may not carry
  a foreign source at all -- the same shape the `module_writes` rule has
  (T-2444, `write_target_sources_scan_test.exs` WTS-4: "a service, script or
  sub-process node would add a source `WriteTargets` cannot see"). The refusal
  is at activation AND at dispatch.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformFunctions.Guard
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2588-foreign")
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

  defp activator(ctx) do
    Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)
  end

  # START -> <the foreign source> -> HUMAN_TASK -> the platform call -> END.
  # The human task sits in front of the call so that the instance stops there:
  # the step library of gap G1 does not dispatch a platform call yet.
  defp graph_with(foreign_node) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        foreign_node,
        %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"platform_call" => create_call()}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "foreign"},
        %{"id" => "e2", "source" => "foreign", "target" => "ht"},
        %{"id" => "e3", "source" => "ht", "target" => "call"},
        %{"id" => "e4", "source" => "call", "target" => "end"}
      ]
    }
  end

  defp inline_http_node do
    %{
      "id" => "foreign",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"endpoint" => "https://example.com/hook", "timeout_ms" => 30_000}
    }
  end

  defp script_node do
    %{
      "id" => "foreign",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"script_key" => "notify", "script_version" => 1}
    }
  end

  defp sub_process_node do
    %{
      "id" => "foreign",
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"definition_name" => "pcf-foreign-child"}
    }
  end

  test "an inline HTTP service task in the graph refuses the activation", ctx do
    draft =
      Fx.definition!(ctx.tenant.schema_name, graph_with(inline_http_node()), "pcf-foreign-http")

    assert {:error, {:platform_calls_invalid, [violation]}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    assert %{node_id: "call", index: 0, code: :platform_call_foreign_source_refused} = violation

    assert %{status: :draft} =
             Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)
  end

  test "a script-bound service task in the graph refuses the activation", ctx do
    draft =
      Fx.definition!(ctx.tenant.schema_name, graph_with(script_node()), "pcf-foreign-script")

    assert {:error, {:platform_calls_invalid, [violation]}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    assert %{code: :platform_call_foreign_source_refused} = violation
  end

  test "a sub-process in the graph refuses the activation", ctx do
    draft =
      Fx.definition!(ctx.tenant.schema_name, graph_with(sub_process_node()), "pcf-foreign-sub")

    assert {:error, {:platform_calls_invalid, [violation]}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    assert %{code: :platform_call_foreign_source_refused} = violation
  end

  test "the dispatch guard refuses a graph that carries a foreign source", ctx do
    # A definition activated WITHOUT a foreign source, whose stored graph is
    # then edited in the database (the way a forged row would be): the dispatch
    # guard refuses it on the foreign source, not only on the broken signature.
    draft =
      Fx.definition!(ctx.tenant.schema_name, Fx.graph(create_call()), "pcf-foreign-dispatch")

    assert {:ok, _} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )

    row = Repo.get!(ProcessDefinition, draft.id, prefix: ctx.tenant.schema_name)

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^row.id),
        [set: [graph: graph_with(inline_http_node())]],
        prefix: ctx.tenant.schema_name
      )

    stored = Repo.get!(ProcessDefinition, row.id, prefix: ctx.tenant.schema_name)

    assert {:error, :platform_call_foreign_source_refused} =
             Guard.authorize_dispatch(
               definition: stored,
               prefix: ctx.tenant.schema_name,
               tenant_id: ctx.tenant.tenant_id,
               function: "tenant.create"
             )
  end

  test "a graph with no foreign source still activates", ctx do
    draft = Fx.definition!(ctx.tenant.schema_name, Fx.graph(create_call()), "pcf-foreign-clean")

    assert {:ok, _} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )
  end
end
