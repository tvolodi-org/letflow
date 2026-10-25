defmodule Letflow.Documents.CanonicalTest do
  @moduledoc """
  REQ-542 / GH #3164 criteria 8 and 9: `Letflow.Documents.Canonical` -- canonical form and
  content hash (decision 0056 D3). Design: state/tasks/T-0474/design.md, tests C1..C5.
  Pure, no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.Canonical

  @tenant "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @doc_id "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @entity "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  defp base do
    %{
      tenant_uuid: @tenant,
      document_id: @doc_id,
      type_key: "purchase_request",
      legal_entity_id: @entity,
      number: 7,
      version_no: 1,
      canonical_content: ~s({"a":1})
    }
  end

  defp hash!(inputs) do
    {:ok, hash} = Canonical.content_hash(inputs)
    hash
  end

  describe "C1 refusals" do
    test "floats, integer-valued included" do
      assert {:error, :float_not_allowed} = Canonical.canonicalize(%{"a" => 1.5})
      assert {:error, :float_not_allowed} = Canonical.canonicalize(%{"a" => 1.0})
      assert {:error, :float_not_allowed} = Canonical.canonicalize(%{"a" => [%{"b" => 2.5}]})
      assert {:error, :float_not_allowed} = Canonical.canonicalize(~s({"a":1.5}))
    end

    test "non-finite and unparsable JSON text" do
      for text <- ["NaN", "Infinity", ~s({"a":NaN}), ~s({"a":1e999}), "{", ""] do
        assert {:error, :invalid_json} = Canonical.canonicalize(text), text
      end
    end

    test "duplicate keys in text, nested, and after NFC" do
      assert {:error, :duplicate_key} = Canonical.canonicalize(~s({"a":1,"a":2}))
      assert {:error, :duplicate_key} = Canonical.canonicalize(~s({"x":{"b":1,"b":2}}))
      assert {:error, :duplicate_key} = Canonical.canonicalize(%{"é" => 1, "é" => 2})
    end

    test "other terms" do
      assert {:error, :invalid_key} = Canonical.canonicalize(%{a: 1})
      assert {:error, :unsupported_value} = Canonical.canonicalize(%{"a" => :nan})
      assert {:error, :unsupported_value} = Canonical.canonicalize(%{"a" => {1, 2}})
      assert {:error, :invalid_utf8} = Canonical.canonicalize(%{"a" => <<0xFF>>})
    end
  end

  describe "C2 canonical bytes" do
    test "NFC and NFD give the same bytes" do
      assert Canonical.canonicalize(%{"k" => "é"}) == Canonical.canonicalize(%{"k" => "é"})
      assert Canonical.canonicalize(%{"é" => 1}) == Canonical.canonicalize(%{"é" => 1})
    end

    test "key order is irrelevant, array order is not" do
      assert Canonical.canonicalize(~s({"b":1,"a":2})) == {:ok, ~s({"a":2,"b":1})}
      assert Canonical.canonicalize(%{"b" => 1, "a" => 2}) == {:ok, ~s({"a":2,"b":1})}
      refute Canonical.canonicalize(%{"l" => [1, 2]}) == Canonical.canonicalize(%{"l" => [2, 1]})
    end
  end

  describe "C3 content_hash, one input at a time" do
    test "each of the eight inputs changes the hash" do
      b = base()
      base_hash = hash!(b)
      assert base_hash =~ ~r/^[0-9a-f]{64}$/

      variants = [
        hash!(%{b | tenant_uuid: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"}),
        hash!(%{b | document_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}),
        hash!(%{b | type_key: "invoice"}),
        hash!(%{b | legal_entity_id: "ffffffff-ffff-4fff-8fff-ffffffffffff"}),
        hash!(%{b | number: 8}),
        hash!(%{b | version_no: 2}),
        hash!(%{b | canonical_content: ~s({"a":2})}),
        Canonical.digest("letflow.document.v2", fields(b))
      ]

      assert length(Enum.uniq([base_hash | variants])) == 9
    end

    test "nil legal entity is the sentinel" do
      assert hash!(%{base() | legal_entity_id: nil}) ==
               hash!(%{base() | legal_entity_id: Canonical.legal_entity_sentinel()})
    end

    test "framing: moving a byte between fields changes the hash" do
      a = hash!(%{base() | type_key: "ab", canonical_content: "c"})
      b = hash!(%{base() | type_key: "a", canonical_content: "bc"})
      refute a == b
    end
  end

  defp fields(b) do
    [
      b.tenant_uuid,
      b.document_id,
      b.type_key,
      b.legal_entity_id,
      Integer.to_string(b.number),
      Integer.to_string(b.version_no),
      b.canonical_content
    ]
  end

  describe "C4 pinned vector" do
    # Expected value computed outside the code under test: the byte string (domain tag, then each
    # field as an 8-byte big-endian length and its bytes) built with bash printf and hashed with
    # `sha256sum`.
    test "fixed input, fixed digest" do
      assert hash!(base()) == "2cb47a27a83f3062c67d8e4e3af71209d8575f412e2a78938ec96d188fbc4c6a"
    end
  end

  describe "C5 refused input" do
    test "caller hash, nil number, malformed uuid, extra key, non-map" do
      assert {:error, :invalid_hash_input} =
               Canonical.content_hash(Map.put(base(), :content_hash, "x"))

      assert {:error, :invalid_hash_input} = Canonical.content_hash(%{base() | number: nil})

      assert {:error, :invalid_hash_input} =
               Canonical.content_hash(%{base() | tenant_uuid: "nope"})

      assert {:error, :invalid_hash_input} = Canonical.content_hash(%{base() | version_no: 0})
      assert {:error, :invalid_hash_input} = Canonical.content_hash(Map.delete(base(), :type_key))
      assert {:error, :invalid_hash_input} = Canonical.content_hash("x")
    end
  end
end
