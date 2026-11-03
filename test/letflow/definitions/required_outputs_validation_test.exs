defmodule Letflow.Definitions.RequiredOutputsValidationTest do
  @moduledoc """
  Pure unit tests for REQ-461's three validator checks (REQ-459 design sections 1.2-1.4).
  See `test/specs/REQ-461.md`.

    * check 1 -- `Graph.validate_node_attributes/1` (CHK-25): `:invalid_required_outputs`,
      `:required_outputs_on_non_human_task`
    * check 2 -- `SemanticValidation.required_output_schema_violations/2` and
      `SemanticValidation.validate/2` (both clauses): `:required_output_without_variable_schema`
    * check 3 -- `SemanticValidation.decision_key_warnings/2`: the permanent WARNING string
      prefix `decision_key_not_required:` (never a violation)

  Every "minimal violating definition" below is otherwise clean: each asserts the WHOLE code
  list of the relevant validator, so a second, unrelated violation would fail the test.

  `async: true`, no I/O, no clock, no randomness. No helper has a default argument
  (anti-patterns ISS-0069).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.SemanticValidation

  @decision_schema %{"type" => "string", "enum" => ["approved", "rejected"]}
  @declared %{"decision" => @decision_schema}
  @condition "decision == \"approved\""

  # --- builders -------------------------------------------------------------------------

  defp node(id, type), do: %{"id" => id, "node_type" => type}
  defp node(id, type, attrs), do: %{"id" => id, "node_type" => type, "attributes" => attrs}

  defp form(property_names) do
    props = Map.new(property_names, &{&1, %{"type" => "string"}})
    %{"form_schema" => %{"properties" => props}}
  end

  # A HUMAN_TASK whose form collects `property_names`, plus `extra` attributes.
  defp human(id, property_names, extra),
    do:
      node(
        id,
        "HUMAN_TASK",
        Map.merge(%{"role" => "approver"}, Map.merge(form(property_names), extra))
      )

  defp service(id),
    do: node(id, "SERVICE_TASK", %{"endpoint" => "https://x.test", "timeout_ms" => 1000})

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp cond_edge(id, source, target, condition),
    do: %{"id" => id, "source" => source, "target" => target, "condition" => condition}

  defp default_edge(id, source, target),
    do: %{"id" => id, "source" => source, "target" => target, "is_default" => true}

  defp build!(nodes, edges) do
    assert {:ok, graph} = Graph.from_map(%{"nodes" => nodes, "edges" => edges})
    graph
  end

  # start -> t -> (decision == "approved") end-a | default end-b; `t` is the given node map.
  defp one_task(task, condition) do
    build!(
      [node("start", "START"), task, node("end-a", "END"), node("end-b", "END")],
      [
        edge("e-start", "start", task["id"]),
        cond_edge("e-cond", task["id"], "end-a", condition),
        default_edge("e-def", task["id"], "end-b")
      ]
    )
  end

  # start -> (extra upstream chain...) -> reader -> end-a | end-b. `chain` is a list of node
  # maps; `reader_edge_source` is the node whose outgoing edge reads the condition.
  defp chain(upstream, reader, condition) do
    all = upstream ++ [reader]
    ids = ["start" | Enum.map(all, & &1["id"])]

    chain_edges =
      ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {[s, t], i} -> edge("c#{i}", s, t) end)

    build!(
      [node("start", "START")] ++ all ++ [node("end-a", "END"), node("end-b", "END")],
      chain_edges ++
        [
          cond_edge("e-cond", reader["id"], "end-a", condition),
          default_edge("e-def", reader["id"], "end-b")
        ]
    )
  end

  defp attr_codes(graph),
    do: Enum.map(Graph.validate_node_attributes(graph).violations, & &1.code)

  defp attr_violations(graph), do: Graph.validate_node_attributes(graph).violations
  defp sem_codes(result), do: Enum.map(result.violations, & &1.code)

  # =======================================================================================
  # Check 1 -- CHK-25 shape
  # =======================================================================================

  describe "check 1 -- :invalid_required_outputs" do
    test "a non-list value is ONE violation naming the node, whatever the value type" do
      for bad <- ["decision", 5, true, %{"decision" => 1}] do
        graph = one_task(human("t", ["decision"], %{"required_outputs" => bad}), @condition)

        assert [violation] = attr_violations(graph), "value #{inspect(bad)}"
        assert violation.code == :invalid_required_outputs
        assert violation.message =~ "Node 't'"
        assert violation.message =~ "HUMAN_TASK"
      end
    end

    test "a non-string entry is one violation per bad entry, naming the node and the entry" do
      graph =
        one_task(human("t", ["decision"], %{"required_outputs" => [5, nil, ["x"]]}), @condition)

      violations = attr_violations(graph)
      assert Enum.map(violations, & &1.code) == List.duplicate(:invalid_required_outputs, 3)
      assert Enum.all?(violations, &(&1.message =~ "Node 't'"))
      assert Enum.any?(violations, &(&1.message =~ "5"))
    end

    test "an empty-string and a whitespace-only entry are each a violation" do
      for bad <- ["", "   "] do
        graph = one_task(human("t", ["decision"], %{"required_outputs" => [bad]}), @condition)
        assert attr_codes(graph) == [:invalid_required_outputs], "entry #{inspect(bad)}"
      end
    end

    test "a duplicate key is ONE violation naming the node and the key; three copies are still one" do
      twice =
        one_task(
          human("t", ["decision"], %{"required_outputs" => ["decision", "decision"]}),
          @condition
        )

      assert [violation] = attr_violations(twice)
      assert violation.code == :invalid_required_outputs
      assert violation.message =~ "Node 't'"
      assert violation.message =~ "'decision'"

      thrice =
        one_task(
          human("t", ["decision"], %{"required_outputs" => ["decision", "decision", "decision"]}),
          @condition
        )

      assert attr_codes(thrice) == [:invalid_required_outputs]
    end

    test "two different duplicated keys are two violations, one per defect, keys in sorted order" do
      graph =
        one_task(
          human("t", ["decision"], %{"required_outputs" => ["b", "a", "b", "a"]}),
          @condition
        )

      assert [first, second] = attr_violations(graph)
      assert first.message =~ "'a'"
      assert second.message =~ "'b'"
    end

    test "valid neighbour: a duplicate-free list of non-empty strings, an empty list and a null value pass" do
      for ok <- [["decision"], ["decision", "note"], [], nil] do
        graph = one_task(human("t", ["decision"], %{"required_outputs" => ok}), @condition)
        assert attr_violations(graph) == [], "value #{inspect(ok)}"
      end

      absent = one_task(human("t", ["decision"], %{}), @condition)
      assert attr_violations(absent) == []
    end

    test "the violation is per node: two bad HUMAN_TASKs are reported separately, each naming its own id" do
      graph =
        chain(
          [human("t1", ["decision"], %{"required_outputs" => "x"})],
          human("t2", ["decision"], %{"required_outputs" => [""]}),
          @condition
        )

      assert [one, two] = attr_violations(graph)
      assert one.message =~ "Node 't1'"
      assert two.message =~ "Node 't2'"
    end
  end

  describe "check 1 -- :required_outputs_on_non_human_task" do
    test "an EXCLUSIVE_GATEWAY carrying the attribute is ONE violation naming the node and its type" do
      graph =
        build!(
          [
            node("start", "START"),
            node("gw", "EXCLUSIVE_GATEWAY", %{"required_outputs" => ["decision"]}),
            node("end-a", "END"),
            node("end-b", "END")
          ],
          [
            edge("e1", "start", "gw"),
            cond_edge("e2", "gw", "end-a", @condition),
            default_edge("e3", "gw", "end-b")
          ]
        )

      assert [violation] = attr_violations(graph)
      assert violation.code == :required_outputs_on_non_human_task
      assert violation.message =~ "Node 'gw'"
      assert violation.message =~ "EXCLUSIVE_GATEWAY"
    end

    test "a SERVICE_TASK carrying the attribute is reported, even with a malformed value (only the non-human code)" do
      for value <- [["decision"], "decision", []] do
        graph =
          build!(
            [
              node("start", "START"),
              Map.put(service("svc"), "attributes", %{
                "endpoint" => "https://x.test",
                "timeout_ms" => 1000,
                "required_outputs" => value
              }),
              node("end", "END")
            ],
            [edge("e1", "start", "svc"), edge("e2", "svc", "end")]
          )

        assert [violation] = attr_violations(graph), "value #{inspect(value)}"
        assert violation.code == :required_outputs_on_non_human_task
        assert violation.message =~ "Node 'svc'"
      end
    end

    test "valid neighbour: the same SERVICE_TASK and gateway without the attribute (or with null) pass" do
      graph =
        build!(
          [
            node("start", "START"),
            Map.put(service("svc"), "attributes", %{
              "endpoint" => "https://x.test",
              "timeout_ms" => 1000,
              "required_outputs" => nil
            }),
            node("end", "END")
          ],
          [edge("e1", "start", "svc"), edge("e2", "svc", "end")]
        )

      assert attr_violations(graph) == []
    end
  end

  # =======================================================================================
  # Check 2 -- variable_schema for every required_outputs key
  # =======================================================================================

  describe "check 2 -- :required_output_without_variable_schema (validate/2, non-empty declared_fields)" do
    test "a required_outputs key with no variable_schema is ONE violation naming the node id and the key" do
      graph =
        one_task(human("t", ["decision"], %{"required_outputs" => ["decision"]}), @condition)

      # `note` is declared, `decision` is not: the non-empty clause of validate/2.
      result = SemanticValidation.validate(graph, %{"note" => %{"type" => "string"}})

      assert result.valid == false
      assert sem_codes(result) == [:required_output_without_variable_schema]
      [violation] = result.violations

      assert violation.message ==
               "Node 't' (HUMAN_TASK) has required_outputs key 'decision' with no variable_schema"
    end

    test "valid neighbour: the key has a variable_schema" do
      graph =
        one_task(human("t", ["decision"], %{"required_outputs" => ["decision"]}), @condition)

      assert %{valid: true, violations: []} = SemanticValidation.validate(graph, @declared)
    end

    test "one violation per undeclared key: two keys, one declared, names only the missing one" do
      graph =
        one_task(
          human("t", ["decision"], %{"required_outputs" => ["decision", "risk"]}),
          @condition
        )

      assert [violation] = SemanticValidation.validate(graph, @declared).violations
      assert violation.message =~ "'risk'"
      refute violation.message =~ "'decision'"
    end

    test "one violation per (node, key): the same key on two HUMAN_TASKs is reported against each node" do
      graph =
        chain(
          [human("t1", ["decision"], %{"required_outputs" => ["risk"]})],
          human("t2", ["decision"], %{"required_outputs" => ["risk"]}),
          @condition
        )

      violations = SemanticValidation.validate(graph, @declared).violations
      assert length(violations) == 2
      assert Enum.any?(violations, &(&1.message =~ "Node 't1'" and &1.message =~ "'risk'"))
      assert Enum.any?(violations, &(&1.message =~ "Node 't2'" and &1.message =~ "'risk'"))
    end

    test "a duplicated key is reported once by check 2 (the duplicate itself is check 1's)" do
      graph =
        one_task(human("t", ["decision"], %{"required_outputs" => ["risk", "risk"]}), @condition)

      assert [_one] = SemanticValidation.validate(graph, @declared).violations
    end

    test "check 2 reads totally: a malformed or misplaced attribute is ignored, never raises" do
      for value <- ["decision", 5, [1, nil], [""], %{"a" => 1}] do
        graph = one_task(human("t", ["decision"], %{"required_outputs" => value}), @condition)

        assert SemanticValidation.required_output_schema_violations(graph, @declared) == [],
               "value #{inspect(value)}"
      end

      gateway_graph =
        build!(
          [
            node("start", "START"),
            node("gw", "EXCLUSIVE_GATEWAY", %{"required_outputs" => ["ghost"]}),
            node("end", "END")
          ],
          [edge("e1", "start", "gw"), edge("e2", "gw", "end")]
        )

      assert SemanticValidation.required_output_schema_violations(gateway_graph, @declared) == []
    end

    test "check 2 is NOT part of the create-time attribute check (Graph.validate_node_attributes/1)" do
      graph =
        one_task(human("t", ["decision"], %{"required_outputs" => ["undeclared"]}), @condition)

      assert Graph.validate_node_attributes(graph) == %{valid: true, violations: []}
    end
  end

  describe "check 2 -- the empty-declared_fields exemption does not hide it" do
    test "declared_fields == %{} with a required_outputs key is reported by validate/2 (valid: false)" do
      graph =
        one_task(human("t", ["decision"], %{"required_outputs" => ["decision"]}), @condition)

      result = SemanticValidation.validate(graph, %{})

      assert result.valid == false
      assert sem_codes(result) == [:required_output_without_variable_schema]
      assert hd(result.violations).message =~ "Node 't'"
      assert hd(result.violations).message =~ "'decision'"
    end

    test "empty declared_fields, one violation per key and node" do
      graph =
        chain(
          [human("t1", ["decision"], %{"required_outputs" => ["a", "b"]})],
          human("t2", ["decision"], %{"required_outputs" => ["a"]}),
          @condition
        )

      assert length(SemanticValidation.validate(graph, %{}).violations) == 3
    end

    test "valid neighbour: the exemption still applies to everything else (no required_outputs: still valid)" do
      graph = one_task(human("t", ["decision"], %{}), "ghost == 1")

      assert SemanticValidation.validate(graph, %{}) == %{valid: true, violations: []}
    end

    test "the empty clause returns ONLY check 2: no other class leaks into it" do
      graph = one_task(human("t", [], %{"required_outputs" => ["decision"]}), "ghost == 1")

      assert sem_codes(SemanticValidation.validate(graph, %{})) ==
               [:required_output_without_variable_schema]
    end
  end

  # =======================================================================================
  # Check 3 -- decision_key_not_required: WARNING
  # =======================================================================================

  describe "check 3 -- decision_key_warnings/2" do
    test "a HUMAN_TASK edge reading a key its own form collects, with no required_outputs, is one warning naming the key, definition, edge and producer" do
      graph = one_task(human("t", ["decision"], %{}), @condition)

      assert [warning] = SemanticValidation.decision_key_warnings(graph, "my-def")
      assert is_binary(warning)
      assert String.starts_with?(warning, "decision_key_not_required:")
      assert warning =~ "decision"
      assert warning =~ "my-def"
      assert warning =~ "'e-cond'"
      assert warning =~ "node 't'"
      assert warning =~ "produced by: t"
    end

    test "valid neighbour: required_outputs: [decision] on that task yields no warning" do
      graph =
        one_task(human("t", ["decision"], %{"required_outputs" => ["decision"]}), @condition)

      assert SemanticValidation.decision_key_warnings(graph, "my-def") == []
    end

    test "an upstream HUMAN_TASK that collects the key, read on an EXCLUSIVE_GATEWAY edge, warns; declared upstream does not" do
      gateway = node("gw", "EXCLUSIVE_GATEWAY")

      undeclared = chain([human("t", ["decision"], %{})], gateway, @condition)
      assert [warning] = SemanticValidation.decision_key_warnings(undeclared, "d")
      assert warning =~ "node 'gw'"
      assert warning =~ "produced by: t"

      declared =
        chain(
          [human("t", ["decision"], %{"required_outputs" => ["decision"]})],
          gateway,
          @condition
        )

      assert SemanticValidation.decision_key_warnings(declared, "d") == []
    end

    test "a later HUMAN_TASK reading a key an ancestor collects: warns, unless that ancestor declares it" do
      reader = human("t2", ["note"], %{})

      undeclared = chain([human("t1", ["decision"], %{})], reader, @condition)
      assert [warning] = SemanticValidation.decision_key_warnings(undeclared, "d")
      assert warning =~ "node 't2'"
      assert warning =~ "produced by: t1"

      declared =
        chain(
          [human("t1", ["decision"], %{"required_outputs" => ["decision"]})],
          reader,
          @condition
        )

      assert SemanticValidation.decision_key_warnings(declared, "d") == []
    end

    test "the key counts as declared by ANY upstream HUMAN_TASK, not only the producer" do
      graph =
        chain(
          [
            human("t1", ["decision"], %{}),
            human("t2", [], %{"required_outputs" => ["decision"]})
          ],
          human("t3", ["note"], %{}),
          @condition
        )

      assert SemanticValidation.decision_key_warnings(graph, "d") == []
    end

    test "a declaration on a node that is NOT an ancestor-or-self of the reader does not suppress the warning" do
      # start -> t (collects decision, reads it) ; start -> other (declares it, sibling branch).
      graph =
        build!(
          [
            node("start", "START"),
            human("t", ["decision"], %{}),
            human("other", ["decision"], %{"required_outputs" => ["decision"]}),
            node("end-a", "END"),
            node("end-b", "END"),
            node("end-c", "END")
          ],
          [
            edge("c0", "start", "t"),
            edge("c1", "start", "other"),
            edge("c2", "other", "end-c"),
            cond_edge("e-cond", "t", "end-a", @condition),
            default_edge("e-def", "t", "end-b")
          ]
        )

      assert [warning] = SemanticValidation.decision_key_warnings(graph, "d")
      assert warning =~ "produced by: t"
    end

    test "a key no HUMAN_TASK produces (service response, start variable) yields no warning" do
      # A service task upstream, and a human form that collects only `note`.
      via_service = chain([service("svc")], human("t", ["note"], %{}), @condition)
      assert SemanticValidation.decision_key_warnings(via_service, "d") == []

      # Nothing at all upstream collects `decision` (it would be a start variable).
      via_start = one_task(human("t", ["note"], %{}), @condition)
      assert SemanticValidation.decision_key_warnings(via_start, "d") == []

      # An open HUMAN_TASK (no form_schema) is not a producer of a NAMED key.
      open = one_task(node("t", "HUMAN_TASK", %{"role" => "approver"}), @condition)
      assert SemanticValidation.decision_key_warnings(open, "d") == []
    end

    test "a producer DOWNSTREAM of the reader does not count" do
      graph =
        build!(
          [
            node("start", "START"),
            human("t1", ["note"], %{}),
            human("t2", ["decision"], %{}),
            node("end", "END"),
            node("end-b", "END")
          ],
          [
            edge("c0", "start", "t1"),
            cond_edge("e-cond", "t1", "t2", @condition),
            default_edge("e-def", "t1", "end-b"),
            edge("c1", "t2", "end")
          ]
        )

      assert SemanticValidation.decision_key_warnings(graph, "d") == []
    end

    test "one warning per (edge, key), keys in order of first appearance; a nested path warns on its root" do
      graph =
        one_task(
          human("t", ["risk", "decision"], %{}),
          "decision == \"approved\" and risk > 1 and decision.inner == 2"
        )

      assert [first, second] = SemanticValidation.decision_key_warnings(graph, "d")
      assert first =~ "decision_key_not_required: decision "
      assert second =~ "decision_key_not_required: risk "
    end

    test "a producer list is sorted when several upstream HUMAN_TASKs collect the key" do
      graph =
        chain(
          [human("zeta", ["decision"], %{}), human("alpha", ["decision"], %{})],
          human("t", ["note"], %{}),
          @condition
        )

      assert [warning] = SemanticValidation.decision_key_warnings(graph, "d")
      assert warning =~ "produced by: alpha, zeta"
    end

    test "a blank or unparsable condition and an unconditional edge yield none and never raise" do
      for condition <- ["", "   ", "decision ==", "))(("] do
        graph = one_task(human("t", ["decision"], %{}), condition)
        assert is_list(SemanticValidation.decision_key_warnings(graph, "d"))
      end

      blank = one_task(human("t", ["decision"], %{}), "")
      assert SemanticValidation.decision_key_warnings(blank, "d") == []
    end

    test "the warning is never a violation: validate/2 stays valid with the key declared, and Graph attribute check is clean" do
      graph = one_task(human("t", ["decision"], %{}), @condition)

      assert [_warning] = SemanticValidation.decision_key_warnings(graph, "d")
      assert %{valid: true, violations: []} = SemanticValidation.validate(graph, @declared)
      assert %{valid: true, violations: []} = SemanticValidation.validate(graph, %{})
      assert Graph.validate_node_attributes(graph) == %{valid: true, violations: []}
    end
  end
end
