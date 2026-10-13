defmodule Letflow.Definitions.VortexProductionOrderReleaseFixtureTest do
  @moduledoc """
  ISS-1000 / Q-982 (PA-VORTEX-001, PA-VORTEX-009 F1): a production order declined at
  capacity-review or budget-approval must end in a `rejected` END node, never in
  `end-released`. The reject branch of capacity-review used to share `notify-planner`
  with the approve path, whose only exit is `end-released`.

  Graph-walk assertions (no hard-coded end ids for the reject side) over both the QA
  fixture and the simulation copy. Pure: read-only file I/O, no DB, no HTTP.
  See `test/specs/ISS-1000.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SemanticValidation

  @root Path.expand("../../..", __DIR__)
  @qa Path.join(
        @root,
        "test/fixtures/qa/vortex_production_order_release_process_definition.json"
      )
  @sim Path.join(@root, "test/fixtures/simulation/vortex/process_quality_check.yaml")

  defp qa_doc, do: @qa |> File.read!() |> Jason.decode!()
  defp sim_doc, do: YamlElixir.read_from_file!(@sim)

  defp docs, do: [{"qa fixture", qa_doc()}, {"simulation copy", sim_doc()}]

  defp nodes(doc), do: Map.new(doc["graph"]["nodes"], &{&1["id"], &1})
  defp edges(doc), do: doc["graph"]["edges"]

  defp reject_edges(doc, source) do
    Enum.filter(edges(doc), fn e ->
      e["source"] == source and is_binary(e["condition"]) and
        String.contains?(e["condition"], "'reject'")
    end)
  end

  # every node id reachable from `start_ids` (inclusive)
  defp reachable(doc, start_ids), do: walk(edges(doc), start_ids, MapSet.new())

  defp walk(_edges, [], seen), do: seen

  defp walk(edges, [id | rest], seen) do
    if MapSet.member?(seen, id) do
      walk(edges, rest, seen)
    else
      next = for e <- edges, e["source"] == id, do: e["target"]
      walk(edges, next ++ rest, MapSet.put(seen, id))
    end
  end

  defp end_ids(doc, ids) do
    by_id = nodes(doc)
    Enum.filter(ids, &(by_id[&1]["node_type"] == "END"))
  end

  test "fixture version is 1.7 (1.7 = REQ-466 distinct_from; 1.6 = REQ-462 required_outputs; 1.4 = ISS-1027 variable_schemas; 1.5 = ISS-1002 D-ESC timers; forces QA re-seed)" do
    assert qa_doc()["version"] == "1.7"
  end

  for {label, key} <- [{"qa fixture", :qa}, {"simulation copy", :sim}] do
    describe label do
      setup do
        {:ok, doc: if(unquote(key) == :qa, do: qa_doc(), else: sim_doc())}
      end

      test "everything reachable from a capacity-review / budget-approval reject edge ends only in a 'rejected' END",
           %{doc: doc} do
        for source <- ["capacity-review", "budget-approval"] do
          rejects = reject_edges(doc, source)
          assert rejects != [], "no reject edge found on #{source}"

          reach = reachable(doc, Enum.map(rejects, & &1["target"]))
          ends = end_ids(doc, reach)

          assert ends != [], "reject path of #{source} reaches no END"
          refute "end-released" in reach, "reject path of #{source} reaches end-released"

          for id <- ends do
            assert String.contains?(id, "rejected"),
                   "reject path of #{source} reaches END #{id}"
          end
        end
      end

      test "capacity-review reject notifies the planner before the rejected end", %{doc: doc} do
        by_id = nodes(doc)
        [reject | _] = reject_edges(doc, "capacity-review")
        reach = reachable(doc, [reject["target"]])

        assert Enum.any?(reach, fn id ->
                 n = by_id[id]

                 n["node_type"] == "SERVICE_TASK" and
                   String.contains?(n["attributes"]["endpoint"], "/webhooks/notify")
               end)
      end

      test "approve path still reaches end-released via budget-gate and assign-line", %{doc: doc} do
        [approve] =
          Enum.filter(edges(doc), fn e ->
            e["source"] == "capacity-review" and
              e["condition"] == "variables.capacity_decision == 'approve'"
          end)

        reach = reachable(doc, [approve["target"]])
        assert approve["target"] == "budget-gate"
        assert "assign-line" in reach
        assert "notify-planner" in reach
        assert "end-released" in reach
      end
    end
  end

  test "the simulation copy carries the same reject branch as the QA fixture" do
    branch = fn doc ->
      e2 = Enum.find(edges(doc), &(&1["id"] == "e2"))
      e12 = Enum.find(edges(doc), &(&1["id"] == "e12"))
      {e2["target"], e2["condition"], e12["source"], e12["target"]}
    end

    assert branch.(qa_doc()) == branch.(sim_doc())

    assert branch.(qa_doc()) ==
             {"notify-planner-rejected", "variables.capacity_decision == 'reject'",
              "notify-planner-rejected", "end-rejected"}
  end

  test "criterion 4: swiftroute, meridian and vortex all end a rejected decision in a rejected/declined END" do
    fixtures = %{
      "swiftroute" => "test/fixtures/qa/swiftroute_process_definition.json",
      "meridian" => "test/fixtures/qa/meridian_loan_origination_process_definition.json",
      "vortex" => "test/fixtures/qa/vortex_production_order_release_process_definition.json"
    }

    for {company, rel} <- fixtures do
      doc = @root |> Path.join(rel) |> File.read!() |> Jason.decode!()

      targets =
        for e <- edges(doc),
            is_binary(e["condition"]),
            String.contains?(e["condition"], "'reject'"),
            do: e["target"]

      assert targets != [], "#{company}: no reject edge found"

      ends = end_ids(doc, MapSet.to_list(reachable(doc, targets)))
      assert ends != [], "#{company}: reject path reaches no END"

      for id <- ends do
        assert id =~ ~r/rejected|declined/, "#{company}: reject path reaches END #{id}"
      end
    end

    # the three companies' reject END ids, verified against the fixtures
    ends_of = fn rel ->
      doc = @root |> Path.join(rel) |> File.read!() |> Jason.decode!()

      for {id, %{"node_type" => "END"}} <- nodes(doc), id =~ ~r/rejected|declined/, do: id
    end

    assert ends_of.(fixtures["swiftroute"]) == ["end-rejected"]
    assert ends_of.(fixtures["meridian"]) == ["end-declined"]
    assert ends_of.(fixtures["vortex"]) == ["end-rejected"]
  end

  # REQ-462: check 2 (required_output_without_variable_schema) needs the definition's own
  # registered variable_schemas, as at validate/activate.
  defp declared_fields(doc) do
    Map.new(doc["variable_schemas"] || [], &{&1["variable_key"], &1["json_schema"]})
  end

  test "the validators report zero violations for both copies" do
    for {label, doc} <- docs() do
      assert {:ok, graph} = Graph.from_map(doc["graph"])

      violations =
        Graph.validate_graph(graph).violations ++
          Graph.validate_node_attributes(graph).violations ++
          Graph.validate_edge_conditions(graph).violations ++
          Graph.validate_flow(graph).violations ++
          SemanticValidation.validate(graph, declared_fields(doc)).violations

      assert violations == [], "#{label}: #{inspect(violations)}"
    end
  end
end
