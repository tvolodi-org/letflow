defmodule Letflow.Scripts.Req465MeridianDistinctFromFixtureTest do
  @moduledoc """
  REQ-465 -- the two shipped Meridian QA fixtures carry `distinct_from` on exactly the approve,
  pay and commit nodes listed in the requirement's table, and nothing else. Pins the node set and
  the listed ids, the version bumps (loan 1.13 -> 1.14, then 1.14 -> 1.15 under Q-1048 / GH #2390;
  regulatory 1.9 -> 1.10) and that each
  description says why, and runs the REQ-464 checks over both definitions: zero violations and
  zero same-role candidate pairs.

  Pure: no DB, no HTTP. The checks run through the same Graph, SemanticValidation and RoleBinding
  functions `Letflow.Definitions.validate_definition_graph/2` calls. The refusal behaviour is in
  `test/letflow/engine/req465_meridian_*_distinct_from_test.exs`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.RoleBinding
  alias Letflow.Definitions.SemanticValidation

  @qa Path.expand("../../fixtures/qa", __DIR__)
  @loan "meridian_loan_origination_process_definition.json"
  @regulatory "meridian_regulatory_compliance_review_process_definition.json"

  # node id => the listed distinct_from ids, exactly as the requirement's table records them.
  @expected %{
    @loan => %{
      "l2-approval" => ["l1-approval"],
      "escalate-l2-approval-to-ceo" => ["l1-approval"],
      "committee-vote-cro" => ["committee-vote-director", "committee-vote-ceo"],
      "committee-vote-director" => ["committee-vote-cro", "committee-vote-ceo"],
      "committee-vote-ceo" => ["committee-vote-cro", "committee-vote-director"],
      "disburse-loan" => [
        "l1-approval",
        "l2-approval",
        "escalate-l2-approval-to-ceo",
        "committee-vote-cro",
        "committee-vote-director",
        "committee-vote-ceo"
      ],
      # Q-1048 / GH #2390 closes the REQ-465 residual: the node now routes to role-loan-ops-lead, which
      # no approval node holds, so the two same-role approvals (l2-approval and committee-vote-director,
      # both role-credit-director) can be named without a same-role pair. All six approval nodes listed.
      "escalate-disburse-loan-to-loan-ops-lead" => [
        "l1-approval",
        "l2-approval",
        "escalate-l2-approval-to-ceo",
        "committee-vote-cro",
        "committee-vote-director",
        "committee-vote-ceo"
      ]
    },
    @regulatory => %{
      "findings-sign-off" => ["evidence-collection", "risk-evaluation", "remediation-subprocess"],
      "ceo-override" => [
        "evidence-collection",
        "risk-evaluation",
        "remediation-subprocess",
        "findings-sign-off"
      ]
    }
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
    for file <- [@loan, @regulatory] do
      assert distinct_from_by_node(file) == Map.fetch!(@expected, file), file
    end
  end

  test "every listed node is a HUMAN_TASK, and the listed ids are HUMAN_TASKs of the same definition" do
    for file <- [@loan, @regulatory] do
      nodes = doc(file)["graph"]["nodes"]
      types = Map.new(nodes, &{&1["id"], &1["node_type"]})

      for {node_id, listed} <- Map.fetch!(@expected, file), other <- [node_id | listed] do
        assert types[other] == "HUMAN_TASK", "#{file}: #{other} is not a HUMAN_TASK"
      end
    end
  end

  test "versions: loan is 1.15 (from 1.14, Q-1048) and regulatory is 1.10 (from 1.9); each description says why (REQ-465 / Q-1048)" do
    assert doc(@loan)["version"] == "1.15"
    assert doc(@regulatory)["version"] == "1.10"
    assert doc(@loan)["description"] =~ "Q-1048"
    assert doc(@loan)["description"] =~ "REQ-465"
    assert doc(@regulatory)["description"] =~ "REQ-465"
  end

  test "REQ-464 checks: zero violations per changed definition (the validate_definition_graph/2 checks, pure)" do
    for file <- [@loan, @regulatory] do
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
    for file <- [@loan, @regulatory] do
      assert RoleBinding.single_member_pairs(graph!(file)) == [], file
    end
  end
end
