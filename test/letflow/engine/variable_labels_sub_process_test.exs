defmodule Letflow.Engine.VariableLabelsSubProcessTest do
  @moduledoc """
  SR-OPT-10 (decision 0062 R7b, GH #2616 part 1): variable labels travel with the copied keys
  into a sub-process child and back into the parent, are recorded in `INSTANCE_STARTED` /
  `SUB_PROCESS_COMPLETED`, and replay rebuilds them.

  Part 1 has no production source of a non-empty label, so the parent's labels are written
  straight into its projection (what a part-3 script run would leave there). The "GET
  /instances/:child redacts" half of the record's SR-OPT-10 is part 2 (it needs the read side).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.SubProcess
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  @salary ["customer.salary"]
  @ssn ["customer.ssn"]

  setup do
    %{schema_name: TenantFixture.provisioned_tenant!(slug_prefix: "gh2616-sub").schema_name}
  end

  defp seq(prefix), do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp active_definition!(schema_name, graph) do
    attrs = %{
      name: seq("gh2616-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # START -> HUMAN_TASK("work") -> END
  defp child_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "work", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "worker"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "work"},
        %{"id" => "e2", "source" => "work", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp") -> END
  defp parent_graph(child_name, interface) do
    attributes =
      if interface,
        do: %{"definition_name" => child_name, "interface" => interface},
        else: %{"definition_name" => child_name}

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "gater"}},
        %{"id" => "sp", "node_type" => "SUB_PROCESS", "attributes" => attributes},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gate"},
        %{"id" => "e2", "source" => "gate", "target" => "sp"},
        %{"id" => "e3", "source" => "sp", "target" => "end"}
      ]
    }
  end

  defp number(name), do: %{"name" => name, "json_schema" => %{"type" => "number"}}

  defp complete!(schema_name, instance_id, output) do
    task =
      EngineTask
      |> where([t], t.instance_id == ^instance_id and t.status == :pending)
      |> Repo.one!(prefix: schema_name)

    attrs = %{
      output_variables: output,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: seq("complete")
    }

    assert {:ok, _} = Engine.complete_task(task.id, attrs, prefix: schema_name)
  end

  # Parent holds a, b, y with labels on a and y, then completes the gate so the child starts.
  defp start_parent!(schema_name, interface) do
    child_def = active_definition!(schema_name, child_graph())
    parent_def = active_definition!(schema_name, parent_graph(child_def.name, interface))

    assert {:ok, %{instance_id: parent_id}} =
             Engine.create(
               %{
                 definition_id: parent_def.id,
                 initial_variables: %{"a" => 5, "b" => 1, "y" => 7},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: seq("start")
               },
               prefix: schema_name
             )

    {1, _} =
      from(p in InstanceProjection, where: p.instance_id == ^parent_id)
      |> Repo.update_all([set: [variable_labels: %{"a" => @salary, "y" => @ssn}]],
        prefix: schema_name
      )

    complete!(schema_name, parent_id, %{})
    parent_id
  end

  defp projection!(schema_name, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema_name)

  defp child_of!(schema_name, parent_id) do
    InstanceProjection
    |> where([p], p.parent_instance_id == ^parent_id)
    |> Repo.one!(prefix: schema_name)
  end

  defp payloads(schema_name, instance_id, type) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == ^type)
    |> order_by([e], asc: e.sequence_number)
    |> Repo.all(prefix: schema_name)
    |> Enum.map(& &1.payload)
  end

  defp replayed!(schema_name, instance_id) do
    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: schema_name)

    state
  end

  describe "SR-OPT-10" do
    test "no interface: the child starts with the parent's labels and they are recorded",
         %{schema_name: schema_name} do
      parent_id = start_parent!(schema_name, nil)
      child = child_of!(schema_name, parent_id)

      assert child.variables == %{"a" => 5, "b" => 1, "y" => 7}
      assert child.variable_labels == %{"a" => @salary, "y" => @ssn}

      assert [%{"initial_labels" => %{"a" => @salary, "y" => @ssn}}] =
               payloads(schema_name, child.instance_id, "INSTANCE_STARTED")

      assert replayed!(schema_name, child.instance_id).variable_labels == child.variable_labels
    end

    test "an interface naming only b: the child has no label and no key for a",
         %{schema_name: schema_name} do
      parent_id = start_parent!(schema_name, %{"inputs" => [number("b")]})
      child = child_of!(schema_name, parent_id)

      assert child.variables == %{"b" => 1}
      assert child.variable_labels == %{}

      assert [payload] = payloads(schema_name, child.instance_id, "INSTANCE_STARTED")
      refute Map.has_key?(payload, "initial_labels")
    end

    test "child output keeps its label in the parent; an unlabelled child key removes the parent's",
         %{schema_name: schema_name} do
      parent_id = start_parent!(schema_name, nil)
      child = child_of!(schema_name, parent_id)

      # the child overwrites y with an unlabelled value; a is left alone
      complete!(schema_name, child.instance_id, %{"y" => 8})

      child_done = projection!(schema_name, child.instance_id)
      assert child_done.variable_labels == %{"a" => @salary}

      parent = projection!(schema_name, parent_id)
      assert parent.variables["y"] == 8
      assert parent.variable_labels == %{"a" => @salary}

      assert [event] = payloads(schema_name, parent_id, "SUB_PROCESS_COMPLETED")
      assert event["output_labels"] == %{"a" => @salary}

      by_key = Map.new(event["merged_variable_events"], &{&1["key"], &1})
      assert by_key["a"]["old_labels"] == @salary
      assert by_key["a"]["new_labels"] == @salary
      assert by_key["y"]["old_labels"] == @ssn
      refute Map.has_key?(by_key["y"], "new_labels")
      refute Map.has_key?(by_key["b"], "old_labels")

      # replay of both instances equals their projections
      assert replayed!(schema_name, parent_id).variable_labels == parent.variable_labels

      assert replayed!(schema_name, child.instance_id).variable_labels ==
               child_done.variable_labels
    end

    test "an outputs interface: only the named key's label comes back, others are untouched",
         %{schema_name: schema_name} do
      parent_id =
        start_parent!(schema_name, %{
          "inputs" => [number("a")],
          "outputs" => [number("a")]
        })

      child = child_of!(schema_name, parent_id)
      assert child.variable_labels == %{"a" => @salary}

      complete!(schema_name, child.instance_id, %{})

      parent = projection!(schema_name, parent_id)
      assert parent.variable_labels == %{"a" => @salary, "y" => @ssn}

      assert [%{"output_labels" => %{"a" => @salary}}] =
               payloads(schema_name, parent_id, "SUB_PROCESS_COMPLETED")

      # y was labelled by injection only (no event recorded it), so replay knows just a
      assert replayed!(schema_name, parent_id).variable_labels == %{"a" => @salary}
    end
  end

  describe "SR-OPT-12: a rejected labelled value is never echoed into the error details" do
    # The parent declares `a` an integer; the child's labelled `a` is a string the parent rejects.
    defp rejected_merge!(schema_name, labels) do
      child_def = active_definition!(schema_name, child_graph())

      parent_def =
        Letflow.Support.ScriptTaskFixture.definition!(
          schema_name,
          parent_graph(child_def.name, nil),
          Letflow.Support.ScriptTaskFixture.integer_schemas(["a"])
        )

      assert {:ok, %{instance_id: parent_id}} =
               Engine.create(
                 %{
                   definition_id: parent_def.id,
                   initial_variables: %{"a" => 5},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: seq("start")
                 },
                 prefix: schema_name
               )

      complete!(schema_name, parent_id, %{})
      child = child_of!(schema_name, parent_id)

      {1, _} =
        from(p in InstanceProjection, where: p.instance_id == ^child.instance_id)
        |> Repo.update_all(
          [set: [variables: %{"a" => "secret-42"}, variable_labels: labels]],
          prefix: schema_name
        )

      task =
        EngineTask
        |> where([t], t.instance_id == ^child.instance_id and t.status == :pending)
        |> Repo.one!(prefix: schema_name)

      Engine.complete_task(
        task.id,
        %{output_variables: %{}, actor_id: Ecto.UUID.generate(), idempotency_key: seq("c")},
        prefix: schema_name
      )

      payloads(schema_name, parent_id, "EXECUTION_ERROR")
    end

    test "a labelled key: the value and each failure's actual are scrubbed", %{
      schema_name: schema_name
    } do
      assert [%{"details" => details} = payload] =
               rejected_merge!(schema_name, %{"a" => @salary})

      assert details["rejected_value"] == "__field_redacted__"
      assert Enum.all?(details["failures"], &(&1["actual"] == nil))
      refute inspect(payload) =~ "secret-42"
    end

    test "an unlabelled key keeps its details", %{schema_name: schema_name} do
      assert [%{"details" => details}] = rejected_merge!(schema_name, %{})
      assert details["rejected_value"] == "secret-42"
    end
  end

  describe "SR-OPT-10 pure label carry" do
    test "labels travel exactly with the copied keys and never for a reserved key" do
      labels = %{"a" => @salary, "y" => @ssn, "_sys.move" => ["customer.salary"]}

      assert {:ok, vars} =
               SubProcess.build_child_initial_variables(nil, %{
                 "a" => 1,
                 "b" => 2,
                 "_sys.move" => "00000000-0000-4000-8000-000000000000"
               })

      assert Map.keys(vars) |> Enum.sort() == ["a", "b"]
      assert SubProcess.child_initial_labels(vars, labels) == %{"a" => @salary}

      assert SubProcess.parent_merge_labels(%{"y" => 1}, labels) == %{"y" => @ssn}
      assert SubProcess.parent_merge_labels(%{}, labels) == %{}
    end
  end
end
