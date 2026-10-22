defmodule Letflow.Engine.VariableLabelsReplayTest do
  @moduledoc """
  SR-OPT-6 (decision 0062, GH #2616 part 1): per-variable restriction labels are stored in
  `instance_projections.variable_labels` by `VariableMerge.merge/5` alone, carried by the apply
  event, rebuilt by replay and kept by snapshots.

  Part 1 has no production source of a non-empty label (the C10 refusal stays), so the label
  enters through the one seam part 3 will use: `facts.output_labels` of a script result.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine
  alias Letflow.Engine.Reconstruction
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Engine.SnapshotWriter
  alias Letflow.Support.ScriptTaskFixture, as: F

  @labels %{"total" => ["customer.salary"]}

  setup do
    %{t: F.tenant!("gh2616-labels")}
  end

  # START -> svc (script) -> review (HUMAN_TASK) -> END
  defp script_then_human_graph(key, version) do
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

  defp labelled_result(row, output, labels) do
    {:ok, output,
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
  end

  # Starts an instance whose script task has applied `total = 4` carrying `labels`.
  defp labelled_instance!(t, labels \\ @labels) do
    b =
      F.bound_graph!(
        t,
        F.doubling_source(),
        F.closed_manifest(),
        %{"amount" => 2},
        &script_then_human_graph/2,
        []
      )

    {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)

    assert {:ok, :applied} =
             Engine.apply_script_task_result(
               F.claim(row),
               labelled_result(row, %{"total" => 4}, labels),
               t.schema_name
             )

    b
  end

  defp replayed(t, instance_id) do
    assert {:ok, %{instance_state: state}} =
             Reconstruction.reconstruct_instance(instance_id, prefix: t.schema_name)

    state
  end

  defp complete_review!(t, instance_id, output) do
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
                 idempotency_key: "ct-#{completer}"
               },
               prefix: t.schema_name
             )
  end

  describe "SR-OPT-6" do
    test "(a) the apply stores the labels in the projection and records output_labels", %{t: t} do
      b = labelled_instance!(t)

      assert F.projection(t.schema_name, b.instance_id).variable_labels == @labels
      assert F.projection(t.schema_name, b.instance_id).variables["total"] == 4

      assert [%{"output_labels" => @labels, "output" => %{"total" => 4}}] =
               F.payloads(t.schema_name, b.instance_id, "SCRIPT_TASK_COMPLETED")
    end

    test "T-6: with no labels no event payload carries a label field", %{t: t} do
      b =
        F.bound_graph!(
          t,
          F.doubling_source(),
          F.closed_manifest(),
          %{"amount" => 2},
          &script_then_human_graph/2,
          []
        )

      assert {_row, {:ok, :applied}} = F.run_next!(t.schema_name)
      complete_review!(t, b.instance_id, %{"total" => 5})

      types = F.event_types(t.schema_name, b.instance_id)
      assert "INSTANCE_STARTED" in types and "SCRIPT_TASK_COMPLETED" in types
      assert "TASK_COMPLETED" in types

      for type <- Enum.uniq(types), payload <- F.payloads(t.schema_name, b.instance_id, type) do
        encoded = Jason.encode!(payload)
        refute encoded =~ "_labels", "#{type} payload carries a label field"
        refute Map.has_key?(payload, "labels"), "#{type} payload carries labels"
      end

      assert F.projection(t.schema_name, b.instance_id).variable_labels == %{}
    end

    test "(a') a script output without labels writes no label field and no entry", %{t: t} do
      b = F.bound!(t, F.doubling_source(), F.closed_manifest(), %{"amount" => 2})
      assert {_row, {:ok, :applied}} = F.run_next!(t.schema_name)

      assert F.projection(t.schema_name, b.instance_id).variable_labels == %{}
      assert [payload] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_TASK_COMPLETED")
      refute Map.has_key?(payload, "output_labels")
    end

    test "(b) replay rebuilds the projection's labels", %{t: t} do
      b = labelled_instance!(t)
      state = replayed(t, b.instance_id)

      assert state.variable_labels == F.projection(t.schema_name, b.instance_id).variable_labels
      assert state.variable_labels == @labels
      assert state.variables == F.projection(t.schema_name, b.instance_id).variables
    end

    test "(c) a later unlabelled overwrite removes the entry, records old_labels, replay agrees",
         %{t: t} do
      b = labelled_instance!(t)
      complete_review!(t, b.instance_id, %{"total" => 99})

      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.variables["total"] == 99
      assert projection.variable_labels == %{}

      assert [completed] = F.payloads(t.schema_name, b.instance_id, "TASK_COMPLETED")

      assert [overwritten] = completed["merged_variable_events"]
      assert overwritten["event"] == "variable_overwritten"
      assert overwritten["old_labels"] == ["customer.salary"]
      refute Map.has_key?(overwritten, "new_labels")
      refute Map.has_key?(completed, "output_labels")

      state = replayed(t, b.instance_id)
      assert state.variable_labels == %{}
      assert state.variables == projection.variables
    end

    test "(d) an EXECUTION_ERROR after a labelled write carries labels and replay sets them",
         %{t: t} do
      b = labelled_instance!(t)

      assert {:ok, %{status: :error}} =
               Engine.set_instance_error(
                 %{
                   instance_id: b.instance_id,
                   error_type: :variable_schema_rejected,
                   affected: {:node, "review"},
                   reason: "labelled error",
                   variables: F.projection(t.schema_name, b.instance_id).variables,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: "err-#{b.instance_id}"
                 },
                 prefix: t.schema_name
               )

      assert [%{"labels" => @labels}] =
               F.payloads(t.schema_name, b.instance_id, "EXECUTION_ERROR")

      state = replayed(t, b.instance_id)
      assert state.status == :error
      assert state.variable_labels == @labels
    end

    test "(e) a snapshot round-trip keeps the labels; an old snapshot map reads as no labels",
         %{t: t} do
      b = labelled_instance!(t)
      state = replayed(t, b.instance_id)
      assert state.variable_labels == @labels

      assert {:ok, _id} =
               SnapshotWriter.take_snapshot(b.instance_id, state, 99, prefix: t.schema_name)

      assert {:ok, {restored, 99}} =
               SnapshotWriter.latest_snapshot(b.instance_id, prefix: t.schema_name)

      assert restored.variable_labels == @labels
      assert restored.variables == state.variables

      # a snapshot written before decision 0062 has no "variable_labels" key
      from(s in Letflow.Engine.InstanceStateSnapshot,
        where: s.instance_id == ^b.instance_id and s.sequence_number == 99
      )
      |> Repo.update_all(
        [set: [state: Map.delete(serialized_state(t, b.instance_id), "variable_labels")]],
        prefix: t.schema_name
      )

      assert {:ok, {old, 99}} =
               SnapshotWriter.latest_snapshot(b.instance_id, prefix: t.schema_name)

      assert old.variable_labels == %{}
    end
  end

  defp serialized_state(t, instance_id) do
    Repo.one!(
      from(s in Letflow.Engine.InstanceStateSnapshot,
        where: s.instance_id == ^instance_id and s.sequence_number == 99,
        select: s.state
      ),
      prefix: t.schema_name
    )
  end
end
