defmodule Letflow.Definitions.SolutionPackOverrideMergeTest do
  @moduledoc """
  REQ-610 / GH #3419 criterion 1: the pure merge of an installed graph with an override patch
  (design ids M1..M4). No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.SolutionPackOverrideMerge, as: Merge

  @wide %{"process_definition" => [{"\\Anodes\\..+\\z", :text}, {"\\A[a-z_]+\\..+\\z", :text}]}

  defp graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START", "label" => "Start"},
        %{
          "id" => "t1",
          "node_type" => "HUMAN_TASK",
          "label" => "Approve",
          "attributes" => %{"role" => "approver", "script_key" => "k1"}
        },
        %{"id" => "t2", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "clerk"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "t1", "condition" => nil},
        %{"id" => "e2", "source" => "t1", "target" => "t2", "condition" => "x > 1"},
        %{"id" => "e3", "source" => "t2", "target" => "end"}
      ]
    }
  end

  test "M1: the patched paths are replaced and nothing else changes" do
    patch = %{
      "nodes.t1.attributes.role" => "boss",
      "nodes.t1.label" => "Sign off",
      "nodes.t2.attributes.escalation_timer_duration" => "PT1H"
    }

    assert {:ok, effective} = Merge.merge(graph(), patch)

    expected =
      graph()
      |> put_in(["nodes", Access.at(1), "attributes", "role"], "boss")
      |> put_in(["nodes", Access.at(1), "label"], "Sign off")
      |> put_in(["nodes", Access.at(2), "attributes", "escalation_timer_duration"], "PT1H")

    assert effective == expected
    assert effective["edges"] == graph()["edges"]
  end

  test "M1b: a node without attributes gets the attributes map created" do
    assert {:ok, effective} = Merge.merge(graph(), %{"nodes.end.attributes.role" => "r"})
    assert Enum.at(effective["nodes"], 3)["attributes"] == %{"role" => "r"}
  end

  test "M2: a path off the closed list refuses the whole patch" do
    for bad <- ["nodes.t1.id", "edges.0.target", "nodes.t1.attributes.script_key", "foo"] do
      assert {:error, :property_not_overridable} =
               Merge.merge(graph(), %{"nodes.t1.label" => "ok", bad => "x"})
    end
  end

  test "M3: with a widened list, structural changes are refused" do
    for path <- [
          "nodes.t1.id",
          "nodes.t1.node_type",
          "edges.e2.condition",
          "variables.v.type",
          "nodes.t1.attributes.script_key",
          "nodes.missing.label"
        ] do
      assert {:error, :override_changes_structure} = Merge.merge(graph(), %{path => "x"}, @wide),
             path
    end
  end

  test "M4: an empty patch and settings.* keys leave the graph unchanged" do
    assert {:ok, graph()} == Merge.merge(graph(), %{})
    assert {:ok, graph()} == Merge.merge(graph(), %{"settings.threshold" => 5})
  end
end
