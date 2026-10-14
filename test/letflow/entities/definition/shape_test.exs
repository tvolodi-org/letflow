defmodule Letflow.Entities.Definition.ShapeTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.Definition.Shape` (REQ-225). See
  `lib/letflow/design/req225-entity-definition-schema-validation.md` §§4-5.

  Covers AC3 (canonicalisation/hashing delegates to the existing
  `Letflow.Repository.Canonicaliser`, no second canonicaliser) and AC4 (the
  logical-shape-versioning rule: non-logical vs. logical changes).

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency -- `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Definition.Shape
  alias Letflow.Repository.Canonicaliser

  @base_definition %{
    name: "customer",
    display_name: "Customer",
    fields: [
      %{name: "id", type: :string, required: true, queried: true},
      %{name: "email", type: :string, required: true, queried: true}
    ]
  }

  # ---------------------------------------------------------------------------
  # AC3 -- canonicalisation/hashing reuses Letflow.Repository.Canonicaliser
  # directly; no second canonicaliser is written by this module.
  # ---------------------------------------------------------------------------

  describe "AC3 -- content_hash/1 delegates to Letflow.Repository.Canonicaliser" do
    test "content_hash/1 equals manually calling Canonicaliser.canonicalize_content/2 + content_hash/1 on the same JSON encoding" do
      json_bytes = Jason.encode!(@base_definition)
      {:ok, canonical_form} = Canonicaliser.canonicalize_content("application/json", json_bytes)
      expected = Canonicaliser.content_hash(canonical_form)

      assert Shape.content_hash(@base_definition) == expected
    end

    test "content_hash/1 returns a raw 32-byte binary, matching Canonicaliser.content_hash/1's own return shape" do
      hash = Shape.content_hash(@base_definition)
      assert is_binary(hash)
      assert byte_size(hash) == 32
    end

    test "two raw JSON texts for the same entity definition differing only in key order and insignificant whitespace produce the same hash via Canonicaliser directly (no second canonicaliser reimplements this)" do
      doc_a =
        ~s({"name":"customer","display_name":"Customer","fields":[{"name":"id","type":"string"}]})

      doc_b =
        ~s({ "fields" : [ { "type" : "string" , "name" : "id" } ] , "display_name" : "Customer" , "name" : "customer" })

      assert {:ok, canonical_a} = Canonicaliser.canonicalize_content("application/json", doc_a)
      assert {:ok, canonical_b} = Canonicaliser.canonicalize_content("application/json", doc_b)

      assert canonical_a == canonical_b
      assert Canonicaliser.content_hash(canonical_a) == Canonicaliser.content_hash(canonical_b)
    end

    test "a structurally different definition produces a different hash" do
      other = put_in(@base_definition.fields, [%{name: "id", type: :integer}])

      refute Shape.content_hash(@base_definition) == Shape.content_hash(other)
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- logical-shape-versioning rule.
  # ---------------------------------------------------------------------------

  describe "AC4 -- logical_shape_of/1: non-logical changes do not bump the digest" do
    test "reordering fields does not change the logical shape digest" do
      forward = @base_definition

      reversed =
        Map.put(forward, :fields, Enum.reverse(forward.fields))

      assert Shape.logical_shape_of(forward) == Shape.logical_shape_of(reversed)
      # But the raw content hash DOES change, since array order is significant there.
      refute Shape.content_hash(forward) == Shape.content_hash(reversed)
    end

    test "changing display_name only does not change the logical shape digest" do
      renamed = Map.put(@base_definition, :display_name, "Customers")

      assert Shape.logical_shape_of(@base_definition) == Shape.logical_shape_of(renamed)
      refute Shape.content_hash(@base_definition) == Shape.content_hash(renamed)
    end

    test "changing description only does not change the logical shape digest" do
      with_description = Map.put(@base_definition, :description, "A customer entity")
      other_description = Map.put(@base_definition, :description, "Something else")

      assert Shape.logical_shape_of(with_description) == Shape.logical_shape_of(other_description)
    end

    test "reordering indexes/foreign_keys/constraints does not change the logical shape digest" do
      definition =
        Map.merge(@base_definition, %{
          foreign_keys: [
            %{name: "fk_a", field: "id", references_entity: "a"},
            %{name: "fk_b", field: "email", references_entity: "b"}
          ]
        })

      reordered = Map.put(definition, :foreign_keys, Enum.reverse(definition.foreign_keys))

      assert Shape.logical_shape_of(definition) == Shape.logical_shape_of(reordered)
    end
  end

  describe "AC4 -- logical_shape_of/1: logical changes DO bump the digest" do
    test "adding a required field changes the logical shape digest" do
      with_extra_field =
        Map.put(
          @base_definition,
          :fields,
          @base_definition.fields ++ [%{name: "phone", type: :string, required: true}]
        )

      refute Shape.logical_shape_of(@base_definition) == Shape.logical_shape_of(with_extra_field)
    end

    test "changing a field's type changes the logical shape digest" do
      changed_type =
        Map.put(@base_definition, :fields, [
          %{name: "id", type: :integer, required: true, queried: true},
          %{name: "email", type: :string, required: true, queried: true}
        ])

      refute Shape.logical_shape_of(@base_definition) == Shape.logical_shape_of(changed_type)
    end

    test "removing a field changes the logical shape digest" do
      fewer_fields = Map.put(@base_definition, :fields, [List.first(@base_definition.fields)])

      refute Shape.logical_shape_of(@base_definition) == Shape.logical_shape_of(fewer_fields)
    end
  end

  # ---------------------------------------------------------------------------
  # GH #2529 -- hash stability. The two digests below were captured by running
  # this exact fixture through origin/main's (pre-change) Shape and
  # Canonicaliser, loaded from `git show origin/main:...` into renamed scratch
  # modules. A key-less definition must keep hashing identically; adding
  # `append_only: true` must change the logical shape version.
  # ---------------------------------------------------------------------------

  @gh2529_keyless %{
    name: "ledger",
    display_name: "Ledger",
    description: "GH 2529 hash-stability fixture",
    fields: [
      %{name: "title", type: :string, required: true, queried: true},
      %{name: "amount", type: :decimal, decimal_precision: 12, decimal_scale: 2},
      %{name: "kind", type: :enum, enum_values: ["credit", "debit"]}
    ],
    indexes: [%{name: "title_idx", fields: ["title"], unique: false}]
  }

  @gh2529_pinned_content_hash "db44ca2b364844178062af7fc0e52c1f1be4cd9851254492970999967bbb1c70"
  @gh2529_pinned_logical_shape "eec9060400f298473d0b8182764b366888798a59b07ba7cf83cc98a4accea8bc"

  defp gh2529_hex(digest), do: Base.encode16(digest, case: :lower)

  describe "GH #2529 hash stability" do
    test "a key-less definition's content_hash/1 equals the pinned pre-change digest" do
      assert gh2529_hex(Shape.content_hash(@gh2529_keyless)) == @gh2529_pinned_content_hash
    end

    test "a key-less definition's logical_shape_of/1 equals the pinned pre-change digest" do
      assert gh2529_hex(Shape.logical_shape_of(@gh2529_keyless)) ==
               @gh2529_pinned_logical_shape
    end

    test "adding append_only: true changes the logical shape version" do
      flagged = Map.put(@gh2529_keyless, :append_only, true)

      refute gh2529_hex(Shape.logical_shape_of(flagged)) == @gh2529_pinned_logical_shape
      refute Shape.logical_shape_of(flagged) == Shape.logical_shape_of(@gh2529_keyless)
    end
  end

  # ---------------------------------------------------------------------------
  # GH #2532 -- hash stability. The two digests below were captured by running
  # this exact fixture through origin/main's (f7ce96f0, pre-change) Shape and
  # Canonicaliser, loaded from `git show origin/main:...` into renamed scratch
  # modules (`Gh2532Pre.*`). A key-less definition must keep hashing
  # identically; `non_negative: true` and `min: 0` must be distinct logical
  # shapes (design D4).
  # ---------------------------------------------------------------------------

  @gh2532_keyless %{
    name: "stock",
    display_name: "Stock",
    description: "GH 2532 hash-stability fixture",
    fields: [
      %{name: "sku", type: :string, required: true, queried: true},
      %{name: "qty", type: :integer, required: true, queried: true},
      %{name: "price", type: :decimal, decimal_precision: 12, decimal_scale: 2}
    ]
  }

  @gh2532_pinned_content_hash "ed5be3c22e6318c3afb3ef8da8d7c7f320c239cf14754ba1b22c5366431ab440"
  @gh2532_pinned_logical_shape "ad32dffa260db4f984048ee63bff5ea5dc6e1e0f3e4c61819541ed535f159ec7"

  defp gh2532_with_qty(extra) do
    Map.update!(@gh2532_keyless, :fields, fn fields ->
      Enum.map(fields, fn
        %{name: "qty"} = qty -> Map.merge(qty, extra)
        field -> field
      end)
    end)
  end

  describe "GH #2532 hash stability" do
    test "a key-less definition's content_hash/1 equals the pinned pre-change digest" do
      assert gh2529_hex(Shape.content_hash(@gh2532_keyless)) == @gh2532_pinned_content_hash
    end

    test "a key-less definition's logical_shape_of/1 equals the pinned pre-change digest" do
      assert gh2529_hex(Shape.logical_shape_of(@gh2532_keyless)) ==
               @gh2532_pinned_logical_shape
    end

    test "min: 0 and non_negative: true are distinct logical shapes, both distinct from key-less" do
      min_zero = Shape.logical_shape_of(gh2532_with_qty(%{min: 0}))
      non_negative = Shape.logical_shape_of(gh2532_with_qty(%{non_negative: true}))

      refute min_zero == non_negative
      refute gh2529_hex(min_zero) == @gh2532_pinned_logical_shape
      refute gh2529_hex(non_negative) == @gh2532_pinned_logical_shape
    end
  end
end
