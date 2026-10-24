defmodule Letflow.Engine.TaskScopeWriterTest do
  @moduledoc """
  REQ-532 / GH #3091 (decision 0051 T13): every task the engine creates carries the scope node of its
  instance, copied by `Letflow.Engine.TaskActivation.insert_task_row/4` from the instance's state.

    * AC 1, one test per insert path: the first task of `create/2`, a task after a parallel join
      (`append_multi_from_existing_records/7`, through `complete_task/3`), a task after an exclusive
      gateway (`append_multi/6`), and a sub-process child task (`Letflow.Engine.SubProcess`, the third
      path). An instance with no scope gives NULL (fail-closed);
    * AC 2: an unscoped instance's task is NULL and completes as before;
    * AC 3: a sub-process child's task carries the parent's value; an unscoped parent gives NULL;
    * AC 6: the `task.create` audit entry keeps excluding `scope_node_id` while the row carries it.

  The routes (a scoped TASK_WORKER seeing a task in its scope) are in
  `test/letflow/routers/tasks_scope_writer_on_test.exs`.

  Real Postgres, committed writes: `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.TaskScopeFixture, as: T

  setup do
    fx = T.provision!("req532-w")
    {:ok, fx: fx, schema: fx.schema_name, nodes: F.nodes()}
  end

  # ---- helpers -----------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp active_definition!(schema, name_prefix, graph) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: unique(name_prefix),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: active}} = Definitions.activate(definition.id, prefix: schema)
    active
  end

  defp start!(schema, definition, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("req532-start")
        },
        extra
      )

    assert {:ok, %{instance_id: instance_id}} = Engine.create(attrs, prefix: schema)
    instance_id
  end

  defp tasks_of(schema, instance_id, node_id) do
    Repo.all(
      from(t in EngineTask, where: t.instance_id == ^instance_id and t.node_id == ^node_id),
      prefix: schema
    )
  end

  defp only_task!(schema, instance_id, node_id) do
    assert [task] = tasks_of(schema, instance_id, node_id)
    task
  end

  defp complete!(schema, task) do
    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("req532-complete")
               },
               prefix: schema
             )
  end

  defp human(id),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => %{"role" => T.routing_role()}}

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  # START > HUMAN_TASK "first" > END
  defp first_task_graph do
    %{
      "nodes" => [%{"id" => "start", "node_type" => "START"}, human("first"), end_node()],
      "edges" => [edge("e1", "start", "first"), edge("e2", "first", "end")]
    }
  end

  # START > SPLIT > (a, b) > JOIN > "after" > END
  defp parallel_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"},
        human("a"),
        human("b"),
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        human("after"),
        end_node()
      ],
      "edges" => [
        edge("e1", "start", "split"),
        edge("e2", "split", "a"),
        edge("e3", "split", "b"),
        edge("e4", "a", "join"),
        edge("e5", "b", "join"),
        edge("e6", "join", "after"),
        edge("e7", "after", "end")
      ]
    }
  end

  # START > HUMAN_TASK "gate" > EXCLUSIVE_GATEWAY > HUMAN_TASK "after" > END (the default route)
  defp gateway_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        human("gate"),
        %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"},
        human("after"),
        end_node()
      ],
      "edges" => [
        edge("e1", "start", "gate"),
        edge("e2", "gate", "xg"),
        Map.put(edge("e3", "xg", "after"), "is_default", true),
        edge("e4", "after", "end")
      ]
    }
  end

  defp end_node, do: %{"id" => "end", "node_type" => "END"}

  # START > SUB_PROCESS > END, and the child: START > HUMAN_TASK "task" > END
  defp parent_and_child!(schema) do
    child = active_definition!(schema, "req532-child", first_task_graph())

    active_definition!(schema, "req532-parent", %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "sub",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child.name}
        },
        end_node()
      ],
      "edges" => [edge("p0", "start", "sub"), edge("p1", "sub", "end")]
    })
  end

  defp child_task!(schema, parent_id) do
    [child_id] =
      Repo.all(
        from(p in InstanceProjection,
          where: p.parent_instance_id == ^parent_id,
          select: p.instance_id
        ),
        prefix: schema
      )

    only_task!(schema, child_id, "first")
  end

  # ---- AC 1: one test per insert path ------------------------------------------------------------

  describe "AC 1 the insert paths of task_activation.ex and sub_process.ex" do
    test "T1a the first task of create/2 carries the instance's scope node", %{
      schema: schema,
      nodes: nodes
    } do
      definition = active_definition!(schema, "req532-first", first_task_graph())
      instance_id = start!(schema, definition, %{scope_node_id: nodes.a1})

      assert only_task!(schema, instance_id, "first").scope_node_id == nodes.a1
    end

    test "T1b a task created after a parallel join carries the instance's scope node", %{
      schema: schema,
      nodes: nodes
    } do
      definition = active_definition!(schema, "req532-par", parallel_graph())
      instance_id = start!(schema, definition, %{scope_node_id: nodes.b1})

      a = only_task!(schema, instance_id, "a")
      b = only_task!(schema, instance_id, "b")
      assert a.scope_node_id == nodes.b1
      assert b.scope_node_id == nodes.b1

      complete!(schema, a)
      complete!(schema, b)

      assert only_task!(schema, instance_id, "after").scope_node_id == nodes.b1
    end

    test "T1c a task created after an exclusive gateway carries the instance's scope node", %{
      schema: schema,
      nodes: nodes
    } do
      definition = active_definition!(schema, "req532-gw", gateway_graph())
      instance_id = start!(schema, definition, %{scope_node_id: nodes.a2x})

      complete!(schema, only_task!(schema, instance_id, "gate"))

      assert only_task!(schema, instance_id, "after").scope_node_id == nodes.a2x
    end

    test "T1d a sub-process child's first task carries the scope node of the parent", %{
      schema: schema,
      nodes: nodes
    } do
      parent = parent_and_child!(schema)
      parent_id = start!(schema, parent, %{scope_node_id: nodes.a1})

      assert child_task!(schema, parent_id).scope_node_id == nodes.a1
    end

    test "T1e each instance of one definition gives its own scope to its tasks", %{
      schema: schema,
      nodes: nodes
    } do
      definition = active_definition!(schema, "req532-null", parallel_graph())
      scoped = start!(schema, definition, %{scope_node_id: nodes.a1})
      plain = start!(schema, definition)

      assert only_task!(schema, scoped, "a").scope_node_id == nodes.a1
      assert only_task!(schema, plain, "a").scope_node_id == nil
    end
  end

  # ---- AC 2 and AC 3 ----------------------------------------------------------------------------

  describe "AC 2 an instance without a scope node" do
    test "T2a its task is NULL and completes as before", %{schema: schema} do
      definition = active_definition!(schema, "req532-plain", first_task_graph())
      instance_id = start!(schema, definition)

      task = only_task!(schema, instance_id, "first")
      assert task.scope_node_id == nil

      complete!(schema, task)
      assert only_task!(schema, instance_id, "first").status == :completed
    end
  end

  describe "AC 3 a sub-process child" do
    test "T3a a child of a scoped parent gets the parent's value", %{schema: schema, nodes: nodes} do
      parent = parent_and_child!(schema)
      parent_id = start!(schema, parent, %{scope_node_id: nodes.b})

      assert child_task!(schema, parent_id).scope_node_id == nodes.b
    end

    test "T3b a child of an unscoped parent gets NULL", %{schema: schema} do
      parent = parent_and_child!(schema)
      parent_id = start!(schema, parent)

      assert child_task!(schema, parent_id).scope_node_id == nil
    end
  end

  # ---- AC 6 -------------------------------------------------------------------------------------

  describe "AC 6 the task.create audit shape" do
    test "T6a the audit after_state of a scoped task has no scope_node_id, while the row has one",
         %{
           schema: schema,
           nodes: nodes
         } do
      definition = active_definition!(schema, "req532-audit", first_task_graph())
      instance_id = start!(schema, definition, %{scope_node_id: nodes.a1})
      task = only_task!(schema, instance_id, "first")

      assert task.scope_node_id == nodes.a1

      assert [entry] =
               Repo.all(
                 from(e in Entry, where: e.action == "task.create" and e.resource_id == ^task.id),
                 prefix: schema
               )

      refute Map.has_key?(entry.after_state, "scope_node_id")
    end
  end
end
