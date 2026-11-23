defmodule Letflow.Definitions.TestCasesTest do
  @moduledoc """
  The RUNNER of a definition's declared test cases (T-2604, the "Register a
  tenant" pilot, gap G16 -- the automatic test run before an activation).

  The runner walks the graph on the engine's own transition kernel, in memory:
  no instance, no row, no queue, no clock, no side effect. This file proves
  what the walk does:

  * a human task is completed when the case declares the completion, and the
    run WAITS when it does not;
  * a service task is FAKED: its declared outputs reach the variables and the
    token moves on;
  * a gateway takes the branch the start variables select;
  * the expectation is checked -- the status, the named variables and the
    nodes the run must have reached.

  `async: true`: the module performs no I/O, so it touches no shared state.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.TestCases

  # START -> HUMAN_TASK `review` -> END
  defp human_task_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "review",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "REVIEWER"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "review"},
        %{"id" => "e2", "source" => "review", "target" => "end"}
      ]
    }
  end

  # START -> SERVICE_TASK `call` -> END
  defp service_task_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "call", "node_type" => "SERVICE_TASK"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }
  end

  # START -> EXCLUSIVE_GATEWAY `gw` -> (approved -> end_a) | (default -> end_b)
  defp gateway_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end_a", "node_type" => "END"},
        %{"id" => "end_b", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gw"},
        %{
          "id" => "e2",
          "source" => "gw",
          "target" => "end_a",
          "condition" => "variables.approved == true"
        },
        %{"id" => "e3", "source" => "gw", "target" => "end_b", "is_default" => true}
      ]
    }
  end

  defp parse!(case_body) do
    assert {:ok, [parsed]} = TestCases.parse([case_body])
    parsed
  end

  describe "parse/1 -- the declaration" do
    test "no declaration is no case" do
      assert TestCases.parse(nil) == {:ok, []}
      assert TestCases.parse([]) == {:ok, []}
    end

    test "a case without a name is refused with a closed code" do
      assert {:error, {:invalid_test_cases, :name_required}} = TestCases.parse([%{}])
    end

    test "a case that is not an object is refused with a closed code" do
      assert {:error, {:invalid_test_cases, :not_an_object}} = TestCases.parse(["nope"])
    end

    test "a case without an expectation is refused with a closed code" do
      assert {:error, {:invalid_test_cases, :expect_required}} =
               TestCases.parse([%{"name" => "a case"}])
    end

    test "a start variable that is not a scalar is refused with a closed code" do
      assert {:error, {:invalid_test_cases, :invalid_start_variable}} =
               TestCases.parse([
                 %{"name" => "a case", "start_variables" => %{"a" => %{"b" => 1}}}
               ])
    end

    test "an unknown expected status is refused with a closed code" do
      assert {:error, {:invalid_test_cases, :invalid_expected_status}} =
               TestCases.parse([%{"name" => "a case", "expect" => %{"status" => "maybe"}}])
    end
  end

  describe "run/2 -- the walk" do
    test "a case that holds passes" do
      parsed =
        parse!(%{
          "name" => "the applicant is approved",
          "complete_tasks" => [
            %{"node_id" => "review", "outputs" => %{"approved" => true}}
          ],
          "expect" => %{
            "status" => "completed",
            "variables" => %{"approved" => true},
            "visited_nodes" => ["start", "review", "end"]
          }
        })

      assert :ok = TestCases.run(human_task_graph(), [parsed])
    end

    test "a case whose variable does not hold fails with the variable's name" do
      parsed =
        parse!(%{
          "name" => "the applicant is approved",
          "complete_tasks" => [
            %{"node_id" => "review", "outputs" => %{"approved" => true}}
          ],
          "expect" => %{"variables" => %{"approved" => false}}
        })

      assert {:error, {:definition_test_cases_failed, [failure]}} =
               TestCases.run(human_task_graph(), [parsed])

      assert %{name: "the applicant is approved", reason: :variable_mismatch, key: "approved"} =
               failure
    end

    test "a case that expects a variable the run never wrote fails as missing" do
      parsed =
        parse!(%{
          "name" => "the applicant is approved",
          "complete_tasks" => [
            %{"node_id" => "review", "outputs" => %{"approved" => true}}
          ],
          "expect" => %{"variables" => %{"tenant_id" => "t-1"}}
        })

      assert {:error, {:definition_test_cases_failed, [failure]}} =
               TestCases.run(human_task_graph(), [parsed])

      assert %{reason: :variable_missing, key: "tenant_id"} = failure
    end

    test "a run that waits at a human task does not complete" do
      parsed =
        parse!(%{
          "name" => "the applicant is approved",
          "expect" => %{"status" => "completed"}
        })

      assert {:error, {:definition_test_cases_failed, [failure]}} =
               TestCases.run(human_task_graph(), [parsed])

      assert %{reason: :status_mismatch} = failure
    end

    test "a run that waits at a human task is a waiting run" do
      parsed =
        parse!(%{
          "name" => "the applicant is approved",
          "expect" => %{"status" => "waiting", "visited_nodes" => ["review"]}
        })

      assert :ok = TestCases.run(human_task_graph(), [parsed])
    end

    test "a node the run never reached fails with the node's name" do
      parsed =
        parse!(%{
          "name" => "the applicant is approved",
          "complete_tasks" => [
            %{"node_id" => "review", "outputs" => %{"approved" => true}}
          ],
          "expect" => %{"visited_nodes" => ["nowhere"]}
        })

      assert {:error, {:definition_test_cases_failed, [failure]}} =
               TestCases.run(human_task_graph(), [parsed])

      assert %{reason: :node_not_visited, key: "nowhere"} = failure
    end

    test "a service task is faked: its declared outputs reach the variables" do
      parsed =
        parse!(%{
          "name" => "the tenant is created",
          "step_outputs" => %{"call" => %{"tenant_id" => "t-1"}},
          "expect" => %{
            "status" => "completed",
            "variables" => %{"tenant_id" => "t-1"},
            "visited_nodes" => ["start", "call", "end"]
          }
        })

      assert :ok = TestCases.run(service_task_graph(), [parsed])
    end

    test "a service task with no declared output still moves the token on" do
      parsed =
        parse!(%{
          "name" => "the tenant is created",
          "expect" => %{"status" => "completed", "visited_nodes" => ["call", "end"]}
        })

      assert :ok = TestCases.run(service_task_graph(), [parsed])
    end

    test "a gateway takes the branch the start variables select" do
      parsed =
        parse!(%{
          "name" => "the applicant is approved",
          "start_variables" => %{"approved" => true},
          "expect" => %{"status" => "completed", "visited_nodes" => ["gw", "end_a"]}
        })

      assert :ok = TestCases.run(gateway_graph(), [parsed])
    end

    test "a gateway takes the default branch when no condition holds" do
      parsed =
        parse!(%{
          "name" => "the applicant is rejected",
          "start_variables" => %{"approved" => false},
          "expect" => %{"status" => "completed", "visited_nodes" => ["gw", "end_b"]}
        })

      assert :ok = TestCases.run(gateway_graph(), [parsed])
    end

    test "a graph that cannot be read is refused, never raised" do
      parsed = parse!(%{"name" => "a case", "expect" => %{"status" => "completed"}})

      assert {:error, {:definition_test_cases_invalid, :graph_structure_invalid}} =
               TestCases.run(%{"nodes" => "not a list", "edges" => []}, [parsed])
    end
  end
end
