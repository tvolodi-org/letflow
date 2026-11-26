defmodule Letflow.Engine.WriteTargetsTest do
  @moduledoc """
  T-2430: the pure rule of `Letflow.Engine.WriteTargets`. Tests: WTU-1 the keys a graph reads, WTU-2 the
  refusal, WTU-3 `completer_inputs` and WTU-3b the node's own `form_schema` properties are the only
  ways a person supplies a target (and only at that node), WTU-4 total on malformed input (INV-8). The HTTP half is `write_targets_route_test.exs`
  of the stock and assets modules.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.WriteTargets

  defp graph(nodes) do
    {:ok, g} =
      Graph.from_map(%{
        "nodes" =>
          [%{"id" => "start", "node_type" => "START"}] ++
            nodes ++ [%{"id" => "end", "node_type" => "END"}],
        "edges" => []
      })

    g
  end

  defp human(id, attributes),
    do: %{"id" => id, "node_type" => "HUMAN_TASK", "attributes" => attributes}

  defp service_task(id, attributes),
    do: %{"id" => id, "node_type" => "SERVICE_TASK", "attributes" => attributes}

  defp writes(args), do: [%{"module" => "stock", "handler" => "post_document", "args" => args}]

  defp g1 do
    graph([
      human("submit", %{"role" => "A"}),
      human("approve", %{
        "module_writes" =>
          writes(%{
            "document_id" => %{"var" => "document_id"},
            "posting" => %{"var" => "posting_var"},
            "fixed" => %{"const" => "x"}
          })
      })
    ])
  end

  test "WTU-1 the keys read are the var sources of every node, never the arg names or consts" do
    assert WriteTargets.write_read_keys(g1()) == MapSet.new(["document_id", "posting_var"])
    assert WriteTargets.write_read_keys(graph([human("t", %{})])) == MapSet.new()
    assert WriteTargets.write_read_keys(nil) == MapSet.new()
  end

  test "WTU-2 a key read by ANY node is refused at any node, others pass" do
    out = %{"document_id" => 1, "posting_var" => 2, "posting" => 3, "note" => 4, "_sys" => 5}
    assert WriteTargets.refused_keys(g1(), "approve", out) == ["document_id", "posting_var"]
    # the earlier `submit` node too: the key is the instance's target whoever completes
    assert WriteTargets.refused_keys(g1(), "submit", out) == ["document_id", "posting_var"]
    assert WriteTargets.refused_keys(g1(), "approve", %{"note" => 1}) == []
    assert WriteTargets.refused_keys(g1(), "approve", %{}) == []
  end

  test "WTU-3 completer_inputs lifts the refusal for that key at that node only" do
    g =
      graph([
        human("fill", %{"completer_inputs" => ["document_id", "", 7]}),
        human("approve", %{
          "module_writes" =>
            writes(%{
              "document_id" => %{"var" => "document_id"},
              "mark" => %{"var" => "mark"}
            })
        })
      ])

    out = %{"document_id" => 1, "mark" => 2}
    assert WriteTargets.refused_keys(g, "fill", out) == ["mark"]
    assert WriteTargets.refused_keys(g, "approve", out) == ["document_id", "mark"]
    assert WriteTargets.refused_keys(g, "missing_node", out) == ["document_id", "mark"]
  end

  test "WTU-3b the properties of the node's own form_schema are declared inputs at that node only" do
    g =
      graph([
        human("fill", %{
          "form_schema" => %{"properties" => %{"work_done" => %{"type" => "string"}}}
        }),
        human("approve", %{
          "module_writes" => writes(%{"w" => %{"var" => "work_done"}, "d" => %{"var" => "doc"}})
        })
      ])

    out = %{"work_done" => 1, "doc" => 2}
    assert WriteTargets.refused_keys(g, "fill", out) == ["doc"]
    assert WriteTargets.refused_keys(g, "approve", out) == ["doc", "work_done"]
  end

  test "WTU-4 malformed attributes and arguments never raise and refuse the more" do
    g =
      graph([
        human("a", %{"completer_inputs" => "document_id", "form_schema" => "x"}),
        human("b", %{"module_writes" => "nope"}),
        human("c", %{"module_writes" => [%{"args" => "x"}, %{"module" => "m"}, 1]}),
        human("d", %{
          "module_writes" => writes(%{"x" => %{"var" => 5}, "y" => "z", "k" => %{"var" => "k"}})
        })
      ])

    assert WriteTargets.write_read_keys(g) == MapSet.new(["k"])
    assert WriteTargets.refused_keys(g, "a", %{"k" => 1}) == ["k"]
    assert WriteTargets.refused_keys(g, "a", "not a map") == []
    assert WriteTargets.refused_keys(:nope, "a", %{"k" => 1}) == []
  end

  test "WTU-5 the keys a NOTIFICATION step reads are refused like a write target" do
    # T-2592 (pilot gap G4): the recipient's variable and the variables of the
    # values are decided by the person who STARTED the process, never by the
    # person who completes a task in it. A CONSTANT value is not a key (it sits
    # in the definition, not in the instance).
    g =
      graph([
        human("submit", %{"role" => "A"}),
        service_task("notify", %{
          "notify" => %{
            "template_key" => "tenant_registered",
            "recipient" => %{"var" => "admin_email"},
            "values" => %{
              "tenant_name" => %{"var" => "tenant_name"},
              "tenant_slug" => %{"const" => "acme"}
            }
          }
        })
      ])

    assert WriteTargets.write_read_keys(g) == MapSet.new(["admin_email", "tenant_name"])

    assert WriteTargets.refused_keys(g, "submit", %{"admin_email" => "a@b.com", "note" => 1}) ==
             ["admin_email"]

    assert WriteTargets.refused_keys(g, "submit", %{"tenant_name" => "Acme"}) == ["tenant_name"]
    assert WriteTargets.refused_keys(g, "submit", %{"note" => 1}) == []
  end
end
