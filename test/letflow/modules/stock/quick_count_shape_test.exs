defmodule Letflow.Modules.Stock.QuickCountShapeTest do
  @moduledoc """
  REQ-854 / GH #4564 criterion 9 (QS-1..): the pure shape check of the quick count body, the pure
  posting helpers (`QuickCountPosting`), the `Kinds` entry and the `LedgerPolicy` rule for the cause
  `count_set`. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.QuickCountPosting
  alias Letflow.Modules.Stock.Documents.QuickCountShape
  alias Letflow.Modules.Stock.LedgerPolicy

  @id "11111111-1111-4111-8111-111111111111"
  @id2 "22222222-2222-4222-8222-222222222222"
  @id3 "33333333-3333-4333-8333-333333333333"
  @id4 "44444444-4444-4444-8444-444444444444"

  defp body(extra \\ %{}) do
    Map.merge(
      %{
        "org_unit_id" => @id,
        "location_id" => @id2,
        "catalog_item_id" => @id3,
        "catalog_uom_id" => @id4,
        "counted_quantity" => "7",
        "reason_code" => "recount"
      },
      extra
    )
  end

  defp refused(extra, reason) do
    assert {:error, {^reason, _extras}} = QuickCountShape.parse(extra)
  end

  test "QS-1 a valid body parses to one line with 9-decimal counted quantity and the header" do
    assert {:ok, %{kind: "quick_count", header: header, lines: [line]}} =
             QuickCountShape.parse(body())

    assert header == %{"org_unit_id" => @id, "reason_code" => "recount"}
    assert line["counted_quantity"] == "7.000000000" and line["line_no"] == 1
    assert line["location_id"] == @id2 and line["catalog_item_id"] == @id3
    refute Map.has_key?(line, "org_unit_id")
  end

  test "QS-2 counted quantity 0 is accepted here; negative, 10 decimals, numbers and junk are not" do
    assert {:ok, %{lines: [%{"counted_quantity" => "0.000000000"}]}} =
             QuickCountShape.parse(body(%{"counted_quantity" => "0"}))

    assert {:ok, %{lines: [%{"counted_quantity" => "0.123456789"}]}} =
             QuickCountShape.parse(body(%{"counted_quantity" => "0.123456789"}))

    for bad <- ["-1", "-0", "1.0000000001", "1e3", ".5", "5.", "", " 1", 7, nil, %{}, 1.5] do
      refused(body(%{"counted_quantity" => bad}), "quantity_invalid")
    end
  end

  test "QS-3 reason code is a closed list; other needs a text; the text is 1..500, not blank" do
    for code <- ~w(recount found missing damaged other) do
      text = if code == "other", do: %{"reason_text" => "why"}, else: %{}
      assert {:ok, _} = QuickCountShape.parse(body(Map.merge(%{"reason_code" => code}, text)))
    end

    refused(body(%{"reason_code" => "lost"}), "reason_invalid")
    refused(body(%{"reason_code" => nil}), "reason_invalid")
    refused(Map.delete(body(), "reason_code"), "reason_invalid")
    refused(body(%{"reason_code" => "other"}), "reason_invalid")
    refused(body(%{"reason_code" => "other", "reason_text" => "   "}), "reason_invalid")
    refused(body(%{"reason_text" => String.duplicate("x", 501)}), "reason_invalid")
    refused(body(%{"reason_text" => 5}), "reason_invalid")
    assert {:ok, _} = QuickCountShape.parse(body(%{"reason_text" => String.duplicate("x", 500)}))
  end

  test "QS-3b reason text is bounded in bytes before any per-character work" do
    # one grapheme (a base letter and repeated combining marks) passes the 500-character rule
    pair = <<0x301::utf8, 0x316::utf8>>
    one_grapheme = "a" <> String.duplicate(pair, 1_000)
    assert String.length(one_grapheme) == 1
    refused(body(%{"reason_text" => one_grapheme}), "reason_invalid")
    refused(body(%{"reason_text" => String.duplicate("x", 2_001)}), "reason_invalid")
    # a multibyte text at the character limit (4 bytes each) is still accepted
    assert {:ok, _} =
             QuickCountShape.parse(body(%{"reason_text" => String.duplicate("\u{1F600}", 500)}))
  end

  test "QS-4 required, not allowed and invalid ids are refused with the field name" do
    assert {:error, {"field_required", %{"field" => "location_id"}}} =
             QuickCountShape.parse(Map.delete(body(), "location_id"))

    for key <- ["kind", "lines", "book_quantity", "difference", "document_id", "event_time"] do
      assert {:error, {"field_not_allowed", %{"field" => ^key}}} =
               QuickCountShape.parse(body(%{key => "x"}))
    end

    assert {:error, {"field_invalid", %{"field" => "catalog_item_id"}}} =
             QuickCountShape.parse(body(%{"catalog_item_id" => "nope"}))

    assert {:error, {"field_invalid", %{"field" => "body"}}} = QuickCountShape.parse(:not_a_map)

    assert {:ok, %{lines: [line]}} =
             QuickCountShape.parse(body(%{"catalog_lot_id" => @id, "responsible_id" => @id}))

    assert line["catalog_lot_id"] == @id and line["responsible_id"] == @id
  end

  test "QS-5 the Kinds entry: cause count_set, QCT, approve node, no sides, unknown_kind on save" do
    spec = Kinds.get("quick_count")

    assert spec.cause == "count_set" and spec.prefix == "QCT" and
             spec.completion_node == "approve"

    assert spec.type_key == "stock_quick_count" and spec.line_type == "stock_quick_count_line"
    assert Kinds.sides(spec, %{"org_unit_id" => @id}) == {nil, nil}
    assert Kinds.withdrawable?("quick_count")

    assert {:error, {"unknown_kind", %{}}} =
             Kinds.parse(body(%{"kind" => "quick_count"}), :create)

    assert {:error, {"unknown_kind", %{}}} =
             Kinds.parse(body(%{"kind" => "quick_count"}), {:replace, "quick_count"})
  end

  defp issued(difference, book \\ "10.000000000") do
    %{
      version_id: "ver-1",
      content: %{
        "kind" => "quick_count",
        "header" => %{"org_unit_id" => @id, "reason_code" => "recount"},
        "lines" => [
          %{
            "line_no" => 1,
            "location_id" => @id2,
            "catalog_item_id" => @id3,
            "catalog_uom_id" => @id4,
            "counted_quantity" => "7.000000000",
            "book_quantity" => book,
            "difference" => difference
          }
        ]
      }
    }
  end

  test "QS-6 the command of a shortage has a from side, the absolute quantity and the book" do
    assert {:ok, command} =
             QuickCountPosting.command(%{id: "doc-1"}, issued("-3.000000000"), %{1 => @id})

    assert %{"cause" => "count_set", "reason_code" => "recount"} = command
    assert command["document_type"] == "stock_quick_count"
    refute Map.has_key?(command, "device_id") or Map.has_key?(command, "client_event_time")
    assert [line] = command["lines"]
    assert line["quantity"] == "3.000000000" and line["expected_on_hand"] == "10.000000000"
    assert line["from"]["location"] == @id2 and line["from"]["org_unit"] == @id
    refute Map.has_key?(line, "to")
  end

  test "QS-7 the command of a surplus has a to side; a zero difference has no command and no leg" do
    assert {:ok, %{"lines" => [line]}} =
             QuickCountPosting.command(
               %{id: "doc-1"},
               issued("2.500000000", "4.500000000"),
               %{1 => @id}
             )

    assert line["to"]["location"] == @id2 and line["quantity"] == "2.500000000"
    refute Map.has_key?(line, "from")

    zero = issued("0.000000000")
    assert QuickCountPosting.command(%{id: "doc-1"}, zero, %{1 => @id}) == :none
    assert QuickCountPosting.confirmed?(zero.content)
    refute QuickCountPosting.confirmed?(issued("-3.000000000").content)
    assert QuickCountPosting.expected_legs(zero.content, fn _, _, _, _, _, _, _ -> :leg end) == []

    assert {:error, :line_record_missing} =
             QuickCountPosting.command(%{id: "doc-1"}, issued("1.000000000"), %{})
  end

  # -- the policy ---------------------------------------------------------------------------------

  defp policy_line(extra) do
    Map.merge(
      %{
        line_id: @id,
        sku: @id3,
        unit: "u1",
        quantity: "3",
        expected_on_hand: "10",
        from: %{org_unit: @id, location: @id2}
      },
      extra
    )
  end

  defp declare(lines, extra \\ %{}) do
    LedgerPolicy.declare(
      Map.merge(%{cause: "count_set", reason_code: "recount", lines: lines}, extra),
      %{}
    )
  end

  test "QS-8 the policy builds one leg with expected_on_hand as a decimal" do
    assert {:ok, %{cause: "count_set", legs: [leg]}} = declare([policy_line(%{})])
    assert Decimal.eq?(leg.quantity, -3) and leg.expected_on_hand == Decimal.new("10")

    assert {:ok, %{legs: [up]}} =
             declare([policy_line(%{from: nil, to: %{org_unit: @id, location: @id2}})])

    assert Decimal.eq?(up.quantity, 3)

    assert {:ok, %{legs: [zero_book]}} = declare([policy_line(%{expected_on_hand: "0"})])
    assert Decimal.eq?(zero_book.expected_on_hand, 0)

    # decision 0090 (T-2288): a negative book is counted; the posting carries it as expected.
    assert {:ok, %{legs: [neg_book]}} = declare([policy_line(%{expected_on_hand: "-1"})])
    assert Decimal.eq?(neg_book.expected_on_hand, -1)
  end

  test "QS-9 the policy refuses a missing or bad expected, over 1000 lines, both sides and client time" do
    bad = fn line -> assert {:error, {:invalid_posting, %{leg_no: 1}}} = declare([line]) end
    bad.(Map.delete(policy_line(%{}), :expected_on_hand))
    bad.(policy_line(%{expected_on_hand: "1.0000000001"}))
    bad.(policy_line(%{expected_on_hand: 10}))
    bad.(policy_line(%{to: %{org_unit: @id, location: @id2}}))
    bad.(policy_line(%{quantity: "0"}))

    # REQ-885: the policy takes one line per change of a workbook load (1 to 1000); the one-line rule
    # of `POST /quick-counts` is the route's (`QuickCountShape`), not the policy's.
    assert {:ok, %{legs: [_, _]}} = declare([policy_line(%{}), policy_line(%{})])
    assert {:error, {:invalid_posting, _}} = declare(List.duplicate(policy_line(%{}), 1001))

    for key <- [:device_id, :client_seq, :client_event_time, :event_time] do
      assert {:error, {:invalid_posting, _}} = declare([policy_line(%{})], %{key => "x"})
    end

    # no other cause accepts the key
    assert {:error, {:invalid_posting, _}} =
             LedgerPolicy.declare(
               %{
                 cause: "issue",
                 lines: [policy_line(%{})]
               },
               %{}
             )
  end
end
