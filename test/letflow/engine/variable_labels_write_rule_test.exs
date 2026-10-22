defmodule Letflow.Engine.VariableLabelsWriteRuleTest do
  @moduledoc """
  Decision 0062 R5 (SR-OPT-5, pure) and SR-OPT-12 (GH #2616 part 3): the narrow write predicate
  and the scrub of a rejected labelled value.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.VariableLabels
  alias Letflow.EventStore.Registry.ValidationFailure

  @salary "customer.salary"

  describe "SR-OPT-5: write_allowed?/3" do
    test "an untainted value may be written anywhere" do
      assert VariableLabels.write_allowed?([], "customer.name", MapSet.new())
    end

    test "a value tainted by exactly the restricted target field may be written there" do
      assert VariableLabels.write_allowed?([@salary], @salary, MapSet.new([@salary]))
    end

    test "the target must be restricted" do
      refute VariableLabels.write_allowed?([@salary], @salary, MapSet.new())
    end

    test "another target field, even a restricted one, is refused" do
      restricted = MapSet.new([@salary, "customer.ssn"])
      refute VariableLabels.write_allowed?([@salary], "customer.ssn", restricted)
    end

    test "a taint wider than the target restriction set is refused" do
      restricted = MapSet.new([@salary, "customer.ssn"])
      refute VariableLabels.write_allowed?([@salary, "customer.ssn"], @salary, restricted)
    end
  end

  describe "SR-OPT-12: scrub_rejection/4" do
    defp failure,
      do: %ValidationFailure{field_path: "/k", constraint: "type", actual: "secret-42"}

    test "a labelled key's value and failure actuals are not echoed" do
      assert {"__field_redacted__", [scrubbed]} =
               VariableLabels.scrub_rejection("k", "secret-42", [failure()], %{"k" => [@salary]})

      assert scrubbed.actual == nil
      assert scrubbed.constraint == "type"
    end

    test "an unlabelled key is unchanged" do
      assert VariableLabels.scrub_rejection("k", "v", [failure()], %{"other" => [@salary]}) ==
               {"v", [failure()]}

      assert VariableLabels.scrub_rejection("k", "v", [failure()], %{}) == {"v", [failure()]}
    end
  end
end
