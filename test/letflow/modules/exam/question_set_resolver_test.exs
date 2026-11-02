defmodule Letflow.Modules.Exam.QuestionSetResolverTest do
  @moduledoc """
  REQ-332 -- pure unit tests for `Letflow.Modules.Exam.QuestionSetResolver`. No
  database, no tenant -- `resolve/5` is a pure function over its arguments
  plus the seeded `:rand` state.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Exam.QuestionSetResolver

  defp pool do
    %{
      "cat_a" => [
        %{question_id: "qa1", option_ids: ["oa1", "oa2", "oa3"]},
        %{question_id: "qa2", option_ids: ["ob1", "ob2"]},
        %{question_id: "qa3", option_ids: ["oc1", "oc2", "oc3", "oc4"]},
        %{question_id: "qa4", option_ids: ["od1", "od2"]}
      ],
      "cat_b" => [
        %{question_id: "qb1", option_ids: ["pb1", "pb2"]},
        %{question_id: "qb2", option_ids: ["pb3", "pb4"]}
      ]
    }
  end

  describe "seeded reproducibility" do
    test "same seed + same rules/pool/shuffle flags yields the same resolved set, order, and option order" do
      rules = [%{pool_id: "cat_a", count: 3}, %{pool_id: "cat_b", count: 1}]

      assert {:ok, first} = QuestionSetResolver.resolve(rules, pool(), true, true, 42)
      assert {:ok, second} = QuestionSetResolver.resolve(rules, pool(), true, true, 42)

      assert first == second

      # This test deliberately does NOT compare byte-for-byte against any
      # value produced by Go's `math/rand` -- Go's `math/rand` and Erlang's
      # `:rand` are different PRNG algorithms with different internal state
      # and different output streams for the same numeric seed, so "same
      # seed" cannot mean "same bytes" across the two languages. Only
      # same-seed-in-Letflow-yields-same-output-in-Letflow (asserted above)
      # is a real, checkable property.
    end

    test "a different seed can (and typically does) yield a different order" do
      rules = [%{pool_id: "cat_a", count: 4}]

      assert {:ok, one} = QuestionSetResolver.resolve(rules, pool(), true, true, 1)
      assert {:ok, two} = QuestionSetResolver.resolve(rules, pool(), true, true, 999)

      refute Enum.map(one, & &1.question_id) == Enum.map(two, & &1.question_id) and
               Enum.map(one, & &1.options_order) == Enum.map(two, & &1.options_order)
    end
  end

  describe "pool truncation and shape" do
    test "truncates each rule's pool to its own count, preserving rule order" do
      rules = [%{pool_id: "cat_a", count: 2}, %{pool_id: "cat_b", count: 2}]

      assert {:ok, resolved} = QuestionSetResolver.resolve(rules, pool(), false, false, 7)

      assert length(resolved) == 4
      cat_a_ids = MapSet.new(Enum.map(pool()["cat_a"], & &1.question_id))
      cat_b_ids = MapSet.new(Enum.map(pool()["cat_b"], & &1.question_id))

      {from_a, from_b} = Enum.split(resolved, 2)
      assert Enum.all?(from_a, &MapSet.member?(cat_a_ids, &1.question_id))
      assert Enum.all?(from_b, &MapSet.member?(cat_b_ids, &1.question_id))
    end

    test "assigns sequential zero-based sort_order regardless of shuffle_questions?" do
      rules = [%{pool_id: "cat_a", count: 4}]

      assert {:ok, resolved} = QuestionSetResolver.resolve(rules, pool(), true, false, 3)
      assert Enum.map(resolved, & &1.sort_order) == [0, 1, 2, 3]
    end

    test "shuffle_options?: false preserves each question's original option order" do
      rules = [%{pool_id: "cat_a", count: 1}]
      assert {:ok, [resolved]} = QuestionSetResolver.resolve(rules, pool(), false, false, 5)

      original = Enum.find(pool()["cat_a"], &(&1.question_id == resolved.question_id))
      assert resolved.options_order == original.option_ids
    end
  end

  describe "pool underflow" do
    test "returns {:error, :pool_underflow} when a rule's count exceeds its pool size" do
      rules = [%{pool_id: "cat_b", count: 5}]

      assert {:error, :pool_underflow} =
               QuestionSetResolver.resolve(rules, pool(), false, false, 1)
    end
  end
end
