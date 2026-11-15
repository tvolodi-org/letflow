defmodule Letflow.Modules.Assets.CountSheetPrintTest do
  @moduledoc "T-1932 (REQ-821, asset count K6) design tests P1, P2: the plain count sheet PDF."

  use ExUnit.Case, async: true

  alias Letflow.Modules.Assets.CountSheetPrint

  @chair "33333333-3333-4333-8333-333333333333"
  @member "44444444-4444-4444-8444-444444444444"
  @resp "55555555-5555-4555-8555-555555555555"

  defp line(no) do
    %{
      "line_no" => no,
      "kind" => "book",
      "name" => "Chair #{no}",
      "inventory_number" => "INV-#{no}",
      "acquisition_date" => "2024-03-05",
      "book_value" => "1500.5",
      "book_quantity" => "1",
      "counted_quantity" => "1",
      "book_material_responsible_id" => @resp
    }
  end

  defp issued(n) do
    %{
      number_label: "ACS-1",
      issued_at: "2026-11-05T20:00:00Z",
      content: %{
        "chair_employee_id" => @chair,
        "member_employee_ids" => [@chair, @member],
        "cut_off_at" => "2026-11-05T20:00:00Z",
        "lines" => for(i <- 1..n//1, do: line(i))
      }
    }
  end

  defp names do
    %{
      offsets: %{issued_at: 18_000, cut_off_at: 18_000, order_issued_at: 0},
      employees: %{
        @chair => %{full_name: "Chair Person", code: "E1"},
        @member => %{full_name: "Member One", code: "E2"},
        @resp => %{full_name: "Resp One", code: "E3"}
      },
      positions: %{@chair => "Head"},
      card_currency: %{}
    }
  end

  test "P1: every label has a non-empty en, ru and kk text" do
    for {key, texts} <- CountSheetPrint.labels(), lang <- [:en, :ru, :kk] do
      assert is_binary(texts[lang]) and texts[lang] != "", "#{key} #{lang}"
    end
  end

  test "P2: tables split at 1000 rows; builds in every language; signer rows in order" do
    {layout, projection} = CountSheetPrint.layout(issued(1001), names(), :en)
    assert length(projection["lines_0"]) == 1000
    assert length(projection["lines_1"]) == 1

    tables = for %{"type" => "table", "entity_type" => e} <- layout["blocks"], do: e
    assert tables == ["lines_0", "lines_1", "signers"]

    assert [chair, member, resp] = projection["signers"]
    assert chair["role"] == "Commission chair" and chair["full_name"] == "Chair Person"
    assert chair["position"] == "Head"
    assert member["role"] == "Commission member" and resp["role"] == "Material responsible"

    for r <- [chair, member, resp], do: assert(r["signature"] == "" and r["date"] == "")

    for lang <- [:ru, :kk, :en] do
      assert {:ok, <<"%PDF", _::binary>>} = CountSheetPrint.build(issued(3), names(), lang)
    end

    assert {:ok, <<"%PDF", _::binary>>} = CountSheetPrint.build(issued(0), names(), :ru)
  end
end
