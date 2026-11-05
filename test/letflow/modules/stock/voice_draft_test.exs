defmodule Letflow.Modules.Stock.VoiceDraftTest do
  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.VoiceDraft

  @catalog %{
    items: [
      %{id: "i1", code: "NUT-M8", name: "Гайка М8", base_unit: "pcs"},
      %{id: "i2", code: "NUT-M10", name: "Гайка М10", base_unit: "pcs"},
      %{id: "i3", code: "BLT-M8-40", name: "Болт М8x40", base_unit: "pcs"},
      %{id: "i4", code: "OLD-1", name: "Old", base_unit: "pcs", active: false}
    ],
    locations: [
      %{id: "l1", code: "A-01", name: "A 1"},
      %{id: "l2", code: "B-02", name: "B 2"},
      %{id: "l3", code: "LA3", name: "Слева A 3"},
      %{id: "l4", code: "OLD-L", name: "Old", active: false}
    ]
  }

  defp answer(overrides) do
    base = %{
      "kind" => "receipt",
      "item_codes" => [],
      "location_words" => nil,
      "location_code" => nil,
      "to_location_words" => nil,
      "to_location_code" => nil,
      "quantity" => nil
    }

    Map.merge(base, Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
  end

  defp run(overrides, transcript) do
    text = Jason.encode!(answer(overrides))
    assert {:ok, parsed} = VoiceDraft.parse_answer(text)
    VoiceDraft.check(parsed, transcript, @catalog)
  end

  defp reasons(draft), do: Enum.map(draft.dropped, &{&1.field, &1.value, &1.reason})

  describe "typed phrases" do
    test "VD-P1 receipt with location and quantity" do
      d =
        run(
          [
            kind: "receipt",
            item_codes: ["BLT-M8-40"],
            location_words: "слева а три",
            location_code: "LA3",
            quantity: 80
          ],
          "приход замок восемьдесят штук слева а три"
        )

      assert d.kind == "receipt"
      assert [%{code: "BLT-M8-40"}] = d.items
      assert %{code: "LA3"} = d.location
      assert d.quantity == "80"
      assert d.dropped == []
    end

    test "VD-P2 transfer drops unknown and duplicate item" do
      d =
        run(
          [
            kind: "transfer",
            item_codes: ["NUT-M8", "NO-SUCH", "NUT-M10", "NUT-M8"],
            location_words: "а один",
            location_code: "A-01",
            to_location_words: "бэ два",
            to_location_code: "B-02",
            quantity: 15
          ],
          "переместил пятнадцать гаек из а один в бэ два"
        )

      assert Enum.map(d.items, & &1.code) == ["NUT-M8", "NUT-M10"]
      assert d.location.code == "A-01"
      assert d.to_location.code == "B-02"
      assert d.quantity == "15"

      assert reasons(d) == [
               {"item_codes", "NO-SUCH", "unknown_item"},
               {"item_codes", "NUT-M8", "duplicate_item"}
             ]
    end

    test "VD-P3 location words absent from the phrase" do
      d =
        run(
          [kind: "issue", location_words: "левый двор", location_code: "LE2", quantity: 26],
          "расход кнопка выхода двадцать шесть штук"
        )

      assert d.kind == "issue"
      assert d.location == nil
      assert reasons(d) == [{"location", "LE2", "location_not_said"}]
    end

    test "VD-P4 transfer of seven" do
      d =
        run(
          [
            kind: "transfer",
            item_codes: ["NUT-M8"],
            location_words: "а один",
            location_code: "A-01",
            to_location_words: "бэ два",
            to_location_code: "B-02",
            quantity: 7
          ],
          "переместил семь гаек эм восемь из а один в бэ два"
        )

      assert d.quantity == "7"
      assert {d.location.code, d.to_location.code} == {"A-01", "B-02"}
      assert d.dropped == []
    end

    test "VD-P5 two items kept for the user to choose" do
      d =
        run(
          [
            kind: "receipt",
            item_codes: ["NUT-M8", "NUT-M10"],
            location_words: "а один",
            location_code: "A-01",
            quantity: 20
          ],
          "приход гайки двадцать штук на а один"
        )

      assert length(d.items) == 2
      assert d.location.code == "A-01"
      assert d.quantity == "20"
      assert d.dropped == []
    end

    test "VD-P6b answer without JSON is bad_answer" do
      assert VoiceDraft.parse_answer("Sorry, I cannot help.") == {:error, :bad_answer}
    end

    test "VD-P7 unknown kind" do
      d = run([kind: "unknown"], "что-то")
      assert d.kind == "unknown"
      assert d.items == []
      assert d.dropped == []
    end
  end

  describe "failure reasons" do
    test "VD-R1 unknown_kind" do
      d = run([kind: "writeoff"], "x")
      assert d.kind == "unknown"
      assert reasons(d) == [{"kind", "writeoff", "unknown_kind"}]
    end

    test "VD-R2 unknown_item, also inactive" do
      d = run([item_codes: ["OLD-1", "ZZZ"]], "x")
      assert d.items == []
      assert Enum.map(d.dropped, & &1.reason) == ["unknown_item", "unknown_item"]
    end

    test "VD-R3 duplicate_item keeps order" do
      d = run([item_codes: ["NUT-M10", "NUT-M8", "NUT-M10"]], "x")
      assert Enum.map(d.items, & &1.code) == ["NUT-M10", "NUT-M8"]
      assert reasons(d) == [{"item_codes", "NUT-M10", "duplicate_item"}]
    end

    test "VD-R4 unknown_location (other tenant or inactive, words said)" do
      for code <- ["OTHER-TENANT", "OLD-L"] do
        d = run([location_words: "склад", location_code: code], "на склад")
        assert d.location == nil
        assert reasons(d) == [{"location", code, "unknown_location"}]
      end
    end

    test "VD-R5 location_not_said, empty words and empty transcript" do
      assert reasons(run([location_words: "а один", location_code: "A-01"], "")) ==
               [{"location", "A-01", "location_not_said"}]

      assert reasons(run([location_words: "", location_code: "A-01"], "a-01")) ==
               [{"location", "A-01", "location_not_said"}]
    end

    test "VD-R5b words match ignoring case, yo and spaces" do
      d = run([location_words: "Слева  А три", location_code: "LA3"], "слева а три")
      assert d.location.code == "LA3"
      d = run([location_words: "ёж", location_code: "A-01"], "ЕЖ")
      assert d.location.code == "A-01"
    end

    test "VD-R6 to_location_not_transfer" do
      d =
        run(
          [kind: "receipt", to_location_words: "бэ два", to_location_code: "B-02"],
          "приход на бэ два"
        )

      assert d.to_location == nil
      assert reasons(d) == [{"to_location", "B-02", "to_location_not_transfer"}]
    end

    test "VD-R7 negative_quantity" do
      d = run([quantity: -3], "x")
      assert d.quantity == nil
      assert reasons(d) == [{"quantity", "-3", "negative_quantity"}]
    end

    test "VD-R8 bad_quantity: zero on a receipt dropped, on a count kept" do
      assert reasons(run([kind: "receipt", quantity: 0], "x")) == [
               {"quantity", "0", "bad_quantity"}
             ]

      d = run([kind: "count", quantity: 0], "x")
      assert d.quantity == "0"
      assert d.dropped == []
    end
  end

  describe "parse_answer" do
    test "VD-A1 extra key" do
      text = Jason.encode!(Map.put(answer([]), "note", "hi"))
      assert VoiceDraft.parse_answer(text) == {:error, :bad_answer}
    end

    test "VD-A2 missing key" do
      text = Jason.encode!(Map.delete(answer([]), "quantity"))
      assert VoiceDraft.parse_answer(text) == {:error, :bad_answer}
      assert VoiceDraft.parse_answer("{}") == {:error, :bad_answer}
    end

    test "VD-A3 wrong types" do
      for bad <- [
            answer(kind: 1),
            answer(item_codes: "NUT-M8"),
            answer(item_codes: [1]),
            answer(location_code: 5),
            answer(quantity: "5")
          ] do
        assert VoiceDraft.parse_answer(Jason.encode!(bad)) == {:error, :bad_answer}
      end
    end

    test "VD-A4 wrapping accepted" do
      json = Jason.encode!(answer(kind: "issue"))

      for text <- [
            "```json\n" <> json <> "\n```",
            "<think>{\"a\":1}</think>" <> json,
            "Here: " <> json
          ] do
        assert {:ok, %{"kind" => "issue"}} = VoiceDraft.parse_answer(text)
      end
    end

    test "VD-A5 non-JSON and non-binary" do
      assert VoiceDraft.parse_answer("{not json}") == {:error, :bad_answer}
      assert VoiceDraft.parse_answer("[1,2]") == {:error, :bad_answer}
      assert VoiceDraft.parse_answer(nil) == {:error, :bad_answer}
    end
  end

  test "VD-Q1 quantity text forms" do
    assert run([quantity: 80], "x").quantity == "80"
    assert run([quantity: 1.5], "x").quantity == "1.5"

    assert {:ok, parsed} =
             VoiceDraft.parse_answer(
               ~s({"kind":"receipt","item_codes":[],"location_words":null,"location_code":null,"to_location_words":null,"to_location_code":null,"quantity":1e2})
             )

    assert VoiceDraft.check(parsed, "x", @catalog).quantity == "100"
  end
end
