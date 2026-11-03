defmodule Letflow.Definitions.GraphFlowTest do
  @moduledoc """
  Pure unit tests for REQ-455's `Letflow.Definitions.Graph.validate_flow/1`
  (CHK-22 `:unreachable_node`, CHK-23 `:no_path_to_end`, CHK-24 `:no_default_route`).
  See `test/specs/REQ-455.md` for the per-test rationale.

  Every "violates ONLY that check" graph is also run through the three pre-existing
  validators (`validate_graph/1`, `validate_node_attributes/1`,
  `validate_edge_conditions/1`) and asserted clean, so the test proves the new code
  is the only thing that catches the defect (this is the REQ-455 gap, not an old
  check firing under a new name).

  `async: true`, no I/O, no clock, no randomness.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}

  defp node(id, type), do: %Node{id: id, node_type: type}

  defp human(id), do: %Node{id: id, node_type: :HUMAN_TASK, attributes: %{"role" => "approver"}}

  defp service(id) do
    %Node{
      id: id,
      node_type: :SERVICE_TASK,
      attributes: %{
        "endpoint" => "https://example.test/#{id}",
        "method" => "POST",
        "timeout_ms" => 1000
      }
    }
  end

  defp edge(id, source, target), do: %Edge{id: id, source: source, target: target}

  defp default_edge(id, source, target),
    do: %Edge{id: id, source: source, target: target, is_default: true}

  defp cond_edge(id, source, target, condition),
    do: %Edge{id: id, source: source, target: target, condition: condition}

  defp graph(nodes, edges), do: %Graph{nodes: nodes, edges: edges}

  defp codes(%{violations: violations}), do: Enum.map(violations, & &1.code)
  defp messages(%{violations: violations}), do: Enum.map(violations, & &1.message)

  # The three validators that existed before REQ-455: all must be clean for a graph
  # that claims to violate only a REQ-455 check.
  defp assert_legacy_validators_clean(%Graph{} = g) do
    assert Graph.validate_graph(g) == %{valid: true, violations: []}
    assert Graph.validate_node_attributes(g) == %{valid: true, violations: []}
    assert Graph.validate_edge_conditions(g) == %{valid: true, violations: []}
  end

  # A fully connected, defaulted graph: start -> g -> {end (conditional), end2 (default)}.
  defp valid_flow_graph do
    graph(
      [
        node("start", :START),
        node("g", :EXCLUSIVE_GATEWAY),
        node("end", :END),
        node("end2", :END)
      ],
      [
        edge("e1", "start", "g"),
        cond_edge("e2", "g", "end", "amount > 100"),
        default_edge("e3", "g", "end2")
      ]
    )
  end

  describe "validate_flow/1 -- valid neighbour (baseline)" do
    test "a fully connected graph where every node reaches an END and the gateway has a default passes" do
      g = valid_flow_graph()
      assert_legacy_validators_clean(g)
      assert Graph.validate_flow(g) == %{valid: true, violations: []}
    end

    test "a permitted gateway loop that can still exit to an END passes (cycles are not traps)" do
      g =
        graph(
          [
            node("start", :START),
            node("g", :EXCLUSIVE_GATEWAY),
            service("retry"),
            node("end", :END)
          ],
          [
            edge("e1", "start", "g"),
            cond_edge("e2", "g", "retry", "amount > 100"),
            default_edge("e3", "g", "end"),
            edge("e4", "retry", "g")
          ]
        )

      assert_legacy_validators_clean(g)
      assert Graph.validate_flow(g).violations == []
    end
  end

  describe "CHK-22 :unreachable_node" do
    test "a connected island x<->y beside a valid start->end is reported once per island node, naming each id" do
      g =
        graph(
          [
            node("start", :START),
            node("end", :END),
            node("x", :EXCLUSIVE_GATEWAY),
            node("y", :EXCLUSIVE_GATEWAY)
          ],
          [
            edge("e1", "start", "end"),
            cond_edge("e2", "x", "y", "amount > 100"),
            default_edge("e3", "y", "x"),
            default_edge("e4", "x", "end")
          ]
        )

      # Existing validators are blind to this island (the REQ-455 gap).
      assert_legacy_validators_clean(g)

      result = Graph.validate_flow(g)
      assert result.valid == false
      assert codes(result) == [:unreachable_node, :unreachable_node]
      [mx, my] = messages(result)
      assert mx =~ "Node 'x'"
      assert my =~ "Node 'y'"
      assert mx =~ "not reachable from any START node"
    end

    test "valid neighbour: the same shape with the island wired in from start reports nothing" do
      g =
        graph(
          [
            node("start", :START),
            node("end", :END),
            node("x", :EXCLUSIVE_GATEWAY),
            node("y", :EXCLUSIVE_GATEWAY)
          ],
          [
            edge("e1", "start", "x"),
            cond_edge("e2", "x", "y", "amount > 100"),
            default_edge("e3", "y", "x"),
            default_edge("e4", "x", "end")
          ]
        )

      assert_legacy_validators_clean(g)
      assert Graph.validate_flow(g).violations == []
    end

    test "a dangling edge and a missing START never raise and report nothing from CHK-22" do
      no_start = graph([node("a", :END)], [edge("e1", "ghost", "a")])
      assert %{violations: vs} = Graph.validate_flow(no_start)
      refute :unreachable_node in Enum.map(vs, & &1.code)

      with_dangling =
        graph([node("start", :START), node("end", :END)], [
          edge("e1", "start", "end"),
          edge("e2", "end", "nowhere")
        ])

      assert Graph.validate_flow(with_dangling).violations == []
    end

    test "duplicate node ids are reported once, not once per duplicate" do
      g =
        graph(
          [node("start", :START), node("end", :END), node("dup", :END), node("dup", :END)],
          [edge("e1", "start", "end")]
        )

      unreachable =
        Graph.validate_flow(g).violations |> Enum.filter(&(&1.code == :unreachable_node))

      assert length(unreachable) == 1
      assert hd(unreachable).message =~ "Node 'dup'"
    end
  end

  describe "CHK-23 :no_path_to_end" do
    test "a gateway loop h<->k reachable from start that can never exit is reported for h and k only" do
      g =
        graph(
          [
            node("start", :START),
            node("g", :EXCLUSIVE_GATEWAY),
            node("end", :END),
            node("h", :EXCLUSIVE_GATEWAY),
            node("k", :EXCLUSIVE_GATEWAY)
          ],
          [
            edge("e1", "start", "g"),
            cond_edge("e2", "g", "end", "amount > 100"),
            default_edge("e3", "g", "h"),
            default_edge("e4", "h", "k"),
            default_edge("e5", "k", "h")
          ]
        )

      assert_legacy_validators_clean(g)

      result = Graph.validate_flow(g)
      assert result.valid == false
      assert codes(result) == [:no_path_to_end, :no_path_to_end]
      [mh, mk] = messages(result)
      assert mh =~ "Node 'h'"
      assert mk =~ "Node 'k'"
      assert mh =~ "no path to any END node"
    end

    test "valid neighbour: giving the loop an exit edge to an END clears the violation" do
      g =
        graph(
          [
            node("start", :START),
            node("g", :EXCLUSIVE_GATEWAY),
            node("end", :END),
            node("h", :EXCLUSIVE_GATEWAY),
            node("k", :EXCLUSIVE_GATEWAY)
          ],
          [
            edge("e1", "start", "g"),
            cond_edge("e2", "g", "end", "amount > 100"),
            default_edge("e3", "g", "h"),
            cond_edge("e4", "h", "k", "amount > 5"),
            default_edge("e5", "h", "end"),
            default_edge("e6", "k", "h")
          ]
        )

      assert_legacy_validators_clean(g)
      assert Graph.validate_flow(g).violations == []
    end

    test "an END node trivially reaches itself and a missing END reports nothing (CHK-02 owns it)" do
      assert Graph.validate_flow(graph([node("start", :START)], [])).violations == []
    end
  end

  describe "CHK-24 :no_default_route" do
    test "an exclusive gateway whose outgoing edges are all conditional is reported, naming the gateway" do
      g =
        graph(
          [
            node("start", :START),
            node("g", :EXCLUSIVE_GATEWAY),
            node("a", :END),
            node("b", :END)
          ],
          [
            edge("e1", "start", "g"),
            cond_edge("e2", "g", "a", "amount > 100"),
            cond_edge("e3", "g", "b", "amount <= 100")
          ]
        )

      # No existing validator requires a default on a gateway (the ISS-0928 gap).
      assert_legacy_validators_clean(g)

      result = Graph.validate_flow(g)
      assert codes(result) == [:no_default_route]
      [message] = messages(result)
      assert message =~ "Node 'g' (EXCLUSIVE_GATEWAY)"
      assert message =~ "no default outgoing edge"
    end

    test "valid neighbour: adding one is_default edge to the same gateway passes" do
      assert Graph.validate_flow(valid_flow_graph()).violations == []
    end

    test "a gateway with no outgoing edge at all is not reported by CHK-24 (isolated_node owns it)" do
      g = graph([node("start", :START), node("g", :EXCLUSIVE_GATEWAY), node("end", :END)], [])
      refute :no_default_route in codes(Graph.validate_flow(g))
    end

    test "HUMAN_TASK without a default is NOT double-reported here (CHK-19 owns it)" do
      g =
        graph(
          [node("start", :START), human("t"), node("a", :END), node("b", :END)],
          [
            edge("e1", "start", "t"),
            cond_edge("e2", "t", "a", "decision == \"approve\""),
            cond_edge("e3", "t", "b", "decision == \"reject\"")
          ]
        )

      assert :human_task_no_fallback_edge in codes(Graph.validate_edge_conditions(g))
      assert Graph.validate_flow(g).violations == []
    end
  end

  describe "ISS-0928 shape (REQ-455 AC3): decision node with only conditional edges and no default" do
    test "gateway shape (the real ISS-0928 defect): rejected by validate_flow/1 with the gateway named" do
      g =
        graph(
          [
            node("start", :START),
            service("kyc-check"),
            node("kyc-routing", :EXCLUSIVE_GATEWAY),
            node("approved", :END),
            node("rejected", :END)
          ],
          [
            edge("e1", "start", "kyc-check"),
            edge("e2", "kyc-check", "kyc-routing"),
            cond_edge("e3", "kyc-routing", "approved", "risk == \"low\""),
            cond_edge("e4", "kyc-routing", "rejected", "risk == \"high\"")
          ]
        )

      assert_legacy_validators_clean(g)
      result = Graph.validate_flow(g)
      assert result.valid == false
      assert codes(result) == [:no_default_route]
      assert hd(messages(result)) =~ "Node 'kyc-routing'"
    end

    test "literal service-task shape: rejected twice over (unexpected_edge_condition x2 and no_default_route naming the task)" do
      g =
        graph(
          [node("start", :START), service("svc"), node("a", :END), node("b", :END)],
          [
            edge("e1", "start", "svc"),
            cond_edge("e2", "svc", "a", "risk == \"low\""),
            cond_edge("e3", "svc", "b", "risk == \"high\"")
          ]
        )

      edge_result = Graph.validate_edge_conditions(g)
      assert codes(edge_result) == [:unexpected_edge_condition, :unexpected_edge_condition]

      flow_result = Graph.validate_flow(g)
      assert codes(flow_result) == [:no_default_route]
      assert hd(messages(flow_result)) =~ "Node 'svc' (SERVICE_TASK)"
    end

    test "service-task valid neighbour: an unconditional outgoing edge is never flagged" do
      g =
        graph(
          [node("start", :START), service("svc"), node("a", :END)],
          [edge("e1", "start", "svc"), edge("e2", "svc", "a")]
        )

      assert_legacy_validators_clean(g)
      assert Graph.validate_flow(g).violations == []
    end

    test "service task with one conditional edge and one default is not flagged by CHK-24" do
      g =
        graph(
          [node("start", :START), service("svc"), node("a", :END), node("b", :END)],
          [
            edge("e1", "start", "svc"),
            cond_edge("e2", "svc", "a", "risk == \"low\""),
            default_edge("e3", "svc", "b")
          ]
        )

      refute :no_default_route in codes(Graph.validate_flow(g))
    end
  end

  describe "validate_flow/1 -- composition" do
    test "independent defects are all reported (never short-circuits), in CHK-22, CHK-23, CHK-24 order" do
      g =
        graph(
          [
            node("start", :START),
            node("g", :EXCLUSIVE_GATEWAY),
            node("end", :END),
            node("island", :EXCLUSIVE_GATEWAY)
          ],
          [
            edge("e1", "start", "g"),
            cond_edge("e2", "g", "end", "amount > 100"),
            cond_edge("e3", "g", "end", "amount <= 100"),
            default_edge("e4", "island", "island")
          ]
        )

      assert codes(Graph.validate_flow(g)) ==
               [:unreachable_node, :no_path_to_end, :no_default_route]
    end
  end
end
