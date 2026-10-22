defmodule Letflow.Routers.HistoryRedactionTest do
  @moduledoc """
  SR-OPT-13 and SR-OPT-14 (decision 0062 R8h-3, R14, GH #2616 part 2): the history of an instance
  shows the placeholder for a value its stored event labels hide from the caller, and the clear
  value to a caller who may read it. The labels come from the event payload itself, never from the
  projection (R8h). The history item shaping is `Response.public_event_payload/3`, the function the
  history route calls for each stored event.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2, where: 3]

  alias Letflow.Api.Response
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Support.ScriptTaskFixture, as: F

  @label "customer.salary"
  # The shaped history value before JSON encoding (the router encodes the atom as this string).
  @placeholder :__field_redacted__

  @form %{
    "type" => "object",
    "properties" => %{
      "total" => %{"type" => "number"},
      "y" => %{"type" => "number", "x-ui" => %{"computed" => "total + 1"}}
    }
  }

  setup do
    %{t: F.tenant!("gh2616-history")}
  end

  # START -> svc (script: total = 4, labelled) -> review (HUMAN_TASK with the form) -> END
  defp graph(key, version) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => key, "script_version" => version}
        },
        %{
          "id" => "review",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "REVIEWER", "form_schema" => @form}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "review"},
        %{"id" => "e3", "source" => "review", "target" => "end"}
      ]
    }
  end

  defp labelled_review!(t, graph_fun \\ &graph/2) do
    labelled_script!(t, graph_fun, %{"total" => 4}, %{"total" => [@label]})
  end

  # The script task of `graph_fun` writes `result_vars`, with `labels` on the keys it names.
  defp labelled_script!(t, graph_fun, result_vars, labels) do
    b =
      F.bound_graph!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2}, graph_fun, [])

    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)

    result =
      {:ok, result_vars,
       %{
         row: row,
         phase: :ran,
         outcome: :ok,
         detail: nil,
         fail_code: nil,
         hmac: nil,
         stats: nil,
         output_labels: labels
       }}

    assert {:ok, :applied} = Engine.apply_script_task_result(F.claim(row), result, t.schema_name)
    b
  end

  # START -> svc (script: total and note, both labelled by the script) -> review (HUMAN_TASK, note
  # is visible only when total > 10, which the script's total never is) -> END.
  defp graph_with_visible_when(key, version) do
    form = %{
      "type" => "object",
      "properties" => %{
        "total" => %{"type" => "number"},
        "note" => %{"type" => "string", "x-ui" => %{"visible_when" => "total > 10"}}
      }
    }

    graph(key, version)
    |> Map.update!("nodes", fn nodes ->
      Enum.map(nodes, fn
        %{"id" => "review"} = node -> put_in(node, ["attributes", "form_schema"], form)
        node -> node
      end)
    end)
  end

  # START -> svc (script) -> review (HUMAN_TASK) -> out (SERVICE_TASK whose URL renders empty,
  # so the completion writes an EXECUTION_ERROR on the same advance) -> END
  defp graph_with_empty_url(key, version) do
    graph(key, version)
    |> Map.update!("nodes", fn nodes ->
      List.insert_at(nodes, -2, %{
        "id" => "out",
        "node_type" => "SERVICE_TASK",
        "attributes" => %{
          "endpoint" => "{{variables.blank}}",
          "method" => "POST",
          "timeout_ms" => 5000
        }
      })
    end)
    |> Map.update!("edges", fn edges ->
      List.replace_at(edges, 2, %{"id" => "e3", "source" => "review", "target" => "out"}) ++
        [%{"id" => "e4", "source" => "out", "target" => "end"}]
    end)
  end

  # START -> svc (script) -> review (HUMAN_TASK) -> xg (EXCLUSIVE_GATEWAY: one condition on the
  # computed `y`, and a default edge so the definition validates) -> END.
  defp graph_with_gateway(key, version) do
    graph(key, version)
    |> Map.update!("nodes", fn nodes ->
      List.insert_at(nodes, -2, %{"id" => "xg", "node_type" => "EXCLUSIVE_GATEWAY"})
    end)
    |> Map.update!("edges", fn edges ->
      List.replace_at(edges, 2, %{"id" => "e3", "source" => "review", "target" => "xg"}) ++
        [
          %{"id" => "e4", "source" => "xg", "target" => "end", "condition" => "variables.y == 1"},
          %{"id" => "e5", "source" => "xg", "target" => "end", "is_default" => true}
        ]
    end)
  end

  defp complete!(t, instance_id, output) do
    task =
      Repo.one!(
        from(x in Letflow.Engine.Task,
          where: x.instance_id == ^instance_id and x.status == :pending
        ),
        prefix: t.schema_name
      )

    completer = Ecto.UUID.generate()

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: completer,
                 idempotency_key: "h-#{completer}"
               },
               prefix: t.schema_name
             )
  end

  # The history route's item shaping, applied to each stored event of the instance.
  defp history(t, instance_id, hidden) do
    {:ok, events} = EventStore.read(instance_id, prefix: t.schema_name)

    for event <- events do
      payload = if is_binary(event.payload), do: Jason.decode!(event.payload), else: event.payload

      {event.event_type, Response.public_event_payload(event.event_type, payload, hidden)}
    end
  end

  defp payload_of(history, type) do
    for {^type, payload} <- history, do: payload
  end

  describe "SR-OPT-13 history of a value that was overwritten" do
    test "(a) the earlier labelled value and its overwrite are hidden from a caller without the grant",
         %{t: t} do
      b = labelled_review!(t)
      complete!(t, b.instance_id, %{"total" => 9})

      hidden = MapSet.new([@label])
      shown = history(t, b.instance_id, hidden)

      [script_output] = payload_of(shown, "SCRIPT_TASK_COMPLETED")
      assert script_output["output"]["total"] == @placeholder

      [completed] = payload_of(shown, "TASK_COMPLETED")
      assert completed["output_variables"]["total"] == 9

      overwritten =
        Enum.find(completed["merged_variable_events"], &(&1["event"] == "variable_overwritten"))

      assert overwritten["old_value"] == @placeholder
      assert overwritten["new_value"] == 9
    end

    test "(c) with the grant the same history is clear", %{t: t} do
      b = labelled_review!(t)
      complete!(t, b.instance_id, %{"total" => 9})

      shown = history(t, b.instance_id, MapSet.new())

      [script_output] = payload_of(shown, "SCRIPT_TASK_COMPLETED")
      assert script_output["output"]["total"] == 4

      [completed] = payload_of(shown, "TASK_COMPLETED")

      overwritten =
        Enum.find(completed["merged_variable_events"], &(&1["event"] == "variable_overwritten"))

      assert overwritten["old_value"] == 4
      assert overwritten["new_value"] == 9
    end
  end

  describe "SR-OPT-14 computed field read from a labelled variable" do
    test "a completer without the grant sees the server value hidden and the submitted value clear",
         %{t: t} do
      b = labelled_review!(t)
      complete!(t, b.instance_id, %{"y" => 99})

      [completed] = payload_of(history(t, b.instance_id, MapSet.new([@label])), "TASK_COMPLETED")

      disagreement =
        Enum.find(
          completed["merged_variable_events"],
          &(&1["event"] == "computed_field_disagreement")
        )

      assert disagreement["server_value"] == @placeholder
      assert disagreement["submitted_value"] == 99
    end

    test "with the grant both values are clear", %{t: t} do
      b = labelled_review!(t)
      complete!(t, b.instance_id, %{"y" => 99})

      [completed] = payload_of(history(t, b.instance_id, MapSet.new()), "TASK_COMPLETED")

      disagreement =
        Enum.find(
          completed["merged_variable_events"],
          &(&1["event"] == "computed_field_disagreement")
        )

      assert disagreement["server_value"] == 5
      assert disagreement["submitted_value"] == 99
    end

    test "a value submitted for a visible_when: false field is hidden when its stored value is labelled",
         %{t: t} do
      b =
        labelled_script!(t, &graph_with_visible_when/2, %{"total" => 4, "note" => "old"}, %{
          "note" => [@label]
        })

      complete!(t, b.instance_id, %{"note" => "secret"})

      [completed] = payload_of(history(t, b.instance_id, MapSet.new([@label])), "TASK_COMPLETED")

      discarded =
        Enum.find(
          completed["merged_variable_events"],
          &(&1["event"] == "visible_when_false_value_discarded")
        )

      assert discarded["field"] == "note"
      assert discarded["discarded_value"] == @placeholder
    end

    test "with the grant the discarded submission is clear", %{t: t} do
      b =
        labelled_script!(t, &graph_with_visible_when/2, %{"total" => 4, "note" => "old"}, %{
          "note" => [@label]
        })

      complete!(t, b.instance_id, %{"note" => "secret"})

      [completed] = payload_of(history(t, b.instance_id, MapSet.new()), "TASK_COMPLETED")

      discarded =
        Enum.find(
          completed["merged_variable_events"],
          &(&1["event"] == "visible_when_false_value_discarded")
        )

      assert discarded["discarded_value"] == "secret"
    end
  end

  # ---------------------------------------------------------------------------------------------
  # SR-OPT-13 (d): a parent and a sub-process child. The parent's `a` is labelled and its `y` is
  # not. The child computes `y = a + 1` (R14), so its `y` inherits the label of `a`; the merge
  # back into the parent then overwrites the parent's unlabelled `y` with a labelled value.
  # ---------------------------------------------------------------------------------------------

  defp active_definition!(t, graph) do
    attrs = %{
      name: "gh2616-history-sub-#{System.unique_integer([:positive])}",
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: t.schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: t.schema_name)

    activated
  end

  # START -> HUMAN_TASK("worker", computes y = a + 1) -> END
  defp sub_child_graph do
    form = %{
      "type" => "object",
      "properties" => %{
        "a" => %{"type" => "number"},
        "y" => %{"type" => "number", "x-ui" => %{"computed" => "a + 1"}}
      }
    }

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "work",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "worker", "form_schema" => form}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "work"},
        %{"id" => "e2", "source" => "work", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK("gate") -> SUB_PROCESS("sp", the child) -> END
  defp sub_parent_graph(child_name) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gate", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "gater"}},
        %{
          "id" => "sp",
          "node_type" => "SUB_PROCESS",
          "attributes" => %{"definition_name" => child_name}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gate"},
        %{"id" => "e2", "source" => "gate", "target" => "sp"},
        %{"id" => "e3", "source" => "sp", "target" => "end"}
      ]
    }
  end

  # Starts the parent, labels its `a` (the part-1 fixture writes the projection the same way),
  # completes the gate so the child starts, and returns {parent_id, child_id}.
  defp sub_process_pair!(t) do
    child_def = active_definition!(t, sub_child_graph())
    parent_def = active_definition!(t, sub_parent_graph(child_def.name))

    assert {:ok, %{instance_id: parent_id}} =
             Engine.create(
               %{
                 definition_id: parent_def.id,
                 initial_variables: %{"a" => 5, "y" => 7},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: "sub-#{System.unique_integer([:positive])}"
               },
               prefix: t.schema_name
             )

    {1, _} =
      from(p in InstanceProjection, where: p.instance_id == ^parent_id)
      |> Repo.update_all([set: [variable_labels: %{"a" => [@label]}]], prefix: t.schema_name)

    complete!(t, parent_id, %{})

    child =
      InstanceProjection
      |> where([p], p.parent_instance_id == ^parent_id)
      |> Repo.one!(prefix: t.schema_name)

    {parent_id, child.instance_id}
  end

  describe "SR-OPT-13 (d) a value a sub-process child merges back into the parent" do
    test "the SUB_PROCESS_COMPLETED new_value is hidden from a caller without the grant", %{t: t} do
      {parent_id, child_id} = sub_process_pair!(t)
      complete!(t, child_id, %{})

      [sub] = payload_of(history(t, parent_id, MapSet.new([@label])), "SUB_PROCESS_COMPLETED")

      overwritten =
        Enum.find(
          sub["merged_variable_events"],
          &(&1["event"] == "variable_overwritten" and &1["key"] == "y")
        )

      assert overwritten["old_value"] == 7
      assert overwritten["new_value"] == @placeholder
    end

    test "with the grant the same merge is clear", %{t: t} do
      {parent_id, child_id} = sub_process_pair!(t)
      complete!(t, child_id, %{})

      [sub] = payload_of(history(t, parent_id, MapSet.new()), "SUB_PROCESS_COMPLETED")

      overwritten =
        Enum.find(
          sub["merged_variable_events"],
          &(&1["event"] == "variable_overwritten" and &1["key"] == "y")
        )

      assert overwritten["old_value"] == 7
      assert overwritten["new_value"] == 6
    end
  end

  describe "R12 / R8h an EXECUTION_ERROR written by the completion keeps the labels of its variables" do
    test "(e) a key computed by the completion (R14) stays hidden in the error event a completer without the grant reads",
         %{t: t} do
      b = labelled_review!(t, &graph_with_empty_url/2)

      task =
        Repo.one!(
          from(x in Letflow.Engine.Task,
            where: x.instance_id == ^b.instance_id and x.status == :pending
          ),
          prefix: t.schema_name
        )

      completer = Ecto.UUID.generate()

      # The form submits nothing, so `y` is computed from the labelled `total` (R14) and only
      # exists in the post-merge state; the next SERVICE_TASK renders an empty URL.
      assert {:error, {:instance_execution_error, :service_task_url_rendered_empty, _}} =
               Engine.complete_task(
                 task.id,
                 %{output_variables: %{}, actor_id: completer, idempotency_key: "e-#{completer}"},
                 prefix: t.schema_name
               )

      [error] = payload_of(history(t, b.instance_id, MapSet.new([@label])), "EXECUTION_ERROR")

      assert error["variables"]["y"] == @placeholder
      assert error["variables"]["total"] == @placeholder
    end

    test "(f) a computed key stays hidden in the no_matching_edge error a completer without the grant reads",
         %{t: t} do
      b = labelled_review!(t, &graph_with_gateway/2)

      # A definition activated before CHK-24 keeps running without its default edge (REQ-455
      # OQ-1). The instance runs on its own definition snapshot, so overwrite that graph, the way
      # service_task_wiring_test overwrites a legacy definition's stored graph.
      no_default =
        Map.update!(b.definition.graph, "edges", fn edges ->
          Enum.reject(edges, &Map.get(&1, "is_default"))
        end)

      {1, _} =
        from(s in Letflow.Definitions.InstanceDefinitionSnapshot,
          where: s.instance_id == ^b.instance_id
        )
        |> Repo.update_all([set: [graph: no_default]], prefix: t.schema_name)

      task =
        Repo.one!(
          from(x in Letflow.Engine.Task,
            where: x.instance_id == ^b.instance_id and x.status == :pending
          ),
          prefix: t.schema_name
        )

      completer = Ecto.UUID.generate()

      # The form submits nothing, so `y` = total + 1 = 5 exists only in the post-merge state
      # (R14); the gateway condition `y == 1` matches nothing and there is no default edge.
      assert {:error, _} =
               Engine.complete_task(
                 task.id,
                 %{output_variables: %{}, actor_id: completer, idempotency_key: "f-#{completer}"},
                 prefix: t.schema_name
               )

      [error] = payload_of(history(t, b.instance_id, MapSet.new([@label])), "EXECUTION_ERROR")

      assert error["variables"]["y"] == @placeholder
      assert error["variables"]["total"] == @placeholder
    end
  end
end
