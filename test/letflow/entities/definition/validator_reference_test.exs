defmodule Letflow.Entities.Definition.ValidatorReferenceTest do
  @moduledoc "REQ-636: the `reference` field attribute (Validator rule `:invalid_reference`). Pure."

  use ExUnit.Case, async: true

  alias Letflow.Entities.Definition.Validator

  @ref %{"module_id" => "org", "entity_type" => "org_unit"}

  defp definition(field_extra, type \\ :string) do
    %{
      name: "holder",
      display_name: "Holder",
      fields: [%{name: "unit", type: type} |> Map.merge(field_extra)]
    }
  end

  defp rules(def_),
    do: with({:error, vs} <- Validator.validate(def_), do: Enum.map(vs, & &1.rule))

  test "V-ok: a string field with a well-formed reference" do
    assert Validator.validate(definition(%{reference: @ref})) == :ok
  end

  test "V-not-string-type" do
    assert rules(definition(%{reference: @ref}, :integer)) == [:invalid_reference]
  end

  test "V-bad-shape: non-map, missing key, extra key, atom keys" do
    for bad <- [
          "org",
          %{"module_id" => "org"},
          Map.put(@ref, "x", "y"),
          %{module_id: "org", entity_type: "t"}
        ] do
      assert rules(definition(%{reference: bad})) == [:invalid_reference], inspect(bad)
    end
  end

  test "V-bad-module-id and V-bad-entity-type" do
    for bad <- ["Org", "", "1org", "org\n", 5, String.duplicate("a", 65)] do
      assert rules(definition(%{reference: %{@ref | "module_id" => bad}})) == [:invalid_reference]

      assert rules(definition(%{reference: %{@ref | "entity_type" => bad}})) == [
               :invalid_reference
             ]
    end
  end

  test "V-with-enum" do
    assert :invalid_reference in rules(definition(%{reference: @ref, enum_values: ["a"]}))
  end
end
