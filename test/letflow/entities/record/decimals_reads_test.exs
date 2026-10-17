defmodule Letflow.Entities.Record.DecimalsReadsTest do
  @moduledoc """
  GH #2654 PR-2 -- the pure read-side helpers of `Letflow.Entities.Record.Decimals`
  (design `lib/letflow/design/gh2654-decimal-exact-strings.md` sections 2.6-2.8):
  the defensive decoder (`render_value/2`, `render_field_values/2`; S8 on an
  event-shaped payload, S10), `to_decimal/1` (S2) and `filter_value/1` (S6).
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Record.Decimals

  @specs %{"qty" => %{precision: 10, scale: 2, min: nil, max: nil}}

  describe "specs_from_definition_json/1" do
    test "reads the strict decimal fields of a persisted (string-keyed) definition" do
      json = %{
        "name" => "widget",
        "fields" => [
          %{
            "name" => "qty",
            "type" => "decimal",
            "decimal_precision" => 10,
            "decimal_scale" => 3,
            "decimal_strict" => true,
            "min" => "0.5"
          },
          %{
            "name" => "plain",
            "type" => "decimal",
            "decimal_precision" => 10,
            "decimal_scale" => 2
          },
          %{"name" => "flagged_off", "type" => "decimal", "decimal_strict" => false},
          %{"name" => "title", "type" => "string"}
        ]
      }

      assert %{"qty" => %{precision: 10, scale: 3, min: min, max: nil}} =
               specs = Decimals.specs_from_definition_json(json)

      assert Decimal.equal?(min, Decimal.new("0.5"))
      assert Map.keys(specs) == ["qty"]
    end

    test "anything that is not a definition document is %{} (never raises)" do
      for junk <- [nil, %{}, %{"fields" => "x"}, "text", 5, %{"fields" => [nil, 1, "a"]}] do
        assert Decimals.specs_from_definition_json(junk) == %{}
      end
    end
  end

  describe "render_value/2 (the defensive decoder)" do
    test "numbers and canonical strings become the scale-padded string" do
      assert Decimals.render_value(2.5, 2) == "2.50"
      assert Decimals.render_value(3, 2) == "3.00"
      assert Decimals.render_value(-3, 0) == "-3"
      assert Decimals.render_value("2.5", 2) == "2.50"
      assert Decimals.render_value("2.50", 2) == "2.50"
      assert Decimals.render_value("-0.00", 2) == "0.00"
      assert Decimals.render_value(Decimal.new("1E+1"), 2) == "10.00"
      assert Decimals.render_value(0.1, 1) == "0.1"
    end

    test "a value with more fractional digits than the scale is plain notation, never rounded" do
      assert Decimals.render_value(66.6666, 2) == "66.6666"
      assert Decimals.render_value("1.234", 2) == "1.234"
    end

    test "nil, the redaction sentinel, maps and unparseable strings pass through untouched" do
      for value <- [nil, :__field_redacted__, %{"a" => 1}, ["x"], "n/a", "", "1e3", "NaN", true] do
        assert Decimals.render_value(value, 2) == value
      end

      nan = Decimal.new("NaN")
      assert Decimals.render_value(nan, 2) == nan
    end
  end

  describe "render_field_values/2" do
    test "renders only the strict keys; the rest of the map is untouched" do
      values = %{"qty" => 2.5, "plain" => 2.5, "note" => "x"}

      assert Decimals.render_field_values(values, @specs) ==
               %{"qty" => "2.50", "plain" => 2.5, "note" => "x"}
    end

    test "no strict specs, a non-map, a struct and an absent key are all returned as they are" do
      values = %{"qty" => 2.5}
      assert Decimals.render_field_values(values, %{}) == values
      assert Decimals.render_field_values(nil, @specs) == nil
      assert Decimals.render_field_values(%{"note" => "x"}, @specs) == %{"note" => "x"}
      date = ~D[2026-01-01]
      assert Decimals.render_field_values(date, @specs) == date
    end

    test "S8: an event-shaped payload with a legacy number and a stored string both decode" do
      payload = %{"field_values" => %{"qty" => 7}}

      assert Decimals.render_field_values(payload["field_values"], @specs) == %{"qty" => "7.00"}

      assert Decimals.render_field_values(%{"qty" => "7.00"}, @specs) == %{"qty" => "7.00"}
    end
  end

  describe "to_decimal/1" do
    test "a string, integer, float or finite Decimal" do
      assert {:ok, d} = Decimals.to_decimal("2.50")
      assert Decimal.equal?(d, Decimal.new("2.5"))
      assert {:ok, %Decimal{}} = Decimals.to_decimal(3)
      assert {:ok, %Decimal{}} = Decimals.to_decimal(2.5)
      assert {:ok, %Decimal{}} = Decimals.to_decimal(Decimal.new("1.1"))
    end

    test "everything else is :error" do
      for value <- [nil, "x", "1e3", " 1", %{}, Decimal.new("NaN"), Decimal.new("Infinity")] do
        assert Decimals.to_decimal(value) == :error
      end
    end
  end

  describe "filter_value/1" do
    test "a canonical string or an integer; scale is not enforced" do
      assert {:ok, d} = Decimals.filter_value("2.5555")
      assert Decimal.equal?(d, Decimal.new("2.5555"))
      assert {:ok, d} = Decimals.filter_value(-7)
      assert Decimal.equal?(d, Decimal.new(-7))
      assert {:ok, %Decimal{}} = Decimals.filter_value(Decimal.new("1.5"))
    end

    test "every float, a non-grammar string and an oversized literal are :error" do
      huge_string = String.duplicate("1", 1101)
      huge_int = Integer.pow(10, 1500)

      for value <- [
            2.5,
            3.0,
            "1; DROP TABLE x",
            "1e3",
            "+1",
            ".5",
            "007",
            "",
            nil,
            true,
            %{},
            [],
            huge_string,
            huge_int,
            Decimal.new("NaN")
          ] do
        assert Decimals.filter_value(value) == :error, inspect(value)
      end
    end
  end
end
