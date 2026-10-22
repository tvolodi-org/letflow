defmodule Letflow.Engine.VariableMergeLabelsTest do
  @moduledoc """
  Decision 0062 (GH #2616 part 1), pure units: T-1 `VariableMerge.merge/5` (the only writer of
  variable labels) and T-4 `Letflow.Engine.VariableLabels` (the one encoder of the label fields
  of event payloads). No database, so `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.VariableLabels
  alias Letflow.Engine.VariableMerge

  @salary ["customer.salary"]
  @ssn ["customer.ssn"]

  describe "T-1 merge/5" do
    test "an insert with labels stores the sorted, unique label list, no event" do
      assert {:ok, %{"x" => 1}, %{"x" => ["a.b", "c.d"]}, []} =
               VariableMerge.merge(%{}, %{}, %{"x" => 1}, %{"x" => ["c.d", "a.b", "a.b"]}, nil)
    end

    test "an overwrite replaces the labels and records old and new" do
      assert {:ok, %{"x" => 2}, %{"x" => @ssn},
              [{:variable_overwritten, "x", 1, 2, @salary, @ssn}]} =
               VariableMerge.merge(
                 %{"x" => 1},
                 %{"x" => @salary},
                 %{"x" => 2},
                 %{"x" => @ssn},
                 nil
               )
    end

    test "an unlabelled source removes the entry (R7a)" do
      assert {:ok, %{"x" => 2}, labels, [{:variable_overwritten, "x", 1, 2, @salary, []}]} =
               VariableMerge.merge(%{"x" => 1}, %{"x" => @salary}, %{"x" => 2}, %{}, nil)

      assert labels == %{}
    end

    test "an overwrite adding labels to an unlabelled variable" do
      assert {:ok, _vars, %{"x" => @salary}, [{:variable_overwritten, "x", 1, 2, [], @salary}]} =
               VariableMerge.merge(%{"x" => 1}, %{}, %{"x" => 2}, %{"x" => @salary}, nil)
    end

    test "labels of keys that are not incoming are untouched" do
      assert {:ok, %{"x" => 1, "y" => 2}, %{"x" => @salary}, []} =
               VariableMerge.merge(%{"x" => 1}, %{"x" => @salary}, %{"y" => 2}, %{}, nil)
    end

    test "a label for a key that is not incoming never creates an entry" do
      assert {:ok, %{"y" => 2}, labels, []} =
               VariableMerge.merge(%{}, %{}, %{"y" => 2}, %{"ghost" => @salary}, nil)

      assert labels == %{}
    end

    test "non-binary labels and non-list label values are dropped" do
      assert {:ok, _vars, labels, []} =
               VariableMerge.merge(
                 %{},
                 %{},
                 %{"x" => 1, "y" => 2},
                 %{"x" => ["a.b", 7, nil, :atom], "y" => "customer.salary"},
                 nil
               )

      assert labels == %{"x" => ["a.b"]}
    end

    test "a rejection returns the unchanged variables and leaves labels to the caller" do
      validations = %{"x" => {:rejected, []}}

      assert {:rejected, %{"x" => 1}, [{:execution_error, "x", 2, :variable_schema_rejected, []}]} =
               VariableMerge.merge(
                 %{"x" => 1},
                 %{"x" => @salary},
                 %{"x" => 2},
                 %{"x" => @ssn},
                 validations
               )
    end

    test "a reserved key is refused even when it carries a label" do
      assert {:rejected, %{}, [{:execution_error, "_sys.move", nil, :reserved_variable_key, []}]} =
               VariableMerge.merge(
                 %{},
                 %{},
                 %{"_sys.move" => "x"},
                 %{"_sys.move" => @salary},
                 nil
               )
    end

    test "merge/3 equals merge/5 with empty labels, events trimmed to the 4-tuple" do
      current = %{"x" => 1, "y" => 2}
      incoming = %{"x" => 5, "z" => 3}

      assert {:ok, vars3, events3} = VariableMerge.merge(current, incoming, nil)
      assert {:ok, vars5, %{}, events5} = VariableMerge.merge(current, %{}, incoming, %{}, nil)

      assert vars3 == vars5
      assert events3 == [{:variable_overwritten, "x", 1, 5}]
      assert events5 == [{:variable_overwritten, "x", 1, 5, [], []}]
    end

    test "determinism: equal arguments give equal results" do
      args = [%{"x" => 1}, %{"x" => @salary}, %{"x" => 2, "y" => 3}, %{"y" => @ssn}, nil]
      assert apply(VariableMerge, :merge, args) == apply(VariableMerge, :merge, args)
    end
  end

  describe "T-4 VariableLabels" do
    test "put_label_field omits empty labels and writes non-empty ones" do
      assert VariableLabels.put_label_field(%{a: 1}, :l, %{}) == %{a: 1}
      assert VariableLabels.put_label_field(%{a: 1}, :l, []) == %{a: 1}
      assert VariableLabels.put_label_field(%{a: 1}, :l, nil) == %{a: 1}
      assert VariableLabels.put_label_field(%{a: 1}, :l, @salary) == %{a: 1, l: @salary}

      assert VariableLabels.put_label_field(%{}, "l", %{"x" => @salary}) ==
               %{"l" => %{"x" => @salary}}
    end

    test "encode_merge_events: the three event kinds, labels only when present" do
      assert VariableLabels.encode_merge_events([
               {:variable_overwritten, "x", 1, 2},
               {:variable_overwritten, "y", 1, 2, @salary, []},
               {:computed_field_disagreement, "f", 1, 2},
               {:computed_field_disagreement, "g", 1, 2, @salary, @ssn},
               {:visible_when_false_value_discarded, "h", 3},
               {:visible_when_false_value_discarded, "i", 3, @ssn}
             ]) == [
               %{event: "variable_overwritten", key: "x", old_value: 1, new_value: 2},
               %{
                 event: "variable_overwritten",
                 key: "y",
                 old_value: 1,
                 new_value: 2,
                 old_labels: @salary
               },
               %{
                 event: "computed_field_disagreement",
                 field: "f",
                 submitted_value: 1,
                 server_value: 2
               },
               %{
                 event: "computed_field_disagreement",
                 field: "g",
                 submitted_value: 1,
                 server_value: 2,
                 server_labels: @salary,
                 submitted_labels: @ssn
               },
               %{event: "visible_when_false_value_discarded", field: "h", discarded_value: 3},
               %{
                 event: "visible_when_false_value_discarded",
                 field: "i",
                 discarded_value: 3,
                 discarded_labels: @ssn
               }
             ]
    end

    test "sanitize and take" do
      assert VariableLabels.sanitize(%{
               "x" => ["b", "a", "a"],
               "y" => [],
               1 => ["z"],
               "w" => "q"
             }) == %{"x" => ["a", "b"]}

      assert VariableLabels.sanitize(:nope) == %{}
      assert VariableLabels.take(%{"x" => @salary, "y" => @ssn}, %{"x" => 1}) == %{"x" => @salary}
    end

    test "put_merged replaces variables and labels together" do
      state = %InstanceState{
        instance_id: "i",
        variables: %{"x" => 1},
        variable_labels: %{"x" => @salary}
      }

      merged = VariableLabels.put_merged(state, %{"x" => 2}, %{"x" => @ssn})
      assert {merged.variables, merged.variable_labels} == {%{"x" => 2}, %{"x" => @ssn}}
    end
  end
end
