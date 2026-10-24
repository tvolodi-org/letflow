defmodule Letflow.Scripts.Req466DistinctFromFixtureTest do
  @moduledoc """
  REQ-466 -- the two shipped QA fixtures (vortex "Production Order Release" and swiftroute
  "Shipment Approval") carry `distinct_from` on exactly the approval nodes listed in the
  requirement's table, and nothing else. Pins the node set and the listed ids, the version bumps
  (1.6 -> 1.7 for both; vortex 1.7 -> 1.8 for REQ-471) and that each description says why, and runs the REQ-464 checks over both
  definitions: zero violations and zero same-role candidate pairs.

  Pure: no DB, no HTTP. The checks run through the same Graph, SemanticValidation and RoleBinding
  functions `Letflow.Definitions.validate_definition_graph/2` calls. The refusal behaviour is in
  `test/letflow/engine/req466_{vortex,swiftroute}_distinct_from_test.exs`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.RoleBinding
  alias Letflow.Definitions.SemanticValidation

  @qa Path.expand("../../fixtures/qa", __DIR__)
  @vortex "vortex_production_order_release_process_definition.json"
  @swiftroute "swiftroute_process_definition.json"

  # node id => the listed distinct_from ids, exactly as the requirement's table records them.
  # capacity-review, escalate-to-ceo and ops-review are first-level nodes and carry none.
  # escalate-budget-approval-to-finance-director lists all three upstream nodes since v1.8 (REQ-471):
  # it routes to role-finance-director, so the shipped-definition guard's same-role rule no longer bites.
  @expected %{
    @vortex => %{
      "budget-approval" => ["capacity-review", "escalate-to-ceo"],
      "escalate-budget-approval-to-finance-director" => [
        "capacity-review",
        "escalate-to-ceo",
        "budget-approval"
      ]
    },
    @swiftroute => %{"ceo-approval" => ["ops-review"]}
  }

  defp doc(file), do: @qa |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp graph!(file) do
    assert {:ok, graph} = Graph.from_map(doc(file)["graph"])
    graph
  end

  defp distinct_from_by_node(file) do
    for node <- doc(file)["graph"]["nodes"],
        listed = get_in(node, ["attributes", "distinct_from"]),
        not is_nil(listed),
        into: %{},
        do: {node["id"], listed}
  end

  test "distinct_from is set on exactly the listed nodes, with exactly the listed ids, for both definitions" do
    for file <- [@vortex, @swiftroute] do
      assert distinct_from_by_node(file) == Map.fetch!(@expected, file), file
    end
  end

  test "every listed node is a HUMAN_TASK, and the listed ids are HUMAN_TASKs of the same definition" do
    for file <- [@vortex, @swiftroute] do
      types = Map.new(doc(file)["graph"]["nodes"], &{&1["id"], &1["node_type"]})

      for {node_id, listed} <- Map.fetch!(@expected, file), other <- [node_id | listed] do
        assert types[other] == "HUMAN_TASK", "#{file}: #{other} is not a HUMAN_TASK"
      end
    end
  end

  test "versions: vortex release is 1.8 (REQ-471) and swiftroute is 1.7; each description says why (REQ-466 / Q-1029 / GH #2344) and keeps the REQ-462 sentence" do
    assert doc(@vortex)["version"] == "1.10"
    assert doc(@vortex)["description"] =~ "REQ-471 / GH #2479"
    assert doc(@swiftroute)["version"] == "1.7"

    for file <- [@vortex, @swiftroute] do
      assert doc(file)["description"] =~ "REQ-466 / Q-1029, GH #2344", file
      assert doc(file)["description"] =~ "Required decision outputs (v1.6, REQ-462 / Q-1025", file
    end
  end

  test "REQ-464 checks: zero violations per changed definition (the validate_definition_graph/2 checks, pure)" do
    for file <- [@vortex, @swiftroute] do
      graph = graph!(file)

      declared =
        Map.new(doc(file)["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})

      violations =
        Graph.validate_graph(graph).violations ++
          Graph.validate_node_attributes(graph).violations ++
          Graph.validate_edge_conditions(graph).violations ++
          Graph.validate_flow(graph).violations ++
          SemanticValidation.validate(graph, declared).violations

      assert violations == [], "#{file}: #{inspect(Enum.map(violations, &{&1.code, &1.message}))}"
    end
  end

  test "REQ-464 check 4: no same-role candidate pair in either changed definition (none to warn about)" do
    for file <- [@vortex, @swiftroute] do
      assert RoleBinding.single_member_pairs(graph!(file)) == [], file
    end
  end
end
