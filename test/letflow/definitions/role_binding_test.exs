defmodule Letflow.Definitions.RoleBindingTest do
  @moduledoc """
  Pure unit tests for the no-I/O half of `Letflow.Definitions.RoleBinding`
  (REQ-455 check 4): `task_roles/1`, `unbound/2`, `format_warning/2`. The DB-backed
  half (`bound_role_names/1`, install, validate) is in `role_binding_install_test.exs`.

  `async: true`, no I/O, no clock, no randomness.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Definitions.RoleBinding

  defp human(id, attributes), do: %Node{id: id, node_type: :HUMAN_TASK, attributes: attributes}
  defp graph(nodes), do: %Graph{nodes: nodes, edges: []}

  describe "task_roles/1" do
    test "collects role and escalation_role of human tasks, grouped by name, names and node ids sorted and deduplicated" do
      g =
        graph([
          human("z-task", %{"role" => "role-b", "escalation_role" => "role-a"}),
          human("a-task", %{"role" => "role-b"}),
          human("m-task", %{"role" => "role-a", "escalation_role" => "role-a"})
        ])

      assert RoleBinding.task_roles(g) == [
               %{role_name: "role-a", node_ids: ["m-task", "z-task"]},
               %{role_name: "role-b", node_ids: ["a-task", "z-task"]}
             ]
    end

    test "ignores non-human nodes, blank or non-binary roles and non-map attributes without raising" do
      g =
        graph([
          %Node{id: "svc", node_type: :SERVICE_TASK, attributes: %{"role" => "role-svc"}},
          human("blank", %{"role" => "   ", "escalation_role" => ""}),
          human("num", %{"role" => 5}),
          human("nil-attrs", nil),
          human("list-attrs", ["role"])
        ])

      assert RoleBinding.task_roles(g) == []
    end

    test "REQ-494: collects reminder_role of human tasks" do
      g = graph([human("a", %{"role" => "role-a", "reminder_role" => "role-r"})])

      assert RoleBinding.task_roles(g) == [
               %{role_name: "role-a", node_ids: ["a"]},
               %{role_name: "role-r", node_ids: ["a"]}
             ]
    end

    test "role names are used raw (not trimmed), matching the exact-name tenant_role index" do
      g = graph([human("t", %{"role" => " padded "})])
      assert [%{role_name: " padded "}] = RoleBinding.task_roles(g)
    end
  end

  describe "unbound/2" do
    test "keeps only roles absent from the bound set, order preserved" do
      roles = [
        %{role_name: "bound", node_ids: ["a"]},
        %{role_name: "loose-1", node_ids: ["b"]},
        %{role_name: "loose-2", node_ids: ["c"]}
      ]

      assert RoleBinding.unbound(roles, MapSet.new(["bound"])) == [
               %{role_name: "loose-1", node_ids: ["b"]},
               %{role_name: "loose-2", node_ids: ["c"]}
             ]

      assert RoleBinding.unbound(roles, MapSet.new(["bound", "loose-1", "loose-2"])) == []
    end
  end

  describe "format_warning/2" do
    test "builds the stable wire text with the unbound_task_role: prefix, definition and node ids" do
      assert RoleBinding.format_warning("kyc", %{role_name: "role-x", node_ids: ["n1", "n2"]}) ==
               "unbound_task_role: role-x (definition 'kyc', nodes: n1, n2)"
    end
  end
end
