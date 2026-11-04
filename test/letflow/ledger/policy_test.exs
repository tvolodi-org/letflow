defmodule Letflow.Ledger.PolicyTest do
  @moduledoc """
  REQ-684 criterion 5 (T-PL-1): the pure helpers of `Letflow.Ledger.Policy` and the fixture policy.
  The static allowlist is tested in `test/letflow/entities/ledger_boundaries_test.exs`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Ledger.Policy
  alias Letflow.Modules.FixtureLedgerPost.LedgerPolicy

  test "T-PL-1a decimal/2 parses canonical text and never rounds" do
    assert {:ok, d} = Policy.decimal("12.345", 3)
    assert Decimal.equal?(d, Decimal.new("12.345"))
    assert {:ok, _} = Policy.decimal("0", 0)
    assert {:ok, _} = Policy.decimal("-1.5", 1)
    assert {:ok, _} = Policy.decimal("1.000000000", 9)

    for {input, scale} <- [
          {"1.234", 2},
          {"1.5", 0},
          {"1e3", 3},
          {"01", 0},
          {" 1", 0},
          {"1 ", 0},
          {"1.", 2},
          {".5", 2},
          {"+1", 0},
          {"NaN", 0},
          {"", 0},
          {1.5, 2},
          {1, 0},
          {nil, 0},
          {Decimal.new(1), 0},
          {"1", 10},
          {"1", -1},
          {"1", "2"},
          {String.duplicate("9", 65), 0}
        ] do
      assert Policy.decimal(input, scale) == {:error, :invalid}, inspect({input, scale})
    end
  end

  test "T-PL-1a uuid/1 returns lowercase canonical text" do
    assert Policy.uuid("0123ABCD-0123-4567-89ab-0123456789AB") ==
             {:ok, "0123abcd-0123-4567-89ab-0123456789ab"}

    for bad <- [
          "",
          "x",
          "0123abcd01234567-89ab-0123456789ab",
          1,
          nil,
          "0123abcd-0123-4567-89ab-0123456789a\n"
        ] do
      assert Policy.uuid(bad) == {:error, :invalid}, inspect(bad)
    end
  end

  test "T-PL-1a token/2 charset and byte cap" do
    assert Policy.token("a.b_c:d-1", 16) == {:ok, "a.b_c:d-1"}
    assert Policy.token("a.b:c-d1", 16) == {:ok, "a.b:c-d1"}
    assert Policy.token("abc", 3) == {:ok, "abc"}
    assert Policy.token("abcd", 3) == {:error, :invalid}

    for {bad, max} <- [
          {"", 3},
          {"A", 3},
          {"a b", 8},
          {"é", 8},
          {:a, 3},
          {nil, 3},
          {"a", 0},
          {"a", "1"}
        ] do
      assert Policy.token(bad, max) == {:error, :invalid}, inspect({bad, max})
    end
  end

  test "T-PL-1a leg/1 and posting/1 keep only their closed key set" do
    assert Policy.leg(%{
             k: ["a"],
             quantity: Decimal.new(1),
             unit_ref: "ea",
             evil: 1,
             __struct__: 2
           }) ==
             %{k: ["a"], quantity: Decimal.new(1), unit_ref: "ea"}

    assert Policy.leg(%{k: [], attrs: %{}, document_line_id: nil, prefix: "x"}) ==
             %{k: [], attrs: %{}, document_line_id: nil}

    posting = %{
      ledger_id: "l",
      cause: "c",
      legs: [],
      reason_code: "r",
      prefix: "x",
      subject_id: "s"
    }

    assert Policy.posting(posting) == %{ledger_id: "l", cause: "c", legs: [], reason_code: "r"}
  end

  test "T-PL-1b the fixture policy declares a valid command and refuses a bad one" do
    command = %{
      ledger_id: "fixture_ledger_post",
      cause: "receipt",
      legs: [%{k: ["sku-1", ""], quantity: "2.5", unit_ref: "ea", junk: 1}],
      document_id: "d-1",
      client_op_id: "op-1"
    }

    assert {:ok, posting} = LedgerPolicy.declare(command, %{})
    assert posting.ledger_id == "fixture_ledger_post"
    assert posting.document_id == "d-1"
    refute Map.has_key?(posting, :client_op_id)
    assert [%{quantity: q, unit_ref: "ea"} = leg] = posting.legs
    assert Decimal.equal?(q, Decimal.new("2.5"))
    refute Map.has_key?(leg, :junk)

    bad_leg =
      put_in(command, [:legs], [hd(command.legs), %{k: [], quantity: "1.5.5", unit_ref: "ea"}])

    assert {:error, {:invalid_posting, %{leg_no: 2, reason: :quantity_invalid}}} =
             LedgerPolicy.declare(bad_leg, %{})

    bad_unit = put_in(command, [:legs], [%{k: [], quantity: "1", unit_ref: "BAD UNIT"}])

    assert {:error, {:invalid_posting, %{leg_no: 1, reason: :unit_invalid}}} =
             LedgerPolicy.declare(bad_unit, %{})

    assert {:error, {:invalid_posting, %{leg_no: nil, reason: :posting_shape}}} =
             LedgerPolicy.declare(:nope, %{})

    assert {:error, {:invalid_posting, %{leg_no: 1, reason: :posting_shape}}} =
             LedgerPolicy.declare(%{command | legs: [:x]}, %{})
  end

  test "the module declares the declare/2 callback" do
    assert {:declare, 2} in Policy.behaviour_info(:callbacks)
  end
end
