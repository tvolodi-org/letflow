defmodule Letflow.Definitions.ReservedReferencesTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A1b (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  2A.2, 2A.6): `Letflow.Definitions.ReservedReferences` finds every place a graph names the
  reserved engine namespace (L1-L8), by parsing, and nothing else. Pure.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ReservedReferences
  alias Letflow.Engine.ServiceTask

  # ── graph builders ─────────────────────────────────────────────────────────

  defp graph!(nodes, edges) do
    {:ok, graph} = Graph.from_map(%{"nodes" => nodes, "edges" => edges})
    graph
  end

  defp start, do: %{"id" => "start", "node_type" => "START"}
  defp finish, do: %{"id" => "end", "node_type" => "END"}

  # START -> <source node> -> END twice, the second edge carrying `condition`.
  defp conditioned_graph(source_node, condition) do
    graph!(
      [start(), source_node, finish()],
      [
        %{"id" => "e1", "source" => "start", "target" => source_node["id"]},
        %{
          "id" => "e2",
          "source" => source_node["id"],
          "target" => "end",
          "condition" => condition
        },
        %{"id" => "e3", "source" => source_node["id"], "target" => "end", "is_default" => true}
      ]
    )
  end

  defp gateway, do: %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"}

  defp human(attrs \\ %{}),
    do: %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => Map.put(attrs, "role", "R")}

  defp node_graph(node),
    do:
      graph!([start(), node, finish()], [
        %{"id" => "e1", "source" => "start", "target" => node["id"]},
        %{"id" => "e2", "source" => node["id"], "target" => "end"}
      ])

  defp service(attrs),
    do: %{"id" => "svc", "node_type" => "SERVICE_TASK", "attributes" => attrs}

  defp sub_process(interface),
    do: %{
      "id" => "sp",
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"interface" => interface}
    }

  defp entry(name), do: %{"name" => name, "json_schema" => %{"type" => "string"}}

  defp form(properties),
    do: human(%{"form_schema" => %{"type" => "object", "properties" => properties}})

  defp edge_ref(id, name),
    do: %{element: :edge, id: id, location: :edge_condition, field: nil, name: name}

  defp node_ref(id, location, field, name),
    do: %{element: :node, id: id, location: location, field: field, name: name}

  # ── L1 edge conditions ─────────────────────────────────────────────────────

  describe "L1 edge condition" do
    test "a nested reserved path on an EXCLUSIVE_GATEWAY edge" do
      graph = conditioned_graph(gateway(), "variables._sys.r.seq > 0")
      assert ReservedReferences.find(graph) == [edge_ref("e2", "_sys.r.seq")]
    end

    test "the same on a HUMAN_TASK outgoing edge" do
      graph = conditioned_graph(human(), "variables._sys.r.seq > 0")
      assert ReservedReferences.find(graph) == [edge_ref("e2", "_sys.r.seq")]
    end

    test "the bare reserved name" do
      graph = conditioned_graph(gateway(), "_sys == null")
      assert ReservedReferences.find(graph) == [edge_ref("e2", "_sys")]
    end

    test "a name named twice in one condition is reported once" do
      graph = conditioned_graph(gateway(), "_sys == 1 || _sys == 2")
      assert ReservedReferences.find(graph) == [edge_ref("e2", "_sys")]
    end
  end

  # ── L2-L4 form x-ui ────────────────────────────────────────────────────────

  describe "L2-L4 form x-ui expressions" do
    test "visible_when, computed and cross_field_validation, fields sorted by name" do
      graph =
        node_graph(
          form(%{
            "_sys" => %{"type" => "boolean"},
            "c" => %{
              "type" => "string",
              "x-ui" => %{
                "cross_field_validation" => %{"expression" => "_sys != null", "message" => "m"}
              }
            },
            "b" => %{"type" => "boolean", "x-ui" => %{"computed" => "_sys"}},
            "a" => %{"type" => "string", "x-ui" => %{"visible_when" => "_sys == true"}}
          })
        )

      assert ReservedReferences.find(graph) == [
               node_ref("ht", :form_visible_when, "a", "_sys"),
               node_ref("ht", :form_computed, "b", "_sys"),
               node_ref("ht", :form_cross_field_validation, "c", "_sys")
             ]
    end

    test "one field's three keys in the fixed order" do
      graph =
        node_graph(
          form(%{
            "_sys" => %{"type" => "boolean"},
            "a" => %{
              "type" => "boolean",
              "x-ui" => %{
                "cross_field_validation" => %{"expression" => "_sys != null", "message" => "m"},
                "computed" => "_sys",
                "visible_when" => "_sys == true"
              }
            }
          })
        )

      assert Enum.map(ReservedReferences.find(graph), & &1.location) == [
               :form_visible_when,
               :form_computed,
               :form_cross_field_validation
             ]
    end
  end

  # ── L5-L6 templates ────────────────────────────────────────────────────────

  describe "L5-L6 service-task templates" do
    test "endpoint placeholder" do
      graph = node_graph(service(%{"endpoint" => "https://x/{{variables._sys}}"}))

      assert ReservedReferences.find(graph) == [
               node_ref("svc", :service_task_endpoint, nil, "_sys")
             ]
    end

    test "body_template placeholder (spaces inside the braces)" do
      graph =
        node_graph(
          service(%{
            "endpoint" => "https://x/",
            "body_template" => "{\"a\":\"{{ variables._sys }}\"}"
          })
        )

      assert ReservedReferences.find(graph) == [
               node_ref("svc", :service_task_body_template, nil, "_sys")
             ]
    end
  end

  # ── L7-L8 interface ────────────────────────────────────────────────────────

  describe "L7-L8 sub-process interface" do
    test "a reserved-prefixed input and output entry (whole name, not a head-only == check)" do
      graph =
        node_graph(
          sub_process(%{
            "inputs" => [entry("ok"), entry("_sys.x")],
            "outputs" => [entry("_sys.x")]
          })
        )

      assert ReservedReferences.find(graph) == [
               node_ref("sp", :sub_process_input, "_sys.x", "_sys.x"),
               node_ref("sp", :sub_process_output, "_sys.x", "_sys.x")
             ]
    end

    test "the bare reserved name as an entry" do
      graph = node_graph(sub_process(%{"inputs" => [entry("_sys")]}))

      assert ReservedReferences.find(graph) == [
               node_ref("sp", :sub_process_input, "_sys", "_sys")
             ]
    end
  end

  # ── non-references ─────────────────────────────────────────────────────────

  describe "non-references are []" do
    for condition <- [
          ~s(x == "_sys.r"),
          ~s[contains(name, "_sys")],
          "variables.variables_x == 1",
          "_system == 1",
          "a._sys == 1",
          "_sys ==",
          ""
        ] do
      test "condition #{inspect(condition)}" do
        assert ReservedReferences.find(conditioned_graph(gateway(), unquote(condition))) == []
      end
    end

    test "template {{variables._system}}, reserved text outside a placeholder, dotted key" do
      for template <- [
            "https://x/{{variables._system}}",
            "https://x/_sys/{{variables.order_id}}",
            "https://x/{{variables._sys.r}}"
          ] do
        assert ReservedReferences.find(node_graph(service(%{"endpoint" => template}))) == []
      end
    end

    test "interface entry _system, and a malformed interface" do
      assert ReservedReferences.find(node_graph(sub_process(%{"inputs" => [entry("_system")]}))) ==
               []

      assert ReservedReferences.find(node_graph(sub_process("not a map"))) == []
    end

    test "a form expression on a property that is not reserved, and malformed attributes" do
      graph =
        node_graph(form(%{"a" => %{"type" => "boolean", "x-ui" => %{"visible_when" => "a"}}}))

      assert ReservedReferences.find(graph) == []

      for attrs <- [nil, "x", %{"form_schema" => "x"}, %{"form_schema" => %{"properties" => 1}}] do
        node = %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => attrs}
        assert ReservedReferences.find(node_graph(node)) == []
      end
    end

    # TDV F2: the form path parses too; a raw-text scan of these expressions would flag them.
    test "form expressions: a string literal and an identifier that merely starts alike" do
      graph =
        node_graph(
          form(%{
            "_system" => %{"type" => "string"},
            "x" => %{"type" => "string", "x-ui" => %{"visible_when" => "x == '_sys'"}},
            "y" => %{"type" => "string", "x-ui" => %{"computed" => "_system"}},
            "z" => %{
              "type" => "string",
              "x-ui" => %{
                "cross_field_validation" => %{
                  "expression" => ~s[contains(z, "_sys.r")],
                  "message" => "m"
                }
              }
            }
          })
        )

      assert ReservedReferences.find(graph) == []

      # each one parses, so [] comes from the AST, not from a parse failure
      for expression <- ["x == '_sys'", "_system", ~s[contains(z, "_sys.r")]] do
        assert {:ok, source} = Letflow.Engine.Expr.translate_cel_to_expr(expression)
        assert {:ok, _ast} = Letflow.Engine.Expr.parse_strict(source)
      end
    end

    test "a non-binary condition is no reference (total)" do
      graph = conditioned_graph(gateway(), 42)
      assert ReservedReferences.find(graph) == []
    end
  end

  # ── ordering and determinism ───────────────────────────────────────────────

  test "two nodes and two edges: nodes first, each in graph order; two calls are equal" do
    n1 = %{
      "id" => "n1",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{"endpoint" => "{{variables._sys}}"}
    }

    n2 = %{
      "id" => "n2",
      "node_type" => "SUB_PROCESS",
      "attributes" => %{"interface" => %{"inputs" => [entry("_sys")]}}
    }

    graph =
      graph!([start(), n1, n2, finish()], [
        %{"id" => "a1", "source" => "start", "target" => "n1", "condition" => "_sys == 1"},
        %{"id" => "a2", "source" => "n1", "target" => "n2", "condition" => "_sys.q == 2"},
        %{"id" => "a3", "source" => "n2", "target" => "end"}
      ])

    expected = [
      node_ref("n1", :service_task_endpoint, nil, "_sys"),
      node_ref("n2", :sub_process_input, "_sys", "_sys"),
      edge_ref("a1", "_sys"),
      edge_ref("a2", "_sys.q")
    ]

    assert ReservedReferences.find(graph) == expected
    assert ReservedReferences.find(graph) == ReservedReferences.find(graph)
    assert ReservedReferences.node_references(graph) == Enum.take(expected, 2)
    assert ReservedReferences.edge_references(graph) == Enum.drop(expected, 2)
  end

  # ── violations, reserved_path? ─────────────────────────────────────────────

  test "violations/1: one violation per reference with the stable code and message" do
    refs = [
      edge_ref("e2", "_sys.r"),
      node_ref("ht", :form_visible_when, "a", "_sys"),
      node_ref("svc", :script_input, "_sys.r", "_sys.r")
    ]

    assert [
             %Graph.Violation{code: :expression_references_reserved_variable, message: m1},
             %Graph.Violation{code: :expression_references_reserved_variable, message: m2},
             %Graph.Violation{code: :expression_references_reserved_variable, message: m3}
           ] = ReservedReferences.violations(refs)

    assert m1 == "Edge 'e2' condition references the reserved variable '_sys.r'"

    assert m2 ==
             "Node 'ht' form x-ui.visible_when field 'a' references the reserved variable '_sys'"

    assert m3 ==
             "Node 'svc' bound script input field '_sys.r' references the reserved variable '_sys.r'"
  end

  test "reserved_path?/1 checks the head segment only" do
    assert ReservedReferences.reserved_path?(["_sys"])
    assert ReservedReferences.reserved_path?(["_sys", "r"])
    refute ReservedReferences.reserved_path?(["a", "_sys"])
    refute ReservedReferences.reserved_path?(["_system"])
    refute ReservedReferences.reserved_path?([])
  end

  # ── Graph CHK-29 / CHK-30 (save-time surface, pure) ────────────────────────

  test "CHK-29 is in validate_node_attributes/1 and CHK-30 in validate_edge_conditions/1" do
    node_graph = node_graph(service(%{"endpoint" => "https://x/{{variables._sys}}"}))
    edge_graph = conditioned_graph(gateway(), "_sys == 1")

    assert :expression_references_reserved_variable in Enum.map(
             Graph.validate_node_attributes(node_graph).violations,
             & &1.code
           )

    assert :expression_references_reserved_variable in Enum.map(
             Graph.validate_edge_conditions(edge_graph).violations,
             & &1.code
           )

    refute :expression_references_reserved_variable in Enum.map(
             Graph.validate_node_attributes(edge_graph).violations,
             & &1.code
           )
  end

  # ── ServiceTask placeholder grammar (one source of truth) ──────────────────

  describe "ServiceTask.template_placeholder/0 and template_variable_keys/1" do
    test "keys in order; nil -> []" do
      assert ServiceTask.template_variable_keys(nil) == []

      assert ServiceTask.template_variable_keys("{{variables.a}}/x/{{ variables.b_2 }}") ==
               ["a", "b_2"]
    end

    # SEC F1 (A1b gate, I-13): the KEY class is dot-free, so a placeholder can name only a flat
    # top-level key. Changing this pattern must ship the catalog check (GH #2623) in the same PR.
    test "the placeholder pattern is pinned and dot-free" do
      assert Regex.source(ServiceTask.template_placeholder()) ==
               "\\{\\{\\s*variables\\.([a-zA-Z0-9_]+)\\s*\\}\\}"

      assert ServiceTask.template_variable_keys("{{variables.a.b}}") == []
      refute Regex.source(ServiceTask.template_placeholder()) =~ "a-zA-Z0-9_."
    end
  end
end
