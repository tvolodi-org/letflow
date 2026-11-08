defmodule Letflow.Modules.Codes.Code128Test do
  @moduledoc "GH #4017 / REQ-779: the Code 128 set B encoder (C1-1..C1-4)."

  use ExUnit.Case, async: true

  alias Letflow.Modules.Codes.Code128

  test "C1-1 A1 is start B, A, 1, check 68, stop" do
    {:ok, widths} = Code128.encode("A1")
    pats = Code128.patterns()
    digits = fn i -> pats |> Enum.at(i) |> String.to_charlist() |> Enum.map(&(&1 - ?0)) end
    assert widths == Enum.flat_map([104, 33, 17, 68, 106], digits)
    assert Enum.slice(pats, 104, 1) == ["211214"]
    assert Enum.at(pats, 33) == "111323"
    assert Enum.at(pats, 17) == "123221"
    assert Enum.at(pats, 68) == "141221"
  end

  test "C1-1b known table rows" do
    pats = Code128.patterns()
    assert Enum.at(pats, 0) == "212222"
    assert Enum.at(pats, 95) == "114113"
    assert Enum.at(pats, 103) == "211412"
    assert Enum.at(pats, 105) == "211232"
  end

  test "C1-2 module total is 11 * (n + 2) + 13" do
    for n <- [1, 5, 20] do
      {:ok, widths} = Code128.encode(String.duplicate("7", n))
      assert Enum.sum(widths) == 11 * (n + 2) + 13
      assert rem(length(widths), 2) == 1
    end
  end

  test "C1-3 table: 107 patterns, sums 11, distinct, stop 2331112" do
    pats = Code128.patterns()
    assert length(pats) == 107
    assert pats |> Enum.take(106) |> Enum.all?(&(digit_sum(&1) == 11 and String.length(&1) == 6))
    assert length(Enum.uniq(pats)) == 107
    assert List.last(pats) == "2331112"
    assert digit_sum("2331112") == 13
  end

  test "C1-4 values outside ASCII 32..126 or empty are refused" do
    for v <- ["", "Қод", "a\tb", "é", <<255>>, 5, nil] do
      assert Code128.encode(v) == {:error, :value_not_encodable}, inspect(v)
    end
  end

  defp digit_sum(s), do: s |> String.to_charlist() |> Enum.map(&(&1 - ?0)) |> Enum.sum()
end
