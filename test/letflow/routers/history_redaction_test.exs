defmodule Letflow.Routers.HistoryRedactionTest do
  @moduledoc """
  SR-OPT-13 and SR-OPT-14 (decision 0062 R8h-3, R14, GH #2616 part 2): the history of an instance
  shows the placeholder for a value its stored event labels hide from the caller, and the clear
  value to a caller who may read it. The labels come from the event payload itself, never from the
  projection (R8h). The history item shaping is `Response.public_event_payload/3`, the function the
  history route calls for each stored event.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Response
  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.EventStore
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
  end
end
