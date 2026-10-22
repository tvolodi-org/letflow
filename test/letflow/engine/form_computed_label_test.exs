defmodule Letflow.Engine.FormComputedLabelTest do
  @moduledoc """
  SR-OPT-7 (decision 0062 R14, GH #2616 part 2): a form computed field carries the union of the
  labels of the variables it reads, in topological order, so a computed-on-computed field inherits
  through its input in one completion. A submission that overwrites a source key unlabels that key
  (R9), and the computed fields that read it lose the label. A submitted value for a computed field
  never wins: the server value is stored and the disagreement event names the stored label.

  The labelled source `total` is produced through the script-result seam (part 1's
  `apply_script_task_result` with `output_labels`), because no production path labels a variable yet.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Support.ScriptTaskFixture, as: F

  @label "customer.salary"

  @form %{
    "type" => "object",
    "properties" => %{
      "total" => %{"type" => "number"},
      "y" => %{"type" => "number", "x-ui" => %{"computed" => "total + 1"}},
      "z" => %{"type" => "number", "x-ui" => %{"computed" => "y * 2"}}
    }
  }

  setup do
    %{t: F.tenant!("gh2616-form")}
  end

  # START -> svc (script) -> review (HUMAN_TASK with the computed form) -> END
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

  # An instance whose `total` (4) is labelled, with the computed review task pending.
  defp labelled_review!(t) do
    b =
      F.bound_graph!(
        t,
        F.doubling_source(),
        F.closed_manifest(),
        %{"amount" => 2},
        &graph/2,
        []
      )

    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)

    result =
      {:ok, %{"total" => 4},
       %{
         row: row,
         phase: :ran,
         outcome: :ok,
         detail: nil,
         fail_code: nil,
         hmac: nil,
         stats: nil,
         output_labels: %{"total" => [@label]}
       }}

    assert {:ok, :applied} = Engine.apply_script_task_result(F.claim(row), result, t.schema_name)
    b
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
                 idempotency_key: "fl-#{completer}"
               },
               prefix: t.schema_name
             )
  end

  describe "SR-OPT-7" do
    test "(a) a computed field that reads a labelled source is labelled with its label", %{t: t} do
      b = labelled_review!(t)

      complete!(t, b.instance_id, %{})

      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.variables["y"] == 5
      assert projection.variable_labels["y"] == [@label]
    end

    test "(b) computed-on-computed: z inherits the source label through y in one completion", %{
      t: t
    } do
      b = labelled_review!(t)

      complete!(t, b.instance_id, %{})

      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.variables["z"] == 10
      assert projection.variable_labels["z"] == [@label]
    end

    test "(c) a submission that overwrites the source unlabels it and the fields that read it", %{
      t: t
    } do
      b = labelled_review!(t)

      complete!(t, b.instance_id, %{"total" => 9})

      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.variables["total"] == 9
      assert projection.variables["y"] == 10
      refute Map.has_key?(projection.variable_labels, "total")
      refute Map.has_key?(projection.variable_labels, "y")
      refute Map.has_key?(projection.variable_labels, "z")
    end

    test "(d) a submitted value for a computed field loses to the server value; the event keeps the stored label",
         %{t: t} do
      b = labelled_review!(t)

      complete!(t, b.instance_id, %{"y" => 99})

      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.variables["y"] == 5
      assert projection.variable_labels["y"] == [@label]

      disagreement =
        t.schema_name
        |> then(fn schema -> F.payloads(schema, b.instance_id, "TASK_COMPLETED") end)
        |> List.flatten()
        |> Enum.flat_map(&Map.get(&1, "merged_variable_events", []))
        |> Enum.find(&(&1["event"] == "computed_field_disagreement"))

      assert disagreement["field"] == "y"
      assert disagreement["submitted_value"] == 99
      assert disagreement["server_value"] == 5
      assert disagreement["server_labels"] == [@label]
      refute Map.has_key?(disagreement, "submitted_labels")
    end
  end
end
