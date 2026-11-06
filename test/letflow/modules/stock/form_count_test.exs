defmodule Letflow.Modules.Stock.FormCountTest do
  @moduledoc """
  T-1418 (E5d), design tests M1..M5: the pure data mappers of the official count forms Inv-18 and
  Inv-10 (no database).
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Stock.FormCountInv10
  alias Letflow.Modules.Stock.FormCountInv18

  @e1 "11111111-1111-1111-1111-111111111111"
  @e2 "22222222-2222-2222-2222-222222222222"
  @e3 "33333333-3333-3333-3333-333333333333"
  @hidden "99999999-9999-9999-9999-999999999999"
  @unit "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

  defp names(extra \\ %{}) do
    Map.merge(
      %{
        timezone: "Asia/Almaty",
        offsets: %{issued_at: 18_000, cut_off_at: 18_000, order_issued_at: 18_000},
        legal_entities: %{@unit => %{name: "ТОО Ромашка", bin: "123456789012"}},
        order: %{number_label: "CO-2026-0001", issued_at: "2026-11-01T20:00:00Z"},
        employees: %{
          @e1 => %{full_name: "Иванов И.", code: "E1"},
          @e2 => %{full_name: "Петров П.", code: "E2"},
          @e3 => %{full_name: "Сидоров С.", code: "E3"},
          @hidden => nil
        },
        positions: %{@e1 => "Кладовщик", @e2 => "Бухгалтер", @e3 => "Директор"},
        items: %{
          "i1" => %{name: "Болт", code: "B-1"},
          "i2" => %{name: "Гайка", code: "G-2"}
        },
        units: %{"u1" => %{code: "PCS", name: "шт"}}
      },
      extra
    )
  end

  defp line(n, extra) do
    Map.merge(
      %{
        "line_no" => n,
        "catalog_item_id" => "i#{n}",
        "unit_ref" => "u1",
        "responsible_employee_id" => @e1
      },
      extra
    )
  end

  defp diff_issued(lines, order_extra \\ %{}) do
    %{
      number_label: "CD-2026-0001",
      issued_at: "2026-11-05T20:30:00Z",
      content: %{
        "org_unit_id" => @unit,
        "cut_off_at" => "2026-11-04T10:00:00Z",
        "lines" => lines
      },
      order_content: Map.merge(%{"org_unit_id" => @unit}, order_extra)
    }
  end

  describe "M1 Inv-18 rows" do
    test "a surplus fills the surplus quantity, a shortage the absolute shortage, sums stay absent" do
      lines = [
        line(1, %{"difference" => "2.500000000", "direction" => "surplus"}),
        line(2, %{"difference" => "-3.000000000", "direction" => "shortage"}),
        line(3, %{"difference" => "0.000000000", "direction" => "surplus"}),
        line(4, %{"difference" => "oops", "direction" => "shortage"}),
        line(5, %{"difference" => "1", "direction" => "other"})
      ]

      %{"lines" => [r1, r2, r3, r4, r5]} = FormCountInv18.data(diff_issued(lines), names())

      assert %{"no" => "1", "name" => "Болт", "nom" => "B-1", "unit" => "шт"} = r1
      assert {r1["surplus_qty"], r1["shortage_qty"]} == {"2.500000000", ""}
      assert {r2["surplus_qty"], r2["shortage_qty"]} == {"", "3.000000000"}
      assert {r3["surplus_qty"], r3["shortage_qty"]} == {"", ""}
      assert {r4["surplus_qty"], r4["shortage_qty"]} == {"", ""}
      assert {r5["surplus_qty"], r5["shortage_qty"]} == {"", ""}

      for k <- ~w(surplus_sum shortage_sum adj_surplus_acct adj_shortage_qty),
          do: refute(Map.has_key?(r1, k))
    end
  end

  describe "M2 Inv-18 totals" do
    test "the engine sums the two quantity columns of mixed lines; no lines gives a blank total" do
      alias Letflow.Documents.FormPrint
      {:ok, layout} = FormPrint.layout("inv18")

      total = fn lines ->
        data = FormCountInv18.data(diff_issued(lines), names())
        model = FormPrint.resolve(layout, data, "ru", FormPrint.catalog())
        {:table, %{total: t}} = Enum.find(model, &match?({:table, %{total: %{}}}, &1))
        t
      end

      lines = [
        line(1, %{"difference" => "2", "direction" => "surplus"}),
        line(2, %{"difference" => "-3", "direction" => "shortage"}),
        line(1, %{"difference" => "1.5", "direction" => "surplus"})
      ]

      t = total.(lines)
      assert t["surplus_qty"] == "3.5" and t["shortage_qty"] == "3"
      assert t["name"] == "Итого"
      assert total.([])["surplus_qty"] == ""
    end
  end

  describe "M3 Inv-18 header" do
    test "organisation, numbers, dates in the tenant zone, responsible persons joined" do
      lines = [
        line(1, %{"difference" => "2", "direction" => "surplus"}),
        line(2, %{
          "difference" => "1",
          "direction" => "shortage",
          "responsible_employee_id" => @e2
        }),
        line(3, %{
          "difference" => "1",
          "direction" => "shortage",
          "responsible_employee_id" => @hidden
        })
      ]

      d = FormCountInv18.data(diff_issued(lines), names())

      assert d["org_name"] == "ТОО Ромашка" and d["org_bin"] == "123456789012"
      assert d["number"] == "CD-2026-0001"
      # 2026-11-05T20:30Z + 5h is 06.11 in Almaty
      assert d["date"] == "06.11.2026"
      assert d["count_date"] == "04.11.2026"
      assert d["order"] == "02.11.2026 № CO-2026-0001"
      assert d["responsible"] == "Иванов И.; Петров П."
      assert d["responsible_position"] == "Кладовщик; Бухгалтер"
      assert d["regrade"] == [%{}, %{}]
      refute Map.has_key?(d, "accountant")
      refute Enum.any?(Map.keys(d), &(&1 =~ "iin"))
    end

    test "a missing legal entity, order and a hidden employee give blanks, not invented values" do
      lines = [
        line(1, %{
          "difference" => "2",
          "direction" => "surplus",
          "responsible_employee_id" => @hidden
        })
      ]

      d = FormCountInv18.data(diff_issued(lines), names(%{legal_entities: %{}, order: nil}))
      assert d["org_name"] == "" and d["org_bin"] == ""
      assert d["order"] == ""
      assert d["responsible"] == "" and d["responsible_position"] == ""
    end
  end

  defp sheet_issued(lines, order_extra) do
    %{
      number_label: "CS-2026-0001",
      issued_at: "2026-11-05T09:00:00Z",
      content: %{"org_unit_id" => @unit, "cut_off_at" => "2026-11-04T10:00:00Z", "lines" => lines},
      order_content: Map.merge(%{"org_unit_id" => @unit}, order_extra)
    }
  end

  describe "M4 Inv-10 rows and header" do
    test "counted and book quantity, price/sum/account blank, row and quantity totals" do
      lines = [
        line(1, %{"book_quantity" => "10.000000000", "counted_quantity" => "8.000000000"}),
        line(2, %{"book_quantity" => "4.000000000", "counted_quantity" => "4.500000000"})
      ]

      d = FormCountInv10.data(sheet_issued(lines, %{}), names())

      assert d["number"] == "CS-2026-0001" and d["date"] == "05.11.2026"
      assert d["order_no"] == "CO-2026-0001" and d["order_date"] == "02.11.2026"
      assert d["cut_off"] == "04.11.2026"
      assert [r1, r2] = d["lines"]
      assert r1["qty_fact"] == "8.000000000" and r1["qty_book"] == "10.000000000"
      assert r2["name"] == "Гайка" and r2["unit"] == "шт"
      for k <- ~w(price sum_fact sum_book acct), do: refute(Map.has_key?(r1, k))
      assert d["total_nos"] == "2" and d["total_qty"] == "12.500000000"
      for k <- ~w(stock_kind account started ended total_sum), do: refute(Map.has_key?(d, k))
    end

    test "an uncounted line blanks the quantity total; no lines gives blank totals" do
      lines = [line(1, %{"book_quantity" => "1", "counted_quantity" => nil})]
      d = FormCountInv10.data(sheet_issued(lines, %{}), names())
      assert d["total_nos"] == "1" and d["total_qty"] == ""
      empty = FormCountInv10.data(sheet_issued([], %{}), names())
      assert empty["lines"] == [] and empty["total_nos"] == "" and empty["total_qty"] == ""
    end
  end

  describe "M5 Inv-10 persons" do
    test "chair, members and responsible persons; the third and later are joined" do
      lines = [
        line(1, %{"book_quantity" => "1", "counted_quantity" => "1"}),
        line(2, %{
          "book_quantity" => "1",
          "counted_quantity" => "1",
          "responsible_employee_id" => @e2
        }),
        line(3, %{
          "book_quantity" => "1",
          "counted_quantity" => "1",
          "responsible_employee_id" => @e3
        }),
        line(4, %{
          "book_quantity" => "1",
          "counted_quantity" => "1",
          "responsible_employee_id" => @hidden
        })
      ]

      order = %{"chair_employee_id" => @e3, "member_employee_ids" => [@e1, @e2, @hidden]}
      d = FormCountInv10.data(sheet_issued(lines, order), names())

      assert {d["resp1"], d["resp1_position"]} == {"Иванов И.", "Кладовщик"}
      assert {d["resp2"], d["resp2_position"]} == {"Петров П.; Сидоров С.", "Бухгалтер; Директор"}
      assert {d["chair"], d["chair_position"]} == {"Сидоров С.", "Директор"}
      assert {d["member1"], d["member1_position"]} == {"Иванов И.", "Кладовщик"}
      assert {d["member2"], d["member2_position"]} == {"Петров П.", "Бухгалтер"}
    end

    test "no order persons leave the signature lines blank" do
      d = FormCountInv10.data(sheet_issued([], %{}), names())
      assert {d["chair"], d["chair_position"], d["member1"], d["resp1"]} == {"", "", "", ""}
    end
  end
end
