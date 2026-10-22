defmodule Letflow.Engine.CompleteTaskRedactedSentinelTest do
  @moduledoc """
  GH #2616 part 2, ruling on decision 0062 R8/R9: a form that round-trips the redaction placeholder
  for a restricted variable must not overwrite the stored value with the literal string. The router
  passes the caller's hidden label set as `:hidden_labels`; the engine refuses, under the instance
  lock and before any write, a submitted placeholder for a key whose stored labels are hidden from
  the caller (422 `redacted_value_submitted`, key names only). A real value is accepted (R9: the
  write removes the label). Omitting the key keeps the stored value. Callers that pass no
  `:hidden_labels` (scripts, timers) are not checked.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Support.ScriptTaskFixture, as: F

  @label "customer.salary"
  @placeholder "__field_redacted__"

  setup do
    %{t: F.tenant!("gh2616-ruling")}
  end

  # START -> svc (script: total = 4, labelled) -> review (HUMAN_TASK) -> END
  defp graph(key, version) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"script_key" => key, "script_version" => version}
        },
        %{"id" => "review", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "REVIEWER"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "review"},
        %{"id" => "e3", "source" => "review", "target" => "end"}
      ]
    }
  end

  defp labelled_review!(t) do
    b =
      F.bound_graph!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2}, &graph/2, [])

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

  defp complete(t, instance_id, output, opts) do
    task =
      Repo.one!(
        from(x in Letflow.Engine.Task,
          where: x.instance_id == ^instance_id and x.status == :pending
        ),
        prefix: t.schema_name
      )

    completer = Ecto.UUID.generate()

    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: completer, idempotency_key: "rs-#{completer}"},
      Keyword.put(opts, :prefix, t.schema_name)
    )
  end

  test "the placeholder for a key the caller cannot read is refused; nothing is written", %{t: t} do
    b = labelled_review!(t)
    hidden = MapSet.new([@label])

    assert {:error, {:redacted_value_submitted, ["total"]}} =
             complete(t, b.instance_id, %{"total" => @placeholder}, hidden_labels: hidden)

    projection = F.projection(t.schema_name, b.instance_id)
    assert projection.variables["total"] == 4
    assert projection.variable_labels["total"] == [@label]
    assert F.payloads(t.schema_name, b.instance_id, "TASK_COMPLETED") == []
  end

  test "a real value for a key the caller cannot read is accepted and removes the label (R9)", %{
    t: t
  } do
    b = labelled_review!(t)

    assert {:ok, _} =
             complete(t, b.instance_id, %{"total" => 7}, hidden_labels: MapSet.new([@label]))

    projection = F.projection(t.schema_name, b.instance_id)
    assert projection.variables["total"] == 7
    refute Map.has_key?(projection.variable_labels, "total")
  end

  test "omitting the key keeps the stored value and its label", %{t: t} do
    b = labelled_review!(t)

    assert {:ok, _} = complete(t, b.instance_id, %{}, hidden_labels: MapSet.new([@label]))

    projection = F.projection(t.schema_name, b.instance_id)
    assert projection.variables["total"] == 4
    assert projection.variable_labels["total"] == [@label]
  end

  test "a caller who can read the labelled key may submit the placeholder string as data", %{t: t} do
    b = labelled_review!(t)

    assert {:ok, _} =
             complete(t, b.instance_id, %{"total" => @placeholder}, hidden_labels: MapSet.new())

    projection = F.projection(t.schema_name, b.instance_id)
    assert projection.variables["total"] == @placeholder
    refute Map.has_key?(projection.variable_labels, "total")
  end

  test "a caller that passes no hidden set (a non-router caller) is not checked", %{t: t} do
    b = labelled_review!(t)

    assert {:ok, _} = complete(t, b.instance_id, %{"total" => @placeholder}, [])

    assert F.projection(t.schema_name, b.instance_id).variables["total"] == @placeholder
  end
end
