defmodule Letflow.Engine.VariableLabelsRedactionTest do
  @moduledoc """
  GH #2616 part 2 (decision 0062 R8, R8h, R12): the pure redaction core of `VariableLabels`.
  A value is hidden when one of its labels is in the caller's hidden label set; `nil` hides every
  labelled value (fail closed); an unlabelled value is never hidden; the placeholder is
  `FieldGrants.redacted_sentinel/0`. Event history is redacted by the labels on the event itself.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.VariableLabels

  @salary "customer.salary"
  @ssn "customer.ssn"
  @placeholder :__field_redacted__

  describe "hidden?/3" do
    test "a key is hidden when one of its labels is in the hidden set" do
      labels = %{"x" => [@salary, @ssn]}

      assert VariableLabels.hidden?(labels, "x", MapSet.new([@ssn]))
      assert VariableLabels.hidden?(labels, "x", MapSet.new([@salary]))
    end

    test "a key whose labels are all readable is not hidden" do
      assert VariableLabels.hidden?(%{"x" => [@salary]}, "x", MapSet.new([@ssn])) == false
      assert VariableLabels.hidden?(%{"x" => [@salary]}, "x", MapSet.new()) == false
    end

    test "an unlabelled key is never hidden, even when the hidden set is unknown" do
      assert VariableLabels.hidden?(%{}, "x", MapSet.new([@salary])) == false
      assert VariableLabels.hidden?(%{"x" => []}, "x", nil) == false
      assert VariableLabels.hidden?(%{"x" => nil}, "x", nil) == false
      assert VariableLabels.hidden?(nil, "x", nil) == false
    end

    test "a nil hidden set hides every labelled key (fail closed)" do
      assert VariableLabels.hidden?(%{"x" => [@salary]}, "x", nil)
    end
  end

  describe "redact_variables/3" do
    test "replaces each hidden value with the placeholder and keeps the others" do
      variables = %{"x" => 1, "y" => 2, "z" => 3}
      labels = %{"x" => [@salary], "y" => [@ssn]}

      assert VariableLabels.redact_variables(variables, labels, MapSet.new([@salary])) == %{
               "x" => @placeholder,
               "y" => 2,
               "z" => 3
             }
    end

    test "drops reserved keys first and never redacts a key name" do
      variables = %{"_sys.move" => "rec", "x" => "secret"}

      assert VariableLabels.redact_variables(variables, %{"x" => [@salary]}, nil) == %{
               "x" => @placeholder
             }
    end

    test "a non-map input is an empty map" do
      assert VariableLabels.redact_variables(nil, %{}, nil) == %{}
    end
  end

  describe "redact_map/3" do
    test "redacts without dropping reserved keys (the caller decides what is shown)" do
      assert VariableLabels.redact_map(%{"_sys.a" => 1, "x" => 2}, %{"x" => [@salary]}, nil) == %{
               "_sys.a" => 1,
               "x" => @placeholder
             }
    end
  end

  describe "redact_event_payload/2" do
    test "redacts variables, output and initial variables by their own label fields" do
      payload = %{
        "variables" => %{"x" => "a", "y" => "b"},
        "labels" => %{"x" => [@salary]},
        "output_variables" => %{"x" => "c"},
        "output_labels" => %{"x" => [@salary]},
        "initial_variables" => %{"y" => "d"},
        "initial_labels" => %{"y" => [@ssn]},
        "output" => %{"x" => "e"},
        "node_id" => "n1"
      }

      redacted = VariableLabels.redact_event_payload(payload, MapSet.new([@salary, @ssn]))

      assert redacted["variables"] == %{"x" => @placeholder, "y" => "b"}
      assert redacted["output_variables"] == %{"x" => @placeholder}
      assert redacted["initial_variables"] == %{"y" => @placeholder}
      assert redacted["output"] == %{"x" => @placeholder}
      assert redacted["node_id"] == "n1"
    end

    test "a missing label field means unlabelled (R8h-4): the value stays clear" do
      payload = %{"variables" => %{"x" => "a"}}

      assert VariableLabels.redact_event_payload(payload, nil) == %{"variables" => %{"x" => "a"}}
    end

    test "redacts the value of each merged entry by its own labels, leaving key names" do
      payload = %{
        "merged_variable_events" => [
          %{
            "event" => "variable_overwritten",
            "key" => "x",
            "old_value" => 1,
            "new_value" => 2,
            "old_labels" => [@salary],
            "new_labels" => []
          },
          %{
            "event" => "computed_field_disagreement",
            "field" => "y",
            "submitted_value" => 3,
            "server_value" => 4,
            "server_labels" => [@salary],
            "submitted_labels" => []
          },
          %{
            "event" => "visible_when_false_value_discarded",
            "field" => "z",
            "discarded_value" => 5,
            "discarded_labels" => [@ssn]
          }
        ]
      }

      [overwritten, disagreement, discarded] =
        VariableLabels.redact_event_payload(payload, MapSet.new([@salary, @ssn]))[
          "merged_variable_events"
        ]

      assert overwritten == %{
               "event" => "variable_overwritten",
               "key" => "x",
               "old_value" => @placeholder,
               "new_value" => 2,
               "old_labels" => [@salary],
               "new_labels" => []
             }

      assert disagreement["server_value"] == @placeholder
      assert disagreement["submitted_value"] == 3
      assert disagreement["field"] == "y"
      assert discarded["discarded_value"] == @placeholder
    end

    test "malformed input is returned unchanged, not raised on" do
      assert VariableLabels.redact_event_payload("not a map", nil) == "not a map"

      assert VariableLabels.redact_event_payload(%{"variables" => "nope"}, nil) == %{
               "variables" => "nope"
             }
    end
  end

  test "the placeholder is the FieldGrants sentinel" do
    assert VariableLabels.representation() == @placeholder

    assert VariableLabels.representation() ==
             Letflow.Entities.Query.FieldGrants.redacted_sentinel()
  end
end
