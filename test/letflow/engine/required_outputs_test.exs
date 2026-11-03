defmodule Letflow.Engine.RequiredOutputsTest do
  @moduledoc """
  REQ-460 -- pure unit tests of `Letflow.Engine.RequiredOutputs` (design req459 section
  8.2) plus the REQ-460 AC "VariableMerge.merge/3 still returns {:rejected, ...} for
  non-nil validations" regression (the engine-internal ERROR path REQ-061 relies on is
  intact; only the HUMAN_TASK completion path stopped reaching it).

  No database. See `test/specs/REQ-460.md` for why each case exists.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Definitions.Graph.Node
  alias Letflow.Engine.RequiredOutputs
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Test.LoggerCollector

  defp human_task(attributes), do: %Node{id: "n1", node_type: :HUMAN_TASK, attributes: attributes}

  defp rejected do
    {:rejected, [%ValidationFailure{field_path: "/", constraint: "enum", actual: "x"}]}
  end

  describe "required_outputs/1" do
    test "returns the list when the attribute is a list of non-empty strings" do
      assert RequiredOutputs.required_outputs(human_task(%{"required_outputs" => ["a", "b"]})) ==
               ["a", "b"]
    end

    test "absent attribute, nil, [] and a non-node all read as off ([]), silently" do
      {_, entries} =
        LoggerCollector.capture(
          fn ->
            assert RequiredOutputs.required_outputs(human_task(%{"role" => "r"})) == []

            assert RequiredOutputs.required_outputs(human_task(%{"required_outputs" => nil})) ==
                     []

            assert RequiredOutputs.required_outputs(human_task(%{"required_outputs" => []})) == []
            assert RequiredOutputs.required_outputs(nil) == []
            assert RequiredOutputs.required_outputs(:garbage) == []
          end,
          attribute_to: self()
        )

      refute LoggerCollector.text(entries) =~ "malformed"
    end

    test "a malformed attribute (not a list, or a bad entry) reads as off and logs one warning each, naming only the node id" do
      for bad <- ["decision", %{"a" => 1}, ["ok", ""], ["ok", 5], ["ok", nil]] do
        {_, entries} =
          LoggerCollector.capture(
            fn ->
              assert RequiredOutputs.required_outputs(human_task(%{"required_outputs" => bad})) ==
                       []
            end,
            attribute_to: self()
          )

        log = LoggerCollector.text(entries)

        assert log =~ "malformed required_outputs"
        assert log =~ ~s("n1")
      end
    end
  end

  describe "missing_keys/2" do
    test "absent keys are missing" do
      assert RequiredOutputs.missing_keys(["decision"], %{"other" => 1}) == ["decision"]
    end

    test "a null value counts as missing (BA 2026-10-07)" do
      assert RequiredOutputs.missing_keys(["decision"], %{"decision" => nil}) == ["decision"]
    end

    test "an empty string is NOT missing (judged by the variable_schema instead)" do
      assert RequiredOutputs.missing_keys(["decision"], %{"decision" => ""}) == []
    end

    test "false, 0 and an empty list/map are present values, not missing" do
      out = %{"a" => false, "b" => 0, "c" => [], "d" => %{}}
      assert RequiredOutputs.missing_keys(["a", "b", "c", "d"], out) == []
    end

    test "result is sorted ascending and deduplicated" do
      assert RequiredOutputs.missing_keys(["z", "a", "z", "m"], %{}) == ["a", "m", "z"]
    end

    test "nothing required -> nothing missing; non-list / non-map inputs are total (no raise)" do
      assert RequiredOutputs.missing_keys([], %{"a" => 1}) == []
      assert RequiredOutputs.missing_keys(nil, %{}) == []
      assert RequiredOutputs.missing_keys(["a"], nil) == []
    end
  end

  describe "rejected_keys/3" do
    test "reports only {:rejected, _} keys that are in the allowed set" do
      validations = %{"decision" => rejected(), "ok" => :ok, "amount" => rejected()}

      assert RequiredOutputs.rejected_keys(validations, [], ["decision", "ok"]) == ["decision"]
    end

    test "excludes keys already reported as missing" do
      validations = %{"decision" => rejected(), "note" => rejected()}

      assert RequiredOutputs.rejected_keys(validations, ["decision"], ["decision", "note"]) ==
               ["note"]
    end

    test "a rejection outside the allowed set is never named (INV-2)" do
      assert RequiredOutputs.rejected_keys(%{"secret_key" => rejected()}, [], ["decision"]) == []
    end

    test "sorted ascending; total on bad inputs" do
      validations = %{"b" => rejected(), "a" => rejected()}
      assert RequiredOutputs.rejected_keys(validations, [], ["a", "b"]) == ["a", "b"]
      assert RequiredOutputs.rejected_keys(nil, [], []) == []
      assert RequiredOutputs.rejected_keys(%{}, nil, []) == []
    end
  end

  describe "any_rejected?/1" do
    test "true when any key is rejected, regardless of any allowed set" do
      assert RequiredOutputs.any_rejected?(%{"a" => :ok, "b" => rejected()})
    end

    test "false for all :ok, empty and non-map input" do
      refute RequiredOutputs.any_rejected?(%{"a" => :ok})
      refute RequiredOutputs.any_rejected?(%{})
      refute RequiredOutputs.any_rejected?(nil)
    end
  end

  describe "allowed_keys/2" do
    test "union of form_schema.properties keys and required, sorted and deduplicated" do
      form = %{"properties" => %{"note" => %{}, "decision" => %{}}}

      assert RequiredOutputs.allowed_keys(form, ["decision", "extra"]) ==
               ["decision", "extra", "note"]
    end

    test "nil / property-less / malformed form_schema contributes nothing" do
      assert RequiredOutputs.allowed_keys(nil, ["a"]) == ["a"]
      assert RequiredOutputs.allowed_keys(%{}, ["a"]) == ["a"]
      assert RequiredOutputs.allowed_keys(%{"properties" => "nope"}, ["a"]) == ["a"]
      assert RequiredOutputs.allowed_keys(%{"properties" => %{"x" => %{}}}, nil) == []
    end
  end

  describe "VariableMerge.merge/3 is unchanged (REQ-460 item 4 regression)" do
    test "a non-nil validations map with a rejected key still returns {:rejected, ...} with the whole batch unmerged" do
      failures = [%ValidationFailure{field_path: "/", constraint: "enum", actual: "maybe"}]

      assert {:rejected, %{"seed" => 1},
              [{:execution_error, "decision", "maybe", :variable_schema_rejected, ^failures}]} =
               VariableMerge.merge(
                 %{"seed" => 1},
                 %{"decision" => "maybe", "note" => "n"},
                 %{"decision" => {:rejected, failures}}
               )
    end

    test "nil validations are never rejected (the service-task merge case)" do
      assert {:ok, %{"seed" => 1, "decision" => "maybe"}, []} =
               VariableMerge.merge(%{"seed" => 1}, %{"decision" => "maybe"}, nil)
    end
  end
end
