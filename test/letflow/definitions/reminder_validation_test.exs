defmodule Letflow.Definitions.ReminderValidationTest do
  @moduledoc """
  REQ-494 AC10: CHK-28 (`check_human_task_reminder/1`, run by
  `Graph.validate_node_attributes/1`) and `Graph.parse_reminder_repeat_interval/1`.

  Design: `lib/letflow/design/req494-human-task-reminder-timer.md` section 6 and test
  matrix rows T-10 / T-10b. Pure, no I/O, `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node

  @node_id "h-reminder"

  defp graph_with(attributes) do
    node = %Node{
      id: @node_id,
      node_type: :HUMAN_TASK,
      attributes: Map.merge(%{"role" => "approver"}, attributes)
    }

    %Graph{nodes: [node], edges: []}
  end

  defp pair(duration), do: %{"reminder_timer_duration" => duration, "reminder_role" => "r-remind"}

  defp codes(%{violations: violations}), do: Enum.map(violations, & &1.code)

  defp assert_single_violation!(attributes, code) do
    result = Graph.validate_node_attributes(graph_with(attributes))

    assert codes(result) == [code],
           "expected [#{inspect(code)}] for #{inspect(attributes)}, got #{inspect(codes(result))}"

    assert result.valid == false
    assert [violation] = result.violations
    assert violation.message =~ @node_id
  end

  defp assert_valid!(attributes) do
    assert Graph.validate_node_attributes(graph_with(attributes)) == %{
             valid: true,
             violations: []
           },
           "expected no violation for #{inspect(attributes)}"
  end

  describe "CHK-28 pair codes" do
    test "an invalid reminder_timer_duration -> :invalid_reminder_timer" do
      assert_single_violation!(pair("NOT-ISO"), :invalid_reminder_timer)
    end

    test "a duration without a non-blank role -> :missing_reminder_role" do
      for role <- [nil, "", "   "] do
        assert_single_violation!(
          %{"reminder_timer_duration" => "PT1H", "reminder_role" => role},
          :missing_reminder_role
        )
      end

      assert_single_violation!(%{"reminder_timer_duration" => "PT1H"}, :missing_reminder_role)
    end

    test "a role without a duration -> :missing_reminder_timer_duration" do
      assert_single_violation!(%{"reminder_role" => "r-remind"}, :missing_reminder_timer_duration)
    end
  end

  describe "CHK-28 :invalid_reminder_repeat" do
    test "an interval without the pair" do
      assert_single_violation!(%{"reminder_repeat_interval" => "PT1H"}, :invalid_reminder_repeat)
    end

    test "a count without an interval" do
      assert_single_violation!(
        Map.put(pair("PT1H"), "reminder_repeat_count", 2),
        :invalid_reminder_repeat
      )
    end

    test "a count outside 1..50 or not an integer" do
      for count <- [51, 0, 2.0, "2", true] do
        assert_single_violation!(
          pair("PT1H")
          |> Map.put("reminder_repeat_interval", "PT1H")
          |> Map.put("reminder_repeat_count", count),
          :invalid_reminder_repeat
        )
      end
    end

    test "a zero, calendar-unit or malformed interval" do
      for interval <- ["P0D", "PT0S", "P1M", "P1Y", "NOT-ISO"] do
        assert_single_violation!(
          Map.put(pair("PT1H"), "reminder_repeat_interval", interval),
          :invalid_reminder_repeat
        )
      end
    end
  end

  describe "CHK-28 valid shapes" do
    test "the pair alone, with P0D duration, with an interval only, and with interval + count 50" do
      assert_valid!(pair("PT1H"))
      assert_valid!(pair("P0D"))
      assert_valid!(Map.put(pair("PT1H"), "reminder_repeat_interval", "PT1H"))
      assert_valid!(Map.put(pair("PT1H"), "reminder_repeat_interval", "P1W"))
      assert_valid!(Map.put(pair("PT1H"), "reminder_repeat_interval", "PT1M"))

      assert_valid!(
        pair("PT1H")
        |> Map.put("reminder_repeat_interval", "PT1H")
        |> Map.put("reminder_repeat_count", 50)
      )
    end

    test "a HUMAN_TASK with no reminder_* keys is untouched" do
      assert_valid!(%{})
    end
  end

  describe "Graph.parse_reminder_repeat_interval/1" do
    test "fixed-length positive intervals parse to seconds" do
      assert Graph.parse_reminder_repeat_interval("PT1H") == {:ok, 3600}
      assert Graph.parse_reminder_repeat_interval("P1W") == {:ok, 604_800}
      assert Graph.parse_reminder_repeat_interval("P1DT2H") == {:ok, 93_600}
      assert Graph.parse_reminder_repeat_interval("PT30M") == {:ok, 1800}
      assert Graph.parse_reminder_repeat_interval("PT1M") == {:ok, 60}
    end

    test "zero, calendar units, malformed and non-binary values are :error" do
      for value <- ["P0D", "PT0S", "P1M", "P1Y", "P1Y2D", "P1MT1H", "NOT-ISO", 3600, nil] do
        assert Graph.parse_reminder_repeat_interval(value) == :error,
               "expected :error for #{inspect(value)}"
      end
    end
  end
end
