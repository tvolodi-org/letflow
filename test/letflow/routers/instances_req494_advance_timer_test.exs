defmodule Letflow.Routers.InstancesReq494AdvanceTimerTest do
  @moduledoc """
  REQ-494 AC9: `POST /instances/:id/advance-timer` against an instance whose HUMAN_TASK
  carries both a reminder and an escalation timer (two pending timers).

  Design: `lib/letflow/design/req494-human-task-reminder-timer.md` section 5 and test
  matrix rows T-09a..c. The pre-existing ISS-0389 advance-timer tests in
  `test/letflow/routers/instances_test.exs` (single pending -> 200, two deadlines ->
  400) stay untouched and keep covering the non-reminder shapes.

  Same dispatch mechanism as `instances_test.exs` (direct
  `Letflow.Routers.Instances.call/2`, `auth_context` assigned directly). Real Postgres,
  `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [where: 3]

  alias Letflow.Api.Error
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Instances.init([])

  defp build_conn(path, tenant, body) do
    conn(:post, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: ["PROCESS_OPERATOR"]
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Instances.call(conn, @opts)

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp human_task(attributes),
    do: %{"id" => "a", "node_type" => "HUMAN_TASK", "attributes" => attributes}

  defp graph(a_node) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        a_node,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "a"},
        %{"id" => "e2", "source" => "a", "target" => "end"}
      ]
    }
  end

  defp reminder_and_escalation_graph do
    graph(
      human_task(%{
        "role" => "r",
        "reminder_timer_duration" => "PT1H",
        "reminder_role" => "r-remind",
        "escalation_timer_duration" => "PT4H",
        "escalation_role" => "r-escalated"
      })
    )
  end

  defp reminder_only_graph do
    graph(
      human_task(%{
        "role" => "r",
        "reminder_timer_duration" => "PT1H",
        "reminder_role" => "r-remind"
      })
    )
  end

  defp start_instance!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique("req494-advt-def"),
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: activated.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("req494-advt-start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp timers(schema_name, instance_id) do
    Timer
    |> where([t], t.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
  end

  defp pending_of_type(schema_name, instance_id, timer_type) do
    schema_name
    |> timers(instance_id)
    |> Enum.filter(&(&1.status == "pending" and &1.timer_type == timer_type))
  end

  defp task_statuses(schema_name, instance_id) do
    EngineTask
    |> where([t], t.instance_id == ^instance_id)
    |> Repo.all(prefix: schema_name)
    |> Enum.map(& &1.status)
  end

  describe "advance-timer with a reminder (REQ-494 AC9)" do
    test "two pending timers and no timer_id return 400 with code ambiguous_pending_timers" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req494-advt-a")
      instance_id = start_instance!(tenant.schema_name, reminder_and_escalation_graph())

      assert length(
               Enum.filter(timers(tenant.schema_name, instance_id), &(&1.status == "pending"))
             ) == 2

      conn = build_conn("/#{instance_id}/advance-timer", tenant, %{}) |> dispatch()

      assert conn.status == 400
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/problem+json"

      body = Jason.decode!(conn.resp_body)

      assert body |> Map.keys() |> Enum.sort() == [
               "code",
               "detail",
               "status",
               "title",
               "trace_id",
               "type"
             ]

      assert body == %{
               "type" => Error.bad_request("x").type,
               "title" => "Bad Request",
               "status" => 400,
               "detail" => "instance has more than one pending timer; specify timer_id",
               "trace_id" => "fixed-test-trace-id",
               "code" => "ambiguous_pending_timers"
             }

      assert length(pending_of_type(tenant.schema_name, instance_id, "reminder")) == 1
      assert length(pending_of_type(tenant.schema_name, instance_id, "escalation")) == 1
    end

    test "timer_id naming the reminder fires only the reminder" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req494-advt-b")
      instance_id = start_instance!(tenant.schema_name, reminder_and_escalation_graph())
      assert [reminder] = pending_of_type(tenant.schema_name, instance_id, "reminder")

      conn =
        build_conn("/#{instance_id}/advance-timer", tenant, %{"timer_id" => reminder.id})
        |> dispatch()

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "instance_id" => instance_id,
               "timer_id" => reminder.id,
               "node_id" => "a",
               "timer_status" => "fired"
             }

      assert task_statuses(tenant.schema_name, instance_id) == [:pending]
      assert pending_of_type(tenant.schema_name, instance_id, "reminder") == []
      assert length(pending_of_type(tenant.schema_name, instance_id, "escalation")) == 1
    end

    test "exactly one pending (reminder) timer and no timer_id behaves as before: 200, fired" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req494-advt-c")
      instance_id = start_instance!(tenant.schema_name, reminder_only_graph())
      assert [reminder] = pending_of_type(tenant.schema_name, instance_id, "reminder")

      conn = build_conn("/#{instance_id}/advance-timer", tenant, %{}) |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["timer_id"] == reminder.id
      assert body["timer_status"] == "fired"
      assert task_statuses(tenant.schema_name, instance_id) == [:pending]
    end
  end
end
