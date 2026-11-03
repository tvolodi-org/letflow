defmodule Letflow.Definitions.SemanticValidationDataFlowTest do
  @moduledoc """
  Pure unit tests for REQ-455's data-flow class of
  `Letflow.Definitions.SemanticValidation.validate/2`: `:variable_never_collected`.
  See `test/specs/REQ-455.md`.

  The class only fires when it is CERTAIN no path can set the variable (design
  section 4): non-empty declared fields, root not declared, HUMAN_TASK-sourced edge
  with a condition, and no ancestor-or-self node that may write it. Each "valid
  neighbour" below removes exactly one of those conjuncts and must pass.

  `async: true`, no I/O, no clock, no randomness.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.{Edge, Node}
  alias Letflow.Definitions.SemanticValidation

  @declared %{"a" => %{"type" => "string"}}

  defp node(id, type), do: %Node{id: id, node_type: type}

  defp human(id, attributes \\ %{"role" => "approver"}),
    do: %Node{id: id, node_type: :HUMAN_TASK, attributes: attributes}

  defp form(id, property_names) do
    properties = Map.new(property_names, &{&1, %{"type" => "string"}})
    human(id, %{"role" => "approver", "form_schema" => %{"properties" => properties}})
  end

  defp service(id),
    do: %Node{id: id, node_type: :SERVICE_TASK, attributes: %{"endpoint" => "https://x.test"}}

  defp sub_process(id, attributes),
    do: %Node{id: id, node_type: :SUB_PROCESS, attributes: attributes}

  defp edge(id, source, target), do: %Edge{id: id, source: source, target: target}

  defp cond_edge(id, source, target, condition),
    do: %Edge{id: id, source: source, target: target, condition: condition}

  defp graph(nodes, edges), do: %Graph{nodes: nodes, edges: edges}

  defp codes(%{violations: violations}), do: Enum.map(violations, & &1.code)
  defp messages(%{violations: violations}), do: Enum.map(violations, & &1.message)

  # start -> upstream... -> t (HUMAN_TASK, edge e-cond reads `condition`) -> end
  defp flow(upstream_nodes, task, condition) do
    ids = Enum.map(upstream_nodes, & &1.id) ++ [task.id]
    chain = Enum.chunk_every(["start" | ids], 2, 1, :discard)

    chain_edges =
      chain |> Enum.with_index() |> Enum.map(fn {[s, t], i} -> edge("c#{i}", s, t) end)

    graph(
      [node("start", :START)] ++ upstream_nodes ++ [task, node("end", :END), node("end2", :END)],
      chain_edges ++
        [cond_edge("e-cond", task.id, "end", condition), edge("e-other", task.id, "end2")]
    )
  end

  describe "validate/2 -- :variable_never_collected (certain case only)" do
    test "a HUMAN_TASK edge reading a variable no declared field, form or upstream node can set is reported, naming the edge and the variable" do
      g = flow([], form("t", ["x"]), "ghost == 1")

      result = SemanticValidation.validate(g, @declared)

      assert result.valid == false
      assert codes(result) == [:variable_never_collected]
      [message] = messages(result)
      assert message =~ "Edge 'e-cond'"
      assert message =~ "HUMAN_TASK node 't'"
      assert message =~ "'ghost'"
    end

    test "valid neighbour: the variable is a declared field (possible start input)" do
      g = flow([], form("t", ["x"]), "a == \"yes\"")
      assert SemanticValidation.validate(g, @declared).violations == []
    end

    test "valid neighbour: the task's own form properties declare it (the source node counts as a writer)" do
      g = flow([], form("t", ["ghost"]), "ghost == 1")
      assert SemanticValidation.validate(g, @declared).violations == []
    end

    test "valid neighbour: an upstream form on the path declares it" do
      g = flow([form("t0", ["ghost"])], form("t", ["x"]), "ghost == 1")
      assert SemanticValidation.validate(g, @declared).violations == []
    end

    test "valid neighbour: an upstream SERVICE_TASK may write anything (opaque response)" do
      g = flow([service("svc")], form("t", ["x"]), "ghost == 1")
      assert SemanticValidation.validate(g, @declared).violations == []
    end

    test "valid neighbour: an open HUMAN_TASK form (no form_schema properties) may write anything" do
      open_source = flow([], human("t"), "ghost == 1")
      assert SemanticValidation.validate(open_source, @declared).violations == []

      open_upstream = flow([human("t0")], form("t", ["x"]), "ghost == 1")
      assert SemanticValidation.validate(open_upstream, @declared).violations == []
    end

    test "SUB_PROCESS: no interface is open (passes); an interface whose outputs omit the variable does NOT cover it; one that names it does" do
      without_interface = flow([sub_process("sp", %{})], form("t", ["x"]), "ghost == 1")
      assert SemanticValidation.validate(without_interface, @declared).violations == []

      narrow = %{"outputs" => [%{"name" => "other", "json_schema" => %{"type" => "string"}}]}

      narrow_sp =
        flow([sub_process("sp", %{"interface" => narrow})], form("t", ["x"]), "ghost == 1")

      assert codes(SemanticValidation.validate(narrow_sp, @declared)) == [
               :variable_never_collected
             ]

      covering = %{"outputs" => [%{"name" => "ghost", "json_schema" => %{"type" => "string"}}]}

      covering_sp =
        flow([sub_process("sp", %{"interface" => covering})], form("t", ["x"]), "ghost == 1")

      assert SemanticValidation.validate(covering_sp, @declared).violations == []
    end

    test "a writer that is NOT on any path to the task (a sibling branch) does not suppress the violation" do
      # start -> t (reads ghost) ; start -> svc -> end3 : svc is not an ancestor of t.
      g =
        graph(
          [
            node("start", :START),
            form("t", ["x"]),
            service("svc"),
            node("end", :END),
            node("end2", :END),
            node("end3", :END)
          ],
          [
            edge("c0", "start", "t"),
            edge("c1", "start", "svc"),
            edge("c2", "svc", "end3"),
            cond_edge("e-cond", "t", "end", "ghost == 1"),
            edge("e-other", "t", "end2")
          ]
        )

      assert codes(SemanticValidation.validate(g, @declared)) == [:variable_never_collected]
    end

    test "a writer DOWNSTREAM of the task does not suppress the violation (only ancestors-or-self count)" do
      g =
        graph(
          [
            node("start", :START),
            form("t", ["x"]),
            service("svc"),
            node("end", :END)
          ],
          [
            edge("c0", "start", "t"),
            cond_edge("e-cond", "t", "svc", "ghost == 1"),
            edge("e-other", "t", "end"),
            edge("c2", "svc", "end")
          ]
        )

      assert codes(SemanticValidation.validate(g, @declared)) == [:variable_never_collected]
    end

    test "empty declared_fields is exempt: with no registered contract nothing is certain" do
      g = flow([], form("t", ["x"]), "ghost == 1")
      assert SemanticValidation.validate(g, %{}).violations == []
    end

    test "a nested path reads only its root: 'ghost.inner' is reported against 'ghost', and a declared root covers it" do
      g = flow([], form("t", ["x"]), "ghost.inner == 1")
      [message] = messages(SemanticValidation.validate(g, @declared))
      assert message =~ "'ghost'"

      covered = flow([], form("t", ["x"]), "a.inner == 1")
      assert SemanticValidation.validate(covered, @declared).violations == []
    end

    test "an EXCLUSIVE_GATEWAY-sourced edge is not double-reported: only :undeclared_variable_reference fires" do
      g =
        graph(
          [node("start", :START), node("gw", :EXCLUSIVE_GATEWAY), node("end", :END)],
          [edge("c0", "start", "gw"), cond_edge("e-cond", "gw", "end", "ghost == 1")]
        )

      assert codes(SemanticValidation.validate(g, @declared)) == [:undeclared_variable_reference]
    end

    test "a blank condition on a HUMAN_TASK edge is skipped" do
      g = flow([], form("t", ["x"]), "")
      assert SemanticValidation.validate(g, @declared).violations == []
    end
  end
end
