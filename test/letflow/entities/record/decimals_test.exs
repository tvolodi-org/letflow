defmodule Letflow.Entities.Record.DecimalsTest do
  @moduledoc """
  GH #2654 PR-1 -- the pure half of `decimal_strict`: `Record.Decimals`,
  `Record.Validator.normalize_record_payload/2` and the definition validator's
  Rule 7 / Rule 12 additions (design `lib/letflow/design/gh2654-decimal-exact-strings.md`
  sections 2.1, 2.5, 3; decision 0060).
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Definition.Validator, as: DefinitionValidator
  alias Letflow.Entities.Record.Decimals
  alias Letflow.Entities.Record.Validator, as: RecordValidator

  defp definition(field_overrides, extra_fields \\ []) do
    field =
      Map.merge(
        %{
          name: "qty",
          type: :decimal,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: true
        },
        field_overrides
      )

    %{name: "widget", display_name: "Widget", fields: [field | extra_fields]}
  end

  defp normalize(field_overrides, value) do
    RecordValidator.normalize_record_payload(definition(field_overrides), %{"qty" => value})
  end

  defp constraints({:error, violations}),
    do: Enum.map(violations, &{&1.field_path, &1.constraint})

  describe "parse/3 -- the strict write grammar (T2, T5, T6)" do
    test "accepts canonical strings and integers" do
      assert {:ok, d} = Decimals.parse("2.50", 10, 2)
      assert Decimals.to_canonical(d, 2) == "2.50"
      assert {:ok, d} = Decimals.parse(3, 10, 2)
      assert Decimals.to_canonical(d, 2) == "3.00"
      assert {:ok, d} = Decimals.parse("-0.00", 10, 2)
      assert Decimals.to_canonical(d, 2) == "0.00"
      assert {:ok, d} = Decimals.parse("-0", 10, 2)
      assert Decimals.to_canonical(d, 2) == "0.00"
    end

    test "refuses every JSON float, whatever its value" do
      for f <- [2.5, 3.0, 1.0e3, 0.30000000000000004, -0.0] do
        assert Decimals.parse(f, 10, 2) == {:error, :type}
      end
    end

    test "refuses every non-canonical spelling and non-string, non-integer term with type" do
      refused = [
        "+1",
        " 1",
        "1 ",
        ".5",
        "5.",
        "1e3",
        "1E3",
        "1,5",
        "NaN",
        "Infinity",
        "-Infinity",
        "",
        "007",
        "-",
        "--1",
        "1.2.3",
        "0x10",
        "1_000",
        "1\n",
        true,
        false,
        %{},
        [],
        ["1"],
        :atom
      ]

      for value <- refused do
        assert Decimals.parse(value, 10, 2) == {:error, :type},
               "expected type for #{inspect(value)}"
      end
    end

    test "scale is value-based: trailing zeros are accepted, a real extra digit is refused (T4)" do
      assert {:ok, d} = Decimals.parse("2.500", 10, 2)
      assert Decimals.to_canonical(d, 2) == "2.50"
      assert Decimals.parse("2.505", 10, 2) == {:error, :scale}
      assert Decimals.parse("0.001", 10, 2) == {:error, :scale}
    end

    test "scale 0: an integer string, a zero fraction dropped, a real fraction refused (T3)" do
      assert {:ok, d} = Decimals.parse("3", 5, 0)
      assert Decimals.to_canonical(d, 0) == "3"
      assert {:ok, d} = Decimals.parse("3.0", 5, 0)
      assert Decimals.to_canonical(d, 0) == "3"
      assert Decimals.parse("3.1", 5, 0) == {:error, :scale}
    end

    test "precision counts integer digits against precision - scale (T5)" do
      assert Decimals.parse("123456789.12", 10, 2) == {:error, :precision}
      assert {:ok, _} = Decimals.parse("12345678.12", 10, 2)
      assert {:ok, d} = Decimals.parse("0.99", 2, 2)
      assert Decimals.to_canonical(d, 2) == "0.99"
      assert Decimals.parse("1.00", 2, 2) == {:error, :precision}
      assert Decimals.parse(1, 2, 2) == {:error, :precision}
      assert {:ok, _} = Decimals.parse(0, 2, 2)
      assert Decimals.parse(100_000_000, 10, 2) == {:error, :precision}
      assert {:ok, _} = Decimals.parse(99_999_999, 10, 2)
    end

    test "size caps are enforced before any parsing (T5)" do
      too_long = String.duplicate("1", 1101)
      assert Decimals.parse(too_long, 2000, 0) == {:error, :type}
      at_cap = String.duplicate("1", 1100)
      assert {:ok, _} = Decimals.parse(at_cap, 1100, 0)

      huge = Integer.pow(2, 4000)
      assert Decimals.parse(huge, 1000, 0) == {:error, :precision}
      assert Decimals.parse(-huge, 1000, 0) == {:error, :precision}
    end

    test "never rounds or loses digits beyond the 28-digit arithmetic context" do
      value = "123456789012345678901234567890.12"
      assert {:ok, d} = Decimals.parse(value, 40, 2)
      assert Decimals.to_canonical(d, 2) == value
    end
  end

  describe "to_canonical/2" do
    test "pads to exactly the scale in plain notation" do
      assert Decimals.to_canonical(Decimal.new("2.5"), 2) == "2.50"
      assert Decimals.to_canonical(Decimal.new("3"), 2) == "3.00"
      assert Decimals.to_canonical(Decimal.new("0.05"), 3) == "0.050"
      assert Decimals.to_canonical(Decimal.new("-0.5"), 2) == "-0.50"
      assert Decimals.to_canonical(Decimal.new("1E+2"), 1) == "100.0"
      assert Decimals.to_canonical(Decimal.new("0"), 0) == "0"
    end
  end

  describe "bound/1" do
    test "integers, floats and strict-grammar strings; nothing else" do
      assert {:ok, %Decimal{}} = Decimals.bound(1)
      assert {:ok, %Decimal{}} = Decimals.bound(0.5)
      assert {:ok, %Decimal{}} = Decimals.bound("0.10")
      assert Decimals.bound("1e3") == :error
      assert Decimals.bound("abc") == :error
      assert Decimals.bound(nil) == :error
      assert Decimals.bound(String.duplicate("1", 1101)) == :error
    end
  end

  describe "strict_specs/1" do
    test "only decimal fields with decimal_strict == true; %{} otherwise (I6)" do
      assert Decimals.strict_specs(definition(%{decimal_strict: false})) == %{}
      assert Decimals.strict_specs(%{fields: [%{name: "a", type: :string}]}) == %{}
      assert Decimals.strict_specs(%{}) == %{}

      assert %{"qty" => %{precision: 10, scale: 2, min: nil, max: nil}} =
               Decimals.strict_specs(definition(%{}))
    end

    test "folds non_negative into the minimum and ignores a corrupt stored bound" do
      assert %{"qty" => %{min: %Decimal{} = min}} =
               Decimals.strict_specs(definition(%{non_negative: true}))

      assert Decimal.equal?(min, 0)

      assert %{"qty" => %{min: nil, max: nil}} =
               Decimals.strict_specs(definition(%{min: "garbage", max: %{}}))
    end
  end

  describe "normalize_record_payload/2 -- writes (T1, T2, T4, T7)" do
    test "a strict string is rewritten to its canonical scale-padded form" do
      assert {:ok, %{"qty" => "2.50"}} = normalize(%{}, "2.5")
      assert {:ok, %{"qty" => "2.50"}} = normalize(%{}, "2.50")
      assert {:ok, %{"qty" => "3.00"}} = normalize(%{}, 3)
      assert {:ok, %{"qty" => "0.00"}} = normalize(%{}, "-0.00")
    end

    test "different spellings of one value normalise to the same stored string (idempotent retry)" do
      assert normalize(%{}, "2.5") == normalize(%{}, "2.500")
    end

    test "a float is refused with type and the field path" do
      assert [{"/qty", "type"}] = constraints(normalize(%{}, 2.5))
    end

    test "scale and precision violations carry the constraint name and no echoed value" do
      assert {:error, [failure]} = normalize(%{}, "2.505")
      assert %{field_path: "/qty", constraint: "scale", actual: nil} = failure
      assert [{"/qty", "precision"}] = constraints(normalize(%{}, "123456789.12"))
    end

    test "one violation per field; other fields still validated" do
      def =
        definition(%{}, [%{name: "label", type: :string, required: true}])

      assert {:error, violations} = RecordValidator.normalize_record_payload(def, %{"qty" => 2.5})
      paths = Enum.map(violations, &{&1.field_path, &1.constraint}) |> Enum.sort()
      assert paths == [{"/label", "required"}, {"/qty", "type"}]
    end

    test "null follows the existing null handling (a type violation, not a crash)" do
      assert {:error, [%{field_path: "/qty", constraint: "type"}]} = normalize(%{}, nil)
    end

    test "an absent optional strict field is fine" do
      assert {:ok, %{}} = RecordValidator.normalize_record_payload(definition(%{}), %{})
    end

    test "a non-strict decimal field is untouched: numbers pass, strings and scale are as before (R1, R3)" do
      non_strict = definition(%{decimal_strict: nil, decimal_precision: 5})

      assert {:ok, %{"qty" => 66.6666}} =
               RecordValidator.normalize_record_payload(non_strict, %{"qty" => 66.6666})

      assert {:ok, %{"qty" => 2.505}} =
               RecordValidator.normalize_record_payload(non_strict, %{"qty" => 2.505})

      assert {:error, [%{constraint: "type"}]} =
               RecordValidator.normalize_record_payload(non_strict, %{"qty" => "2.50"})

      # byte-identical subschema for a non-strict field
      assert RecordValidator.build_record_schema(non_strict)["properties"]["qty"] == %{
               "type" => "number"
             }

      assert RecordValidator.build_record_schema(definition(%{}))["properties"]["qty"] == %{
               "type" => "string"
             }
    end
  end

  describe "normalize_record_payload/2 -- bounds are exact (T9)" do
    test "min/max as decimal strings; boundaries are accepted" do
      overrides = %{min: "0.10", max: "99.99"}
      assert {:ok, %{"qty" => "0.10"}} = normalize(overrides, "0.10")
      assert {:ok, %{"qty" => "99.99"}} = normalize(overrides, "99.99")
      assert [{"/qty", "minimum"}] = constraints(normalize(overrides, "0.09"))
      assert [{"/qty", "maximum"}] = constraints(normalize(overrides, "100.00"))
    end

    test "a bound of 0.1 compares exactly, not as a float" do
      overrides = %{min: 0.1}
      assert {:ok, _} = normalize(overrides, "0.10")
      assert [{"/qty", "minimum"}] = constraints(normalize(overrides, "0.09"))
    end

    test "non_negative refuses -0.01 and accepts -0" do
      overrides = %{non_negative: true}
      assert [{"/qty", "minimum"}] = constraints(normalize(overrides, "-0.01"))
      assert {:ok, %{"qty" => "0.00"}} = normalize(overrides, "-0")
    end
  end

  describe "definition Rule 7 -- decimal_strict (T9)" do
    defp violations(definition) do
      case DefinitionValidator.validate(definition) do
        :ok -> []
        {:error, violations} -> violations
      end
    end

    test "valid on a decimal field, true or false" do
      assert DefinitionValidator.validate(definition(%{})) == :ok
      assert DefinitionValidator.validate(definition(%{decimal_strict: false})) == :ok
    end

    test "refused on a non-decimal field and when not a boolean" do
      on_string = %{
        name: "w",
        display_name: "W",
        fields: [%{name: "s", type: :string, decimal_strict: true}]
      }

      assert [
               %{
                 rule: :invalid_decimal,
                 message: "decimal_strict is only allowed on :decimal fields"
               }
             ] = violations(on_string)

      assert [%{rule: :invalid_decimal, message: "decimal_strict must be a boolean"}] =
               violations(definition(%{decimal_strict: "yes"}))
    end

    test "precision above 1000 is refused for a strict field only" do
      assert [
               %{
                 rule: :invalid_decimal,
                 message: "decimal_precision must not exceed 1000 when decimal_strict is true"
               }
             ] =
               violations(definition(%{decimal_precision: 1001}))

      assert DefinitionValidator.validate(definition(%{decimal_precision: 1000})) == :ok

      assert DefinitionValidator.validate(
               definition(%{decimal_strict: false, decimal_precision: 5000})
             ) == :ok
    end
  end

  describe "definition Rule 12 -- bounds on decimal fields (T9, T11)" do
    test "a strict field takes number and string bounds, mixed" do
      assert DefinitionValidator.validate(definition(%{min: "0.10", max: 99})) == :ok
      assert DefinitionValidator.validate(definition(%{min: 1, max: "5.5"})) == :ok
    end

    test "strict: min above max is compared exactly" do
      assert [%{rule: :invalid_range, message: "min must not exceed max"}] =
               violations(definition(%{min: "1", max: "0.5"}))

      assert DefinitionValidator.validate(definition(%{min: "0.50", max: 0.5})) == :ok
    end

    test "strict: a garbage string bound is invalid_range; non_negative with a negative string min is refused" do
      assert [%{rule: :invalid_range}] = violations(definition(%{min: "abc"}))
      assert [%{rule: :invalid_range}] = violations(definition(%{min: "1e3"}))

      assert [
               %{
                 rule: :invalid_range,
                 message: "min must not be negative when non_negative is true"
               }
             ] =
               violations(definition(%{min: "-1.5", non_negative: true}))
    end

    test "a string bound on a NON-strict decimal field is a definition violation; a number bound is still valid" do
      assert [%{rule: :invalid_range}] =
               violations(definition(%{decimal_strict: nil, min: "0.10"}))

      assert [%{rule: :invalid_range}] =
               violations(definition(%{decimal_strict: false, max: "9"}))

      assert DefinitionValidator.validate(definition(%{decimal_strict: nil, min: 0.1, max: 9})) ==
               :ok
    end
  end
end
