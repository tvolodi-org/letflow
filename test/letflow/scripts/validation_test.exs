defmodule Letflow.Scripts.ValidationTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC10 (C11; design `lib/letflow/design/gh2534-7c-script-handler.md` 8.2): the
  top-level output key namespace `$` is reserved for host channels, so `Validation.manifest/1`
  refuses an `output_schema.properties` name starting with `$`. Nested `$` names are data.
  """

  use ExUnit.Case, async: true

  alias Letflow.Scripts.Validation

  @manifest %{
    "input_schema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}},
    "output_schema" => %{
      "type" => "object",
      "properties" => %{"y" => %{"type" => "integer"}},
      "additionalProperties" => false
    },
    "fail_codes" => []
  }

  test "manifest $ name refused" do
    assert Validation.manifest(@manifest) == :ok

    for name <- ["$writes", "$x", "$"] do
      manifest = put_in(@manifest, ["output_schema", "properties", name], %{"type" => "integer"})
      assert Validation.manifest(manifest) == {:error, :invalid_manifest}, name
    end
  end

  test "a nested `$` property name and a `$` input name stay allowed" do
    nested =
      put_in(@manifest, ["output_schema", "properties", "y"], %{
        "type" => "object",
        "properties" => %{"$nested" => %{"type" => "integer"}}
      })

    assert Validation.manifest(nested) == :ok

    input = put_in(@manifest, ["input_schema", "properties", "$in"], %{"type" => "integer"})
    assert Validation.manifest(input) == :ok
  end
end
