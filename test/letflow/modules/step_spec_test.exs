defmodule Letflow.Modules.StepSpecTest do
  @moduledoc """
  REQ-773 / T-1581 (S1, S2): the closed vocabulary of a declarative data step and its validation by
  `Catalog.validate/1` (rule 17). Pure: no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Step
  alias Letflow.Modules.StepSpec

  @manifest %{manages_entity_types: ["t"]}

  defp step(up, over \\ []) do
    struct!(
      Step,
      Keyword.merge(
        [
          id: "s1",
          from: "1.0.0",
          to: "1.1.0",
          kind: :declarative,
          up: up,
          down: :irreversible,
          lossy: false
        ],
        over
      )
    )
  end

  defp valid?(up), do: StepSpec.validate(step(up), @manifest) == :ok

  defp catalog_ok?(up) do
    manifest =
      CatalogItems.manifest()
      |> Map.merge(%{
        version: "1.1.0",
        min_upgradable_from: "1.0.0",
        migrations: [step(up)]
      })

    Catalog.validate(manifest) == :ok
  end

  test "S1 the three executable ops validate" do
    assert valid?(%{op: :set_default, type: "t", field: "f", value: "x"})
    assert valid?(%{op: :backfill_from_constant, type: "t", field: "f", value: 3})
    assert valid?(%{op: :set_default, type: "t", field: "f", value: false})
    assert valid?(%{op: :copy_field, type: "t", from: "a", to: "b", transform: :to_decimal})
  end

  test "S1 refusals: transform, type, names, value, shape" do
    refute valid?(%{op: :copy_field, type: "t", from: "a", to: "b", transform: :nope})
    refute valid?(%{op: :copy_field, type: "t", from: "a", to: "a", transform: :identity})
    refute valid?(%{op: :copy_field, type: "t", from: "a", to: "x_b", transform: :identity})
    refute valid?(%{op: :set_default, type: "other", field: "f", value: "x"})
    refute valid?(%{op: :set_default, type: "t", field: "x_f", value: "x"})
    refute valid?(%{op: :set_default, type: "t", field: "f; drop", value: "x"})
    refute valid?(%{op: :set_default, type: "t", field: "f", value: nil})
    refute valid?(%{op: :set_default, type: "t", field: "f", value: %{"a" => 1}})
    refute valid?(%{op: :set_default, type: "t", field: "f", value: "x", extra: 1})
    refute valid?(%{op: :unknown_op, type: "t", field: "f", value: "x"})
    refute valid?(%{op: "set_default", type: "t", field: "f", value: "x"})
  end

  test "S1 validate never raises on an arbitrary term" do
    for term <- [
          nil,
          1,
          "x",
          [],
          %{},
          %{op: :set_default},
          %Step{id: 1, from: 1, to: 1, kind: 1, up: 1, down: 1, lossy: 1}
        ] do
      assert StepSpec.validate(term, @manifest) == :error
    end

    assert StepSpec.validate(step(%{op: :set_default}), :not_a_map) == :error
  end

  test "S1 Catalog.validate/1 refuses a bad spec and keeps an opaque up" do
    assert catalog_ok?(%{op: :set_default, type: "catalog_uom", field: "f", value: "x"})

    refute catalog_ok?(%{
             op: :copy_field,
             type: "catalog_uom",
             from: "a",
             to: "b",
             transform: :unknown
           })

    refute catalog_ok?(%{op: :set_default, type: "catalog_uom", field: "x_f", value: "x"})
    refute catalog_ok?(%{op: :set_default, type: "not_managed", field: "f", value: "x"})
    # an `up` with no :op is not governed by the vocabulary (stored as before, refused at apply)
    assert catalog_ok?(%{})
  end

  test "S2 transforms" do
    assert StepSpec.transform(:identity, 5) == {:ok, 5}
    assert StepSpec.transform(:trim, "  a b ") == {:ok, "a b"}
    assert StepSpec.transform(:upcase, "ab") == {:ok, "AB"}
    assert StepSpec.transform(:trim, 5) == :error
    assert StepSpec.transform(:upcase, nil) == :error
    assert StepSpec.transform(:to_decimal, " 12.50 ") == {:ok, "12.50"}
    assert StepSpec.transform(:to_decimal, 7) == {:ok, "7"}
    assert StepSpec.transform(:to_decimal, 1.5) == {:ok, "1.5"}
    assert StepSpec.transform(:to_decimal, "abc") == :error
    assert StepSpec.transform(:to_decimal, "1.5x") == :error
    assert StepSpec.transform(:to_decimal, "Infinity") == :error
    assert StepSpec.transform(:to_decimal, "NaN") == :error
    assert StepSpec.transform(:to_decimal, nil) == :error
    assert StepSpec.transform(:bogus, "a") == :error
  end

  test "op_name, executable? and the spec hash" do
    a = step(%{op: :set_default, type: "t", field: "f", value: "x"})
    b = step(%{op: :set_default, type: "t", field: "f", value: "y"})
    assert StepSpec.op_name(a) == "set_default"
    assert StepSpec.op_name(step(%{}, kind: :code)) == "code"
    assert StepSpec.op_name(step(%{})) == "other"
    assert StepSpec.executable?(a)
    refute StepSpec.executable?(step(%{op: :rename_field, from: "a", to: "b"}))

    refute StepSpec.executable?(
             step(%{op: :set_default, type: "t", field: "f", value: 1}, kind: :code)
           )

    assert StepSpec.spec_hash(a) =~ ~r/\A[0-9a-f]{64}\z/
    assert StepSpec.spec_hash(a) == StepSpec.spec_hash(a)
    refute StepSpec.spec_hash(a) == StepSpec.spec_hash(b)
  end
end
