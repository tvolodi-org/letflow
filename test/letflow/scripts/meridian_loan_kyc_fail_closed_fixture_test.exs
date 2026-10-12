defmodule Letflow.Scripts.MeridianLoanKycFailClosedFixtureTest do
  @moduledoc """
  ISS-1020 / Q-1002 (GH #2289) -- the QA Meridian "Loan Origination" fixture (v1.7, now v1.9) must
  fail CLOSED on the KYC/AML control: a KYC hit / inconclusive / unknown screening whose
  manual review times out, is rejected, or never records an outcome must NOT reach
  `authority-routing` (the approval path), `create-facility` or `disburse-loan`.

  v1.6 defect: `kyc-manual-review` -> `assessment-join` (and `timeout-kyc-manual-review` ->
  `kyc-timeout` -> `assessment-join`) carried no outcome, and `eligibility-gate` e15 read only
  `credit_decision` and `risk_rating`, never any KYC value.

  v1.7: the outcome is an explicit variable. `kyc-manual-review` is completed with output
  variable `kyc_outcome` = `cleared` | `rejected`; the `kyc-timeout` service task records
  `kyc_outcome` = `unresolved` (the QA stub echoes it, like `kyc-aml-check` echoes
  `kyc_status`). `eligibility-gate` has two approval edges -- `e15` (screening answered
  `kyc_status == 'clear'`) and `e15-kyc-cleared` (`kyc_outcome == 'cleared'`) -- and
  everything else falls to the default edge -> `decline-application`.

  ## Why two edges, not `kyc_status == 'clear' || kyc_outcome == 'cleared'`

  Probed against the real evaluator: a reference to a variable that is not set makes the
  comparison an eval error and `Letflow.Engine.Expr.evaluate_condition/2` returns `false`
  for the WHOLE condition -- there is no short-circuit across `||`. A single OR condition
  would therefore decline the UAT fast path (`kyc_status` 'clear', no `kyc_outcome`).

  ## risk_rating (acceptance criterion: engine-level proof)

  An UNSET `risk_rating` already fails closed (the same missing-key eval error makes
  `risk_rating != 'unacceptable'` false), but an explicit `null` or `''` PASSED the v1.6
  gate (`null != 'unacceptable'` is true). v1.7 requires the rating to be present and not
  empty as well as not `unacceptable`. These tests drive the REAL `Letflow.Engine.Transition`
  gateway dispatch (token at `eligibility-gate`, `{:advance_token, _}`), not a re-implementation.

  Pure: no DB, no HTTP.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.{Expr, InstanceState, Token, Transition}

  @fixture Path.expand(
             "../../fixtures/qa/meridian_loan_origination_process_definition.json",
             __DIR__
           )

  defp doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp edges(document), do: document["graph"]["edges"]
  defp edges_from(document, source), do: Enum.filter(edges(document), &(&1["source"] == source))

  defp graph! do
    assert {:ok, graph} = Graph.from_map(doc()["graph"])
    graph
  end

  # --- real-engine settle: advance a token through EXCLUSIVE_GATEWAY nodes only ----------

  defp settle(graph, node_id, variables) do
    state = %InstanceState{
      instance_id: "inst-kyc",
      tokens: [%Token{node_id: node_id, token_id: "t1"}],
      variables: variables
    }

    do_settle(graph, state)
  end

  defp do_settle(graph, %InstanceState{tokens: [%Token{node_id: node_id}]} = state) do
    node = Enum.find(graph.nodes, &(&1.id == node_id))

    if node.node_type == :EXCLUSIVE_GATEWAY do
      assert {:ok, next_state, []} = Transition.transition(graph, state, {:advance_token, "t1"})
      do_settle(graph, next_state)
    else
      node_id
    end
  end

  # What the real engine does when the human task kyc-manual-review is completed.
  defp complete_review(graph, variables) do
    state = %InstanceState{
      instance_id: "inst-kyc",
      tokens: [%Token{node_id: "kyc-manual-review", token_id: "t1"}],
      variables: variables
    }

    assert {:ok, %InstanceState{tokens: [%Token{node_id: node_id}]}, _} =
             Transition.transition(graph, state, {:complete_task, "t1"})

    node_id
  end

  @pass %{"credit_decision" => "pass", "risk_rating" => "low", "requested_amount_eur" => 100_000}

  defp vars(extra), do: Map.merge(@pass, extra)

  test "fixture version is 1.16 (Q-1051 / GH #2395 L1 CRO escalation and assessment distinct_from; 1.15 Q-1048 loan-ops-lead escalation; 1.14 REQ-465 distinct_from; 1.13 REQ-462 required_outputs; ISS-1013 D-ESC timers; 1.7 forced the QA re-seed of the KYC fail-closed gate; ISS-1024 bumped to 1.8; ISS-1015 to 1.9)" do
    assert doc()["version"] == "1.16"
  end

  describe "eligibility-gate through the real engine" do
    test "clear screening (the UAT stub's kyc_status 'clear', no kyc_outcome) still reaches the approval path" do
      graph = graph!()

      assert "l1-approval" ==
               settle(graph, "eligibility-gate", vars(%{"kyc_status" => "clear"}))

      assert "committee-vote-fork" ==
               settle(
                 graph,
                 "eligibility-gate",
                 vars(%{"kyc_status" => "clear", "requested_amount_eur" => 600_000})
               )
    end

    test "a hit / inconclusive / unknown screening whose review recorded kyc_outcome 'cleared' reaches the approval path" do
      graph = graph!()

      for status <- ["hit", "inconclusive", nil] do
        base = if status, do: %{"kyc_status" => status}, else: %{}

        assert "l1-approval" ==
                 settle(graph, "eligibility-gate", vars(Map.put(base, "kyc_outcome", "cleared"))),
               "kyc_status #{inspect(status)} + cleared must pass"
      end
    end

    test "kyc_outcome rejected / unresolved / absent / unrecognised after a hit never reaches the approval path" do
      graph = graph!()

      for status <- ["hit", "inconclusive", "unknown", nil],
          outcome <- ["rejected", "unresolved", "CLEARED", "cleared ", "", nil, :absent] do
        base = if status, do: %{"kyc_status" => status}, else: %{}
        base = if outcome == :absent, do: base, else: Map.put(base, "kyc_outcome", outcome)

        assert "decline-application" == settle(graph, "eligibility-gate", vars(base)),
               "kyc_status #{inspect(status)} kyc_outcome #{inspect(outcome)} must decline"
      end
    end

    test "unset, null or empty risk_rating declines; 'unacceptable' declines; a real rating passes (ISS-1020 AC3)" do
      graph = graph!()
      clear = %{"kyc_status" => "clear"}

      # unset key: the evaluator errors -> false -> default decline (was already fail-closed in v1.6)
      assert "decline-application" ==
               settle(graph, "eligibility-gate", Map.delete(vars(clear), "risk_rating"))

      # explicit null / empty string: PASSED the v1.6 gate (null != 'unacceptable' is true)
      for bad <- [nil, "", "unacceptable"] do
        assert "decline-application" ==
                 settle(graph, "eligibility-gate", vars(Map.put(clear, "risk_rating", bad))),
               "risk_rating #{inspect(bad)} must decline"
      end

      for good <- ["low", "acceptable", "medium"] do
        assert "l1-approval" ==
                 settle(graph, "eligibility-gate", vars(Map.put(clear, "risk_rating", good)))
      end
    end

    test "credit_decision fail or absent declines" do
      graph = graph!()
      clear = %{"kyc_status" => "clear"}

      assert "decline-application" ==
               settle(graph, "eligibility-gate", vars(Map.put(clear, "credit_decision", "fail")))

      assert "decline-application" ==
               settle(graph, "eligibility-gate", Map.delete(vars(clear), "credit_decision"))
    end

    test "completing kyc-manual-review lands on assessment-join (the outcome is checked at the gate, not by killing one parallel branch)" do
      graph = graph!()

      for outcome <- ["cleared", "rejected", nil] do
        assert "assessment-join" ==
                 complete_review(graph, %{"kyc_status" => "hit", "kyc_outcome" => outcome})
      end
    end
  end

  describe "graph walk with the real evaluator (over-approximating: default edges always followed)" do
    # Nodes reachable from `start` along edges that can fire under `variables`.
    defp reachable(start, variables) do
      walk([start], MapSet.new([start]), variables)
    end

    defp walk([], seen, _variables), do: seen

    defp walk([node | rest], seen, variables) do
      next =
        for edge <- edges_from(doc(), node),
            is_nil(edge["condition"]) or Expr.evaluate_condition(edge["condition"], variables),
            edge["target"] not in seen,
            uniq: true,
            do: edge["target"]

      walk(rest ++ next, Enum.into(next, seen), variables)
    end

    @approval_nodes [
      "authority-routing",
      "l1-approval",
      "escalate-l1-approval-to-cro",
      "l2-approval",
      "committee-vote-fork",
      "create-facility",
      "disburse-loan",
      "end-disbursed"
    ]

    test "from kyc-manual-review, a rejected / unresolved / missing outcome never reaches any approval node" do
      for outcome <- [%{"kyc_outcome" => "rejected"}, %{"kyc_outcome" => "unresolved"}, %{}] do
        variables = vars(Map.merge(%{"kyc_status" => "hit"}, outcome))
        reached = reachable("kyc-manual-review", variables)

        for node <- @approval_nodes,
            do: refute(node in reached, "#{node} reached with #{inspect(outcome)}")

        assert "decline-application" in reached
        assert "end-declined" in reached
      end
    end

    test "from kyc-timeout, the timeout record (kyc_outcome 'unresolved') or no record at all never reaches any approval node" do
      for outcome <- [%{"kyc_outcome" => "unresolved"}, %{}] do
        variables = vars(Map.merge(%{"kyc_status" => "inconclusive"}, outcome))
        reached = reachable("kyc-timeout", variables)

        for node <- @approval_nodes,
            do: refute(node in reached, "#{node} reached with #{inspect(outcome)}")

        assert "end-declined" in reached
      end
    end

    test "non-vacuous: cleared review and the clear fast path do reach create-facility" do
      assert "create-facility" in reachable(
               "kyc-manual-review",
               vars(%{
                 "kyc_status" => "hit",
                 "kyc_outcome" => "cleared",
                 "l1_decision" => "approve",
                 "l2_decision" => "approve"
               })
             )

      assert "authority-routing" in reachable("kyc-routing", vars(%{"kyc_status" => "clear"}))
    end

    test "a kyc-routing default/unknown screening goes to manual review and cannot approve without an outcome" do
      reached = reachable("kyc-routing", vars(%{"kyc_status" => "weird"}))
      assert "kyc-manual-review" in reached
      refute "authority-routing" in reached
      refute "create-facility" in reached
    end
  end

  describe "definition-level structure (no evaluator)" do
    @clear_condition ~r/variables\.kyc_status == 'clear'|variables\.kyc_outcome == 'cleared'/

    # Reachability over the edge set, ignoring conditions (every edge assumed able to fire).
    defp static_reachable(edge_list, start) do
      walk_static(edge_list, [start], MapSet.new([start]))
    end

    defp walk_static(_edges, [], seen), do: seen

    defp walk_static(edge_list, [node | rest], seen) do
      next =
        for e <- edge_list,
            e["source"] == node,
            e["target"] not in seen,
            uniq: true,
            do: e["target"]

      walk_static(edge_list, rest ++ next, Enum.into(next, seen))
    end

    test "every edge into authority-routing carries an explicit KYC-clear condition, and comes only from eligibility-gate" do
      into = Enum.filter(edges(doc()), &(&1["target"] == "authority-routing"))
      assert Enum.sort(Enum.map(into, & &1["id"])) == ["e15", "e15-kyc-cleared"]

      for e <- into do
        assert e["source"] == "eligibility-gate"
        assert e["condition"] =~ @clear_condition
        refute e["is_default"] == true
      end

      # the two edges are exactly the two documented clear branches
      assert Enum.find(into, &(&1["id"] == "e15"))["condition"] =~
               "variables.kyc_status == 'clear'"

      assert Enum.find(into, &(&1["id"] == "e15-kyc-cleared"))["condition"] =~
               "variables.kyc_outcome == 'cleared'"
    end

    test "removing every KYC-clear-conditioned edge leaves authority-routing, create-facility and disburse-loan unreachable from kyc-manual-review and kyc-timeout" do
      all = edges(doc())
      without_clear = Enum.reject(all, &((&1["condition"] || "") =~ @clear_condition))

      for start <- ["kyc-manual-review", "kyc-timeout"] do
        # non-vacuous: with the clear edges the approval path IS structurally reachable
        assert "authority-routing" in static_reachable(all, start)

        reached = static_reachable(without_clear, start)

        for node <- ["authority-routing", "create-facility", "disburse-loan"],
            do:
              refute(node in reached, "#{node} reachable from #{start} without a KYC-clear edge")
      end
    end

    test "kyc-timeout records kyc_outcome 'unresolved' (httpbin /response-headers echoes the query as JSON keys)" do
      node = Enum.find(doc()["graph"]["nodes"], &(&1["id"] == "kyc-timeout"))
      uri = URI.parse(node["attributes"]["endpoint"])

      assert node["node_type"] == "SERVICE_TASK"
      assert uri.host == "httpbin.org"
      assert uri.path == "/response-headers"
      assert URI.decode_query(uri.query) == %{"kyc_outcome" => "unresolved"}
    end

    test "kyc-manual-review and kyc-timeout still converge on assessment-join; eligibility-gate keeps its decline default" do
      assert [%{"target" => "assessment-join"}] =
               Enum.filter(edges_from(doc(), "kyc-manual-review"), &(&1["id"] == "e12"))

      assert [%{"target" => "assessment-join"}] = edges_from(doc(), "kyc-timeout")

      assert [%{"target" => "decline-application"} = default] =
               Enum.filter(edges_from(doc(), "eligibility-gate"), &(&1["is_default"] == true))

      refute Map.has_key?(default, "condition")
    end

    test "the v1.7 graph validates clean" do
      graph = graph!()
      assert %{valid: true, violations: []} = Graph.validate_graph(graph)
      assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
      assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
    end
  end
end
