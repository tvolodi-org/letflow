defmodule Letflow.Entities.ExternalRefTest do
  @moduledoc """
  GH #2659 / REQ-505 PR-1, T15: unit tests for the pure `Letflow.Entities.ExternalRef.parse/1`
  (design `lib/letflow/design/gh2659-external-ref-idempotent-import.md` section 2.3).
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.ExternalRef

  defp ok(system, id), do: {:ok, %{system: system, id: id}}

  describe "parse/1 accepts" do
    test "a lower-case slug system and a string id" do
      assert ExternalRef.parse(%{"system" => "1c", "id" => "42"}) == ok("1c", "42")

      assert ExternalRef.parse(%{"system" => "sap.erp_v-2", "id" => "A/B 7"}) ==
               ok("sap.erp_v-2", "A/B 7")
    end

    test "boundary lengths: 64-byte system, 255-byte id, 1-byte each" do
      system = String.duplicate("a", 64)
      id = String.duplicate("x", 255)
      assert ExternalRef.parse(%{"system" => system, "id" => id}) == ok(system, id)
      assert ExternalRef.parse(%{"system" => "a", "id" => "b"}) == ok("a", "b")
    end

    test "an id is compared byte-exact: surrounding whitespace and case are kept" do
      assert ExternalRef.parse(%{"system" => "erp", "id" => " Ab "}) == ok("erp", " Ab ")
    end

    test "a multi-byte UTF-8 id within the byte limit" do
      assert ExternalRef.parse(%{"system" => "erp", "id" => "Žeň-№7"}) == ok("erp", "Žeň-№7")
    end
  end

  describe "frozen corpus (values valid at PR-1 must stay valid)" do
    # The parser may only be LOOSENED for history (see the ExternalRef moduledoc): a rebuild
    # re-parses old events with the live parser. Never remove an entry; add new ones.
    @frozen_valid [
      {"1c", "42"},
      {"sap", "0000012345"},
      {"erp.eu-west_1", "A/B 7"},
      {"a", "x"},
      {"wms2", "SKU-001/\u0416\u0435\u043B\u0442\u044B\u0439"},
      {"crm", " leading and trailing "},
      {"crm", "\u00A0nbsp-prefixed"},
      {"legacy", "id with spaces & punctuation: (1)#2;3"},
      {"x9", String.duplicate("\u017E", 127)},
      {"s", String.duplicate("i", 255)}
    ]

    test "every frozen pair still parses to itself" do
      for {system, id} <- @frozen_valid do
        assert ExternalRef.parse(%{"system" => system, "id" => id}) == ok(system, id)
      end
    end
  end

  describe "parse/1 rejects with :external_ref_invalid" do
    @invalid {:error, :external_ref_invalid}

    test "a mixed-case or non-slug system (never case-folded)" do
      assert ExternalRef.parse(%{"system" => "SAP", "id" => "1"}) == @invalid
      assert ExternalRef.parse(%{"system" => "Sap", "id" => "1"}) == @invalid
      assert ExternalRef.parse(%{"system" => "_sap", "id" => "1"}) == @invalid
      assert ExternalRef.parse(%{"system" => "-sap", "id" => "1"}) == @invalid
      assert ExternalRef.parse(%{"system" => "sa p", "id" => "1"}) == @invalid
      assert ExternalRef.parse(%{"system" => "sap\n", "id" => "1"}) == @invalid
      assert ExternalRef.parse(%{"system" => "", "id" => "1"}) == @invalid
    end

    test "length limits: 65-byte system, 256-byte id, empty id" do
      assert ExternalRef.parse(%{"system" => String.duplicate("a", 65), "id" => "1"}) == @invalid
      assert ExternalRef.parse(%{"system" => "a", "id" => String.duplicate("x", 256)}) == @invalid
      assert ExternalRef.parse(%{"system" => "a", "id" => ""}) == @invalid
    end

    test "a multi-byte id counts bytes, not graphemes" do
      # 128 two-byte characters = 256 bytes
      assert ExternalRef.parse(%{"system" => "a", "id" => String.duplicate("ž", 128)}) == @invalid
      assert {:ok, _} = ExternalRef.parse(%{"system" => "a", "id" => String.duplicate("ž", 127)})
    end

    test "control and format characters in an id (tab, newline, DEL, zero-width, bidi, BOM)" do
      for bad <- ["a\tb", "a\nb", "a\u007Fb", "a\u200Bb", "a\u200Db", "a\u202Eb", "\uFEFFab"] do
        assert ExternalRef.parse(%{"system" => "a", "id" => bad}) == @invalid
      end

      # Ordinary printable characters, including interior and surrounding spaces, stay valid.
      assert {:ok, _} = ExternalRef.parse(%{"system" => "a", "id" => " a b "})
    end

    test "all-Unicode-whitespace ids (U+00A0, U+3000, U+2003) are rejected, a non-blank one is not" do
      for blank <- ["\u00A0", "\u3000", "\u2003", " \u00A0\u3000 "] do
        assert ExternalRef.parse(%{"system" => "a", "id" => blank}) == @invalid
      end

      assert {:ok, _} = ExternalRef.parse(%{"system" => "a", "id" => "\u00A0x"})
    end

    test "NUL, all-whitespace and invalid UTF-8 ids" do
      assert ExternalRef.parse(%{"system" => "a", "id" => "a" <> <<0>> <> "b"}) == @invalid
      assert ExternalRef.parse(%{"system" => "a", "id" => "   "}) == @invalid
      assert ExternalRef.parse(%{"system" => "a", "id" => "\t\n"}) == @invalid
      assert ExternalRef.parse(%{"system" => "a", "id" => <<0xFF, 0xFE>>}) == @invalid
    end

    test "unknown keys, missing keys, atom keys" do
      assert ExternalRef.parse(%{"system" => "a", "id" => "1", "extra" => "x"}) == @invalid
      assert ExternalRef.parse(%{"system" => "a"}) == @invalid
      assert ExternalRef.parse(%{"id" => "1"}) == @invalid
      assert ExternalRef.parse(%{}) == @invalid
      assert ExternalRef.parse(%{system: "a", id: "1"}) == @invalid
    end

    test "non-string values (a numeric id must be sent as a string)" do
      assert ExternalRef.parse(%{"system" => "a", "id" => 42}) == @invalid
      assert ExternalRef.parse(%{"system" => 1, "id" => "42"}) == @invalid
      assert ExternalRef.parse(%{"system" => nil, "id" => nil}) == @invalid
    end

    test "non-objects" do
      for term <- [nil, "a:1", ["a", "1"], 42, :ref, {"a", "1"}] do
        assert ExternalRef.parse(term) == @invalid
      end
    end
  end
end
