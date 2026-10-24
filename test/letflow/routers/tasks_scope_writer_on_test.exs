defmodule Letflow.Routers.TasksScopeWriterOnTest do
  @moduledoc """
  REQ-532 / GH #3091 (AC 4): end to end under the stored mode `on`, a task that the ENGINE created
  carries its instance's scope node (`tasks.scope_node_id`, written by `TaskActivation.insert_task_row/4`),
  and the task routes follow it:

    * T4a a scoped TASK_WORKER in the routing role, with a grant covering the instance's node, sees the
      task in `GET /tasks` and `GET /tasks/inbox`, and claims and completes it;
    * T4b a grant on a sibling subtree: the task is a 404 on get, and absent from the lists;
    * T4c a task of an unscoped instance (NULL) is a 404 for a scoped caller, however wide its grant;
    * T4d the same user outside the routing role is a 404 on get, even with the covering grant;
    * T4e a node retired after the instance started: the task keeps its node and is a 404 (the
      existing scope set decides, and it is fail-closed).

  No task is placed by the fixture: each task is created through `Letflow.Engine.create/2`, so the
  scope node is the writer's own. `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.TaskScopeFixture, as: T

  @tw "TASK_WORKER"

  setup do
    fx = T.provision!("req532-on")
    {:ok, fx: fx, schema: fx.schema_name, definition: definition!(fx.schema_name)}
  end

  # ---- helpers ----------------------------------------------------------------------------------

  defp definition!(schema) do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => T.routing_role()}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }

    {:ok, definition} =
      Definitions.create(
        %{
          name: "req532-on-" <> to_string(System.unique_integer([:positive, :monotonic])),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  # a pending task created by the engine under `scope` (nil: an unscoped instance)
  defp engine_task!(fx, definition, scope) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, %{instance_id: instance_id}} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: "req532-on-start-#{n}",
          scope_node_id: scope
        },
        prefix: fx.schema_name
      )

    Repo.one!(from(t in EngineTask, where: t.instance_id == ^instance_id), prefix: fx.schema_name)
  end

  defp get(fx, caller, task), do: T.call(fx, caller, :get, "/#{task.id}")
  defp list(fx, caller), do: T.call(fx, caller, :get, "/")
  defp inbox(fx, caller), do: T.call(fx, caller, :get, "/inbox")
  defp claim(fx, caller, task), do: T.call(fx, caller, :post, "/#{task.id}/claim")
  defp complete(fx, caller, task), do: T.call(fx, caller, :post, "/#{task.id}/complete", %{})

  # ---- AC 4 ------------------------------------------------------------------------------------

  describe "AC 4 a scoped TASK_WORKER and a task the engine scoped" do
    test "T4a the covering grant sees the task in get, list and inbox, and claims and completes it",
         %{fx: fx, definition: definition} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = engine_task!(fx, definition, fx.nodes.a1)
      assert task.scope_node_id == fx.nodes.a1

      assert get(fx, caller, task).status == 200
      assert task.id in T.ids(list(fx, caller))
      assert task.id in T.ids(inbox(fx, caller))

      assert claim(fx, caller, task).status == 200
      assert complete(fx, caller, task).status == 200
      assert T.task(fx, task.id).status == :completed
    end

    test "T4b a grant on a sibling subtree: a 404 on get and absent from the lists",
         %{fx: fx, definition: definition} do
      caller = T.caller!(fx, grants: [{@tw, :b}])
      task = engine_task!(fx, definition, fx.nodes.a1)

      assert get(fx, caller, task).status == 404
      refute task.id in T.ids(list(fx, caller))
      refute task.id in T.ids(inbox(fx, caller))
      assert T.task(fx, task.id).status == :pending
    end

    test "T4c a task of an unscoped instance is a 404 for a scoped caller, even with a wide grant",
         %{fx: fx, definition: definition} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = engine_task!(fx, definition, nil)
      assert task.scope_node_id == nil

      assert get(fx, caller, task).status == 404
      assert complete(fx, caller, task).status == 404
      refute task.id in T.ids(list(fx, caller))
      assert T.task(fx, task.id).status == :pending
    end

    test "T4d the same user outside the routing role is a 404 on get, even with the covering grant",
         %{fx: fx, definition: definition} do
      caller = T.caller!(fx, grants: [{@tw, :a}], routing: false)
      task = engine_task!(fx, definition, fx.nodes.a1)

      assert get(fx, caller, task).status == 404
      refute task.id in T.ids(list(fx, caller))
    end

    test "T4e a node retired after the instance started: the task stays its node and is a 404 (fail-closed)",
         %{fx: fx, definition: definition} do
      caller = T.caller!(fx, grants: [{@tw, :a}])
      task = engine_task!(fx, definition, fx.nodes.a1)
      {:ok, _} = ScopeNodePaths.write({:retire, fx.nodes.a1}, fx.schema_name)

      assert T.task(fx, task.id).scope_node_id == fx.nodes.a1
      assert get(fx, caller, task).status == 404
      refute task.id in T.ids(list(fx, caller))
    end
  end
end
