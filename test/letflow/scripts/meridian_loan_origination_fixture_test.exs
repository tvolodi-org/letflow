defmodule Letflow.Scripts.MeridianLoanOriginationFixtureTest do
  @moduledoc """
  ISS-0928 / Q-928 T8 -- the QA Meridian "Loan Origination" fixture must give the
  `kyc-routing` EXCLUSIVE_GATEWAY an unconditioned default edge, so a KYC stub
  response with no `kyc_status` key does not stall (ISS-0998: it now goes to `kyc-manual-review`, not `assessment-join`) instead of
  erroring (or, pre-fix, stalling) the instance. The version was bumped to 1.2 (ISS-0928; now 1.8: ISS-0998 changed the kyc default edge target to kyc-manual-review; ISS-1001 the l2-approval fallback to decline-application; ISS-1020 the KYC outcome gate; ISS-1024 the three distinct committee-vote roles, see meridian_loan_kyc_fail_closed_fixture_test.exs) so
  `scripts/seed_meridian_definition.sh` re-seeds QA (409 means bump, never delete).

  Pure: no DB, no HTTP. See `test/specs/ISS-0928.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph

  @fixture Path.expand(
             "../../fixtures/qa/meridian_loan_origination_process_definition.json",
             __DIR__
           )

  defp doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp kyc_routing_edges(document),
    do: Enum.filter(document["graph"]["edges"], &(&1["source"] == "kyc-routing"))

  defp graph!(document) do
    assert {:ok, graph} = Graph.from_map(document["graph"])
    graph
  end

  test "fixture version is 1.14 (REQ-465 distinct_from; 1.13 was REQ-462 required_outputs; 1.12 was ISS-1013: D-ESC timers; 1.9 was ISS-1015: timeouts route to escalation reviews, human tasks carry forms; 1.8 was ISS-1024: committee votes route to three distinct roles; 1.7 was ISS-1020, the KYC fail-closed gate; 1.6 was ISS-1001, 1.5 ISS-0998)" do
    assert doc()["version"] == "1.14"
  end

  # --- ISS-1001 / Q-983: l2-approval fails toward scrutiny, never to create-facility ---

  defp edges_from(document, source),
    do: Enum.filter(document["graph"]["edges"], &(&1["source"] == source))

  # Nodes reachable from `start` following only edges that can fire under `variables`:
  # unconditioned edges, `is_default` edges and edges whose condition the real engine
  # evaluator (`Letflow.Engine.Expr.evaluate_condition/2`) holds true. Over-approximates
  # (a default edge is followed even if a sibling condition holds), which is the safe
  # direction for a "never reaches" assertion.
  defp reachable(document, start, variables) do
    walk(document, [start], MapSet.new([start]), variables)
  end

  defp walk(_document, [], seen, _variables), do: seen

  defp walk(document, [node | rest], seen, variables) do
    next =
      for edge <- edges_from(document, node),
          is_nil(edge["condition"]) or
            Letflow.Engine.Expr.evaluate_condition(edge["condition"], variables),
          edge["target"] not in seen,
          do: edge["target"]

    next = Enum.uniq(next)
    walk(document, rest ++ next, Enum.into(next, seen), variables)
  end

  test "ISS-1001 / ISS-1013: fallback-l2-approval targets the CEO escalation task, whose own fallback is decline-application (never create-facility)" do
    l2_edges = edges_from(doc(), "l2-approval")

    assert %{"target" => "escalate-l2-approval-to-ceo"} =
             fallback = Enum.find(l2_edges, &(&1["id"] == "fallback-l2-approval"))

    refute Map.has_key?(fallback, "condition")

    # exactly one edge from l2-approval reaches create-facility: the explicit 'approve'
    assert [%{"id" => "e21", "condition" => "variables.l2_decision == 'approve'"}] =
             Enum.filter(l2_edges, &(&1["target"] == "create-facility"))

    esc_edges = edges_from(doc(), "escalate-l2-approval-to-ceo")

    assert %{"target" => "decline-application"} =
             stalled = Enum.find(esc_edges, &(&1["id"] == "timeout-escalate-l2-approval-to-ceo"))

    refute Map.has_key?(stalled, "condition")

    assert [%{"id" => "e21-escalated", "condition" => "variables.l2_decision == 'approve'"}] =
             Enum.filter(esc_edges, &(&1["target"] == "create-facility"))
  end

  test "ISS-1001: fallback-l1-approval -> l2-approval is unchanged (escalation = more scrutiny)" do
    assert [%{"id" => "fallback-l1-approval", "target" => "l2-approval"} = edge] =
             Enum.filter(edges_from(doc(), "l1-approval"), &(&1["id"] == "fallback-l1-approval"))

    refute Map.has_key?(edge, "condition")
  end

  test "ISS-1001: an instance at l2-approval with a missing or unrecognised l2_decision never reaches create-facility" do
    for variables <- [
          %{},
          %{"l2_decision" => nil},
          %{"l2_decision" => "maybe"},
          %{"l2_decision" => "APPROVE"},
          %{"l2_decision" => ""},
          %{"l2_decision" => "timeout"}
        ] do
      reached = reachable(doc(), "l2-approval", variables)

      refute "create-facility" in reached, "reached create-facility with #{inspect(variables)}"
      refute "disburse-loan" in reached
      assert "decline-application" in reached
      assert "end-declined" in reached
    end
  end

  test "ISS-1001: the same walk does reach create-facility on an explicit l2_decision 'approve' (the walk is not vacuous)" do
    assert "create-facility" in reachable(doc(), "l2-approval", %{"l2_decision" => "approve"})
    refute "create-facility" in reachable(doc(), "l2-approval", %{"l2_decision" => "reject"})
  end

  test "ISS-0998: kyc-routing has exactly one default edge, to kyc-manual-review (fail toward scrutiny), carrying no condition" do
    defaults = Enum.filter(kyc_routing_edges(doc()), &(&1["is_default"] == true))

    assert [%{"id" => "e9-default", "target" => "kyc-manual-review"} = default_edge] = defaults
    refute Map.has_key?(default_edge, "condition")
  end

  test "ISS-0998: the kyc-aml-check stub endpoint answers kyc_status=clear (httpbin /response-headers echoes the query as JSON keys)" do
    node = Enum.find(doc()["graph"]["nodes"], &(&1["id"] == "kyc-aml-check"))
    uri = URI.parse(node["attributes"]["endpoint"])

    assert uri.host == "httpbin.org"
    assert uri.path == "/response-headers"
    assert URI.decode_query(uri.query) == %{"kyc_status" => "clear"}
  end

  test "the explicit kyc_status routes are unchanged (clear -> join; hit/inconclusive -> manual review)" do
    by_id = Map.new(kyc_routing_edges(doc()), &{&1["id"], &1})

    assert %{"target" => "assessment-join", "condition" => "variables.kyc_status == 'clear'"} =
             by_id["e9"]

    assert %{"target" => "kyc-manual-review", "condition" => "variables.kyc_status == 'hit'"} =
             by_id["e10"]

    assert %{
             "target" => "kyc-manual-review",
             "condition" => "variables.kyc_status == 'inconclusive'"
           } = by_id["e11"]
  end

  test "every non-default kyc-routing edge is conditioned (CHK-13 would otherwise fire)" do
    for edge <- kyc_routing_edges(doc()), edge["is_default"] != true do
      assert is_binary(edge["condition"]) and String.trim(edge["condition"]) != ""
    end
  end

  test "the graph validates clean through Graph (structure, node attributes, edge conditions)" do
    graph = graph!(doc())

    assert %{valid: true, violations: []} = Graph.validate_graph(graph)
    assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
    assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
  end
end
