defmodule Letflow.Scripts.VortexSeverityTimeoutDefaultCriticalTest do
  @moduledoc """
  ISS-1003 / Q-985 (GH #2272, audit PA-VORTEX-003) -- the QA Vortex "Supplier Quality
  Deviation" fixture (v1.4) must set `severity` EXPLICITLY on the
  `severity-classification` timeout path.

  v1.3 defect: `timeout-severity-classification` -> `default-to-major` -> `severity-routing`
  never set `severity`, so the gateway's default edge sent the deviation to the critical 8D
  sub-process by accident while the node name claimed "major".

  BA ruling (option B, 2026-10-06; principle: a default routes toward MORE scrutiny, never
  less): the timeout step is `default-to-critical` and the QA stub endpoint echoes
  `severity=critical` (httpbin `/response-headers` echoes its query as JSON keys, the same
  pattern as the Meridian `kyc-timeout` / `kyc-aml-check` stubs). The path ends in the
  critical 8D handling (`corrective-action-subprocess`) exactly as before; the critical path
  itself is unchanged. The superseded original AC ('major') must never come back.

  Drives the REAL `Letflow.Engine.Transition` gateway dispatch. Pure: no DB, no HTTP.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.{InstanceState, Token, Transition}

  @fixture Path.expand(
             "../../fixtures/qa/vortex_supplier_quality_deviation_process_definition.json",
             __DIR__
           )

  defp doc, do: @fixture |> File.read!() |> Jason.decode!()
  defp nodes(d), do: d["graph"]["nodes"]
  defp edges(d), do: d["graph"]["edges"]

  defp graph!(d) do
    assert {:ok, graph} = Graph.from_map(d["graph"])
    graph
  end

  # The node the STALLED timeout path of severity-classification ends at, found structurally
  # (v1.6, ISS-1002 / Q-984: severity-classification -> escalate-severity-classification-to-ceo
  # -> default-to-critical; the CEO escalation level sits in between).
  defp timeout_node(d) do
    [first] = Enum.filter(edges(d), &(&1["id"] == "timeout-severity-classification"))
    assert first["source"] == "severity-classification"
    assert first["target"] == "escalate-severity-classification-to-ceo"

    [edge] =
      Enum.filter(edges(d), &(&1["id"] == "timeout-escalate-severity-classification-to-ceo"))

    assert edge["source"] == first["target"]
    Enum.find(nodes(d), &(&1["id"] == edge["target"]))
  end

  # What the QA stub endpoint (httpbin /response-headers) merges into the variables.
  defp echoed_variables(node) do
    uri = URI.parse(node["attributes"]["endpoint"])
    assert node["node_type"] == "SERVICE_TASK"
    assert uri.host == "httpbin.org"
    assert uri.path == "/response-headers"
    URI.decode_query(uri.query || "")
  end

  # Real engine: advance the token through EXCLUSIVE_GATEWAY nodes until it rests.
  defp settle(graph, node_id, variables) do
    state = %InstanceState{
      instance_id: "inst-vortex",
      tokens: [%Token{node_id: node_id, token_id: "t1"}],
      variables: variables
    }

    do_settle(graph, state)
  end

  defp do_settle(graph, %InstanceState{tokens: [%Token{node_id: node_id}]} = state) do
    node = Enum.find(graph.nodes, &(&1.id == node_id))

    if node.node_type == :EXCLUSIVE_GATEWAY do
      assert {:ok, next, []} = Transition.transition(graph, state, {:advance_token, "t1"})
      do_settle(graph, next)
    else
      node_id
    end
  end

  # The only node between the timeout step and severity-routing carries the severity.
  defp timeout_path_variables(d) do
    node = timeout_node(d)

    assert [%{"target" => "severity-routing"}] =
             Enum.filter(edges(d), &(&1["source"] == node["id"]))

    Map.merge(%{"false_positive" => false}, echoed_variables(node))
  end

  test "fixture version is 1.7 (1.7 = REQ-462 required_outputs; 1.4 forced the QA re-seed of the explicit default-to-critical step; 1.6 = ISS-1002 CEO escalation level)" do
    assert doc()["version"] == "1.8"
  end

  test "the timeout step is named default-to-critical and its stub sets severity = 'critical' explicitly" do
    node = timeout_node(doc())
    assert node["id"] == "default-to-critical"
    assert echoed_variables(node) == %{"severity" => "critical"}
  end

  test "the definition description says an unclassified deviation is handled as critical until a human classifies it" do
    description = doc()["description"]
    assert description =~ "default-to-critical"
    assert description =~ ~r/unclassified deviation is handled as critical/
    assert description =~ "until a human classifies it"
  end

  test "the whole definition no longer mentions a major default (superseded AC never comes back)" do
    refute File.read!(@fixture) =~ "default-to-major"
  end

  test "through the real engine, the timeout path carries severity 'critical' and ends in corrective-action-subprocess" do
    d = doc()
    variables = timeout_path_variables(d)

    assert variables["severity"] == "critical"
    refute variables["severity"] in [nil, "major", "minor"]
    assert "corrective-action-subprocess" == settle(graph!(d), "severity-routing", variables)
  end

  test "only the explicit critical edge fires on the timeout path (not the severity-routing default)" do
    d = doc()
    variables = timeout_path_variables(d)

    fired =
      for e <- edges(d),
          e["source"] == "severity-routing",
          cond = e["condition"],
          Letflow.Engine.Expr.evaluate_condition(cond, variables),
          do: e["id"]

    assert fired == ["e6"]
  end

  test "non-vacuous: major / minor classification still route to their own handling; critical path unchanged" do
    g = graph!(doc())
    assert "supplier-warning" == settle(g, "severity-routing", %{"severity" => "major"})
    assert "supplier-notification" == settle(g, "severity-routing", %{"severity" => "minor"})

    assert "corrective-action-subprocess" ==
             settle(g, "severity-routing", %{"severity" => "critical"})

    [e6] = Enum.filter(edges(doc()), &(&1["id"] == "e6"))
    assert e6["condition"] == "variables.severity == 'critical'"
    assert e6["target"] == "corrective-action-subprocess"
  end

  test "the timeout step has exactly one way on (severity-routing); the v1.4 graph validates clean" do
    d = doc()
    node = timeout_node(d)

    assert [%{"target" => "severity-routing"}] =
             Enum.filter(edges(d), &(&1["source"] == node["id"]))

    g = graph!(d)
    assert %{valid: true, violations: []} = Graph.validate_graph(g)
    assert %{valid: true, violations: []} = Graph.validate_node_attributes(g)
    assert %{valid: true, violations: []} = Graph.validate_edge_conditions(g)
  end
end
