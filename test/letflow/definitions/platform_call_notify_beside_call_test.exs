defmodule Letflow.Definitions.PlatformCallNotifyBesideCallTest do
  @moduledoc """
  The NOTIFICATION step beside a write-like catalogue call (T-2595, gap G9 of
  the "Register a tenant" pilot).

  The foreign-source rule of the platform-call authority rule refuses a graph
  that carries a write-like catalogue call AND a node that merges a value into
  the instance variables from outside the graph's own trusted inputs (an
  inline HTTP service task, a script-bound one, a sub-process): such a node
  could overwrite the value the call reads -- a source the human-task
  comparison cannot see.

  A NOTIFICATION step merges nothing: it reads variables of the instance and
  writes none of them (the notification leaves the process, it changes no
  variable). It is therefore not a foreign source, and the pilot's own
  definition -- the chain of the tenant registration, which ends in a
  notification -- may be switched on.

  The exemption is narrow: it holds for a node that routes itself by the
  `notify` attribute ALONE. A node that carries `notify` beside `endpoint`,
  `service_id` or `script_key` keeps the foreign-source rule (and is refused
  by the notify fence as well), so the rule cannot be dodged by hanging a
  `notify` attribute on a node that really does call something.

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.PlatformCalls
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.OutboundDestinations
  alias Letflow.PlatformFunctions.Guard
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2595-notify")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    # T-2597 (pilot gap G14): the tenant's OUTBOUND ALLOW-LIST -- the mail
    # channel. The list is empty by default, and a definition that carries a
    # notification step is refused at the activation while the channel is
    # closed (the guardrail task's own test file covers the refusal). Only the
    # CHANNEL is opened here: the recipient's domain is a runtime variable, so
    # no destination is known at activation time.
    {:ok, _entry} =
      OutboundDestinations.add(tenant.schema_name, admin.id, "email", nil)

    %{tenant: tenant, admin: admin}
  end

  defp activator(ctx) do
    Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)
  end

  # START -> the write-like catalogue call -> the notification -> END.
  # `extra_node_attributes` are the OTHER attributes of the notification node
  # (a route beside the notification -- the case the rule may not be dodged
  # with).
  defp graph_with(extra_node_attributes) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{
            "platform_call" =>
              Fx.call("tenant.create", %{
                "slug" => %{"var" => "slug"},
                "name" => %{"var" => "name"}
              })
          }
        },
        %{
          "id" => "notify",
          "node_type" => "SERVICE_TASK",
          "attributes" =>
            Map.merge(
              %{
                "notify" => %{
                  "template_key" => "tenant_registered",
                  "recipient" => %{"var" => "admin_email"},
                  "values" => %{
                    "tenant_name" => %{"var" => "name"},
                    "tenant_slug" => %{"var" => "slug"}
                  }
                }
              },
              extra_node_attributes
            )
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "notify"},
        %{"id" => "e3", "source" => "notify", "target" => "end"}
      ]
    }
  end

  defp schemas do
    Enum.map(["slug", "name", "tenant_id", "admin_email"], fn key ->
      %{variable_key: key, json_schema: %{"type" => "string"}}
    end)
  end

  test "a notification step beside a write-like catalogue call is not a foreign source", ctx do
    draft =
      Fx.definition_with_schemas!(
        ctx.tenant.schema_name,
        graph_with(%{}),
        "pcf-notify",
        schemas()
      )

    assert {:ok, %{already_active: false}} =
             Definitions.activate(draft.id,
               prefix: ctx.tenant.schema_name,
               activator: activator(ctx)
             )
  end

  test "the rule cannot be dodged: a notification node that also calls out never becomes a definition",
       ctx do
    # the graph validator refuses such a node before it can be written: the
    # step kinds are exclusive
    assert {:error, {:graph_validation_failed, [violation]}} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "pcf-notify-dual",
                 version: "1",
                 graph: graph_with(%{"endpoint" => "https://example.com/hook"}),
                 created_by: ctx.admin.id
               },
               schemas(),
               prefix: ctx.tenant.schema_name
             )

    assert violation.code == :notify_conflicting_route

    assert Repo.aggregate(ProcessDefinition, :count, prefix: ctx.tenant.schema_name) == 0
  end

  test "the run-time fence reads the same graph the same way", ctx do
    {:ok, %Graph{} = with_notify} = Graph.from_map(graph_with(%{}))

    {:ok, %Graph{} = with_dual} =
      Graph.from_map(graph_with(%{"endpoint" => "https://example.com/x"}))

    assert PlatformCalls.foreign_source_graph?(with_notify) == false
    assert PlatformCalls.foreign_source_graph?(with_dual) == true

    # and the dispatch fence refuses the dual-route graph
    definition = %{
      id: Ecto.UUID.generate(),
      graph: graph_with(%{"endpoint" => "https://example.com/x"})
    }

    assert {:error, :platform_call_foreign_source_refused} =
             Guard.authorize_dispatch(
               prefix: ctx.tenant.schema_name,
               tenant_id: ctx.tenant.tenant_id,
               function: "tenant.create",
               definition: definition
             )
  end
end
