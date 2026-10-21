defmodule Letflow.Simulation.RunnerTimerNodeTest do
  @moduledoc """
  GH #2556: the Runner's `timer_node_id` step param (resolved to a `timer_id` for
  `POST /instances/:id/advance-timer`) on a HUMAN_TASK node that carries both a reminder and an
  escalation timer (possible since REQ-494). An optional `timer_type` param picks one; with no
  `timer_type` the request is ambiguous and the step reports an error instead of raising.

  Real Postgres, `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Identity
  alias Letflow.Scheduler.Timer
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.Scenario
  alias Letflow.TenantFixture

  @graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "a",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{
          "role" => "r",
          "reminder_timer_duration" => "PT1H",
          "reminder_role" => "r-remind",
          "escalation_timer_duration" => "PT4H",
          "escalation_role" => "r-escalated"
        }
      },
      %{"id" => "end", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e1", "source" => "start", "target" => "a"},
      %{"id" => "e2", "source" => "a", "target" => "end"}
    ]
  }

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "runner-timer-node")
    schema_name = tenant.schema_name

    name = "runner-timer-node-" <> to_string(System.unique_integer([:positive, :monotonic]))

    {:ok, definition} =
      Definitions.create(
        %{name: name, version: "1.0.0", graph: @graph, created_by: Ecto.UUID.generate()},
        prefix: schema_name
      )

    {:ok, %{definition: activated}} = Definitions.activate(definition.id, prefix: schema_name)

    {:ok, user} =
      Identity.create_user(
        %{
          "username" => name,
          "display_name" => "Runner Timer Node",
          "email" => name <> "@example.test"
        },
        prefix: schema_name,
        login_directory: :skip
      )

    {:ok, %{plaintext: token}} =
      Identity.create_token(user.id, %{roles: ["PROCESS_OPERATOR"], expires_at: nil},
        prefix: schema_name
      )

    %{
      tenant: tenant,
      definition: activated,
      actors: %{"actor" => %{"token" => token, "tenant_slug" => tenant.tenant.slug}}
    }
  end

  defp start_instance!(ctx) do
    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: ctx.definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "rtn-" <> to_string(System.unique_integer([:positive]))
               },
               prefix: ctx.tenant.schema_name
             )

    result.instance_id
  end

  defp advance_step(instance_id, params) do
    %{
      via: :api,
      action: "POST /api/v1/instances/#{instance_id}/advance-timer",
      params: params,
      produces: "advance_timer_result",
      actor: "actor"
    }
  end

  defp run_step(ctx, step) do
    scenario = %Scenario{
      id: "runner-timer-node",
      company_id: "runner-timer-node",
      process_id: ctx.definition.name,
      actors: ctx.actors,
      preconditions: [
        %{
          check: :process_definition_active,
          args: %{"name" => ctx.definition.name, "prefix" => ctx.tenant.schema_name}
        }
      ],
      steps: [step],
      expected_outcomes: []
    }

    assert {:ok, report} = Runner.run(scenario)
    assert [result] = report.step_results
    result
  end

  defp pending_timer!(ctx, instance_id, timer_type) do
    Timer
    |> Repo.all(prefix: ctx.tenant.schema_name)
    |> Enum.find(
      &(&1.instance_id == instance_id and &1.status == "pending" and &1.timer_type == timer_type)
    )
  end

  test "both timers pending: timer_type selects and fires the reminder", ctx do
    instance_id = start_instance!(ctx)
    reminder = pending_timer!(ctx, instance_id, "reminder")
    assert reminder

    result =
      run_step(
        ctx,
        advance_step(instance_id, %{"timer_node_id" => "a", "timer_type" => "reminder"})
      )

    assert result.outcome == :ok, "detail: #{inspect(result.detail)}"
    assert result.captured["timer_status"] == "fired"
    assert Repo.get!(Timer, reminder.id, prefix: ctx.tenant.schema_name).status == "fired"
    assert pending_timer!(ctx, instance_id, "escalation")
  end

  test "both timers pending: timer_type selects and fires the escalation", ctx do
    instance_id = start_instance!(ctx)
    escalation = pending_timer!(ctx, instance_id, "escalation")
    assert escalation

    result =
      run_step(
        ctx,
        advance_step(instance_id, %{"timer_node_id" => "a", "timer_type" => "escalation"})
      )

    assert result.outcome == :ok, "detail: #{inspect(result.detail)}"
    assert result.captured["timer_status"] == "fired"
    assert Repo.get!(Timer, escalation.id, prefix: ctx.tenant.schema_name).status == "fired"
  end

  test "both timers pending and no timer_type: an ambiguity error, not a raise", ctx do
    instance_id = start_instance!(ctx)

    result = run_step(ctx, advance_step(instance_id, %{"timer_node_id" => "a"}))

    assert result.outcome == :error
    assert result.detail == {:ambiguous_timer_for_node, "a", ["escalation", "reminder"]}
  end

  test "a timer_type with no pending timer on the node is a no-pending-timer error", ctx do
    instance_id = start_instance!(ctx)

    result =
      run_step(
        ctx,
        advance_step(instance_id, %{"timer_node_id" => "a", "timer_type" => "deadline"})
      )

    assert result.outcome == :error
    assert result.detail == {:no_pending_timer_for_node, "a"}
  end
end
