defmodule Letflow.Modules.Assets.DocumentPrintTest do
  @moduledoc """
  T-1915 (design tests U1..U4): the pure builder of the asset document act. No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Assets.DocumentPrint

  @unit "u1"
  @emp1 "e1"
  @emp2 "e2"

  defp names do
    %{
      offsets: %{issued_at: 18_000, event_time: 0},
      org_units: %{@unit => %{code: "U1", name: "Warehouse"}},
      locations: %{"l1" => %{code: "L1", name: "Room"}},
      employees: %{
        @emp1 => %{full_name: "Ann One", code: "T1"},
        @emp2 => %{full_name: "Bob Two", code: "T2"}
      },
      cards: %{"a1" => %{inventory_number: "INV-1", name: "Laptop"}}
    }
  end

  defp issued(kind, header) do
    %{
      number_label: "AXX-1",
      version_no: 1,
      issued_at: "2026-11-04T05:00:00Z",
      content: %{
        "kind" => kind,
        "header" => header,
        "lines" => [%{"line_no" => 1, "asset_id" => "a1", "quantity" => "1234.500000000"}]
      }
    }
  end

  defp header(extra \\ %{}) do
    Map.merge(
      %{
        "org_unit_id" => @unit,
        "location_id" => "l1",
        "material_responsible_id" => @emp1,
        "actual_user_id" => @emp2,
        "from_material_responsible_id" => @emp1,
        "from_actual_user_id" => @emp2,
        "to_material_responsible_id" => @emp2,
        "to_actual_user_id" => @emp1,
        "event_time" => "2026-11-04T05:00:00Z"
      },
      extra
    )
  end

  test "U1 every label has en, ru and kk; the kinds are the four acts" do
    assert DocumentPrint.kinds() == ~w(commission change handover writeoff)

    for {key, texts} <- DocumentPrint.labels(), lang <- [:en, :ru, :kk] do
      assert is_binary(texts[lang]) and texts[lang] != "", "#{key} #{lang}"
    end
  end

  describe "U2 layout per kind" do
    test "one side column for commission and write-off, from and to for the others" do
      for {kind, cols} <- [
            {"commission", ~w(what side)},
            {"writeoff", ~w(what side)},
            {"change", ~w(what from to)},
            {"handover", ~w(what from to)}
          ] do
        {layout, projection} = DocumentPrint.layout(issued(kind, header()), names(), :en)
        sides = Enum.find(layout["blocks"], &(&1["entity_type"] == "sides"))
        assert Enum.map(sides["columns"], & &1["field_name"]) == cols
        assert [%{"what" => "Org unit"} | _] = projection["sides"]
        assert length(projection["sides"]) == 4
      end
    end

    test "signer rows by kind" do
      roles = fn kind ->
        {_, p} = DocumentPrint.layout(issued(kind, header()), names(), :en)
        Enum.map(p["signers"], &{&1["role"], &1["full_name"]})
      end

      assert roles.("commission") == [{"Received by", "Ann One"}, {"Commissioned by", ""}]
      assert roles.("writeoff") == [{"Material responsible", "Ann One"}]
      assert roles.("change") == [{"Handed over by", "Ann One"}, {"Received by", "Bob Two"}]
      assert roles.("handover") == [{"Handed over by", "Ann One"}, {"Received by", "Bob Two"}]
    end

    test "write-off reason prints its label, an unknown code and other kinds print empty" do
      doc = fn kind, code ->
        {_, p} =
          DocumentPrint.layout(issued(kind, header(%{"reason_code" => code})), names(), :ru)

        p["doc"]["reason"]
      end

      assert doc.("writeoff", "broken") == "Сломан"
      assert doc.("writeoff", "nonsense") == ""
      assert doc.("commission", "broken") == ""
    end
  end

  test "U3 numbers and times are formatted for the language" do
    {_, ru} = DocumentPrint.layout(issued("commission", header()), names(), :ru)
    {_, en} = DocumentPrint.layout(issued("commission", header()), names(), :en)
    assert hd(ru["lines"])["quantity"] == "1 234,5"
    assert hd(en["lines"])["quantity"] == "1,234.5"
    assert DocumentPrint.number("1.000000000", :en) == "1"
    assert ru["doc"]["issued_at"] == "04-11-2026 10:00 (UTC+05:00)"
    assert en["doc"]["issued_at"] == "2026-11-04 10:00 (UTC+05:00)"
    assert en["doc"]["event_time"] == "2026-11-04 05:00 (UTC+00:00)"
    assert hd(en["lines"])["inventory_number"] == "INV-1"
  end

  test "U4 a kind outside the four and a language outside the three are refused" do
    assert_raise FunctionClauseError, fn ->
      DocumentPrint.build(issued("opening", header()), names(), :en)
    end

    unsupported = Enum.at([:de], 0)

    assert_raise FunctionClauseError, fn ->
      DocumentPrint.build(issued("commission", header()), names(), unsupported)
    end

    assert {:ok, "%PDF-" <> _} = DocumentPrint.build(issued("change", header()), names(), :kk)
  end
end
