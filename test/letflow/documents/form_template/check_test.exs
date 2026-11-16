defmodule Letflow.Documents.FormTemplate.CheckTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.FormTemplate, as: F
  alias Letflow.FormTemplateDocx, as: D

  defp errors(pkg) do
    case F.check("z2", D.zip(pkg)) do
      {:error, e} -> e
      other -> flunk(inspect(other))
    end
  end

  defp has(pkg, code, rule, name \\ :any) do
    result = errors(pkg)

    assert Enum.any?(
             result,
             &(&1.code == code and &1.rule == rule and (name == :any or &1.name == name))
           ),
           inspect(result)

    refute inspect(result) =~ "private_marker"
    result
  end

  test "S1-malformed names and interrupted placeholders" do
    for xml <- [
          D.run("{{ legal.title }}"),
          D.run("{{Legal.Title}}"),
          D.run("}}"),
          D.run("{{" <> String.duplicate("a", 65) <> "}}"),
          "<w:r><w:t>{{legal.</w:t><w:tab/><w:t>title}}</w:t></w:r>"
        ] do
      assert [%{place: %{paragraph: _}}] =
               has(D.body(D.valid(), "<w:p>#{xml}</w:p>"), :malformed_placeholder, "D4")
    end
  end

  test "S1-not-plain placeholders including brace splits in textbox, hyperlink, header" do
    for runs <- [D.run("{{legal.title}}"), D.run("{") <> D.run("{legal.title}}")],
        {part, xml} <- [
          {"word/document.xml", "<w:p><w:hyperlink>#{runs}</w:hyperlink></w:p>"},
          {"word/document.xml",
           "<w:p><w:r><w:txbxContent><w:p>#{runs}</w:p></w:txbxContent></w:r></w:p>"},
          {"word/header1.xml", "<w:hdr #{D.namespaces()}><w:p>#{runs}</w:p></w:hdr>"}
        ] do
      pkg =
        if part == "word/document.xml",
          do: D.body(D.valid(), xml),
          else: Map.put(D.valid(), part, xml)

      has(pkg, :placeholder_not_plain, "D4")
    end

    assert {:ok, _} =
             F.check(
               "z2",
               D.valid()
               |> D.replace(
                 D.p("legal.title"),
                 "<w:sdt><w:sdtContent>#{D.p("legal.title")}</w:sdtContent></w:sdt>"
               )
               |> D.zip()
             )
  end

  test "S1-unknown-name never echoes company names" do
    result =
      has(D.body(D.valid(), D.p("lines.salary_private_marker")), :unknown_name, "D3.3", nil)

    refute inspect(result) =~ "salary"
  end

  test "S1-missing-legal, S1-missing-data, S1-duplicate-legal and S1-signature" do
    for {name, code, rule} <- [
          {"legal.title", :missing_legal, "D3.1"},
          {"org_bin", :missing_data, "D3.2"},
          {"legal.col.1.5", :missing_legal, "D3.1"},
          {"sig.allowed_by.position", :missing_data, "D3.5"},
          {"legal.stamp.chief_acc", :missing_legal, "D3.5"},
          {"legal.cap.released.signature", :missing_legal, "D3.5"}
        ] do
      has(D.remove(D.valid(), name), code, rule, name)
    end

    for {name, rule} <- [{"legal.title", "D3.1"}, {"legal.cap.released.signature", "D3.5"}] do
      has(D.body(D.valid(), D.p(name)), :duplicate_legal, rule, name)
    end

    has(
      D.body(D.valid(), D.p("tenant.logo") <> D.p("tenant.logo")),
      :duplicate_legal,
      "D3.1",
      "tenant.logo"
    )
  end

  test "S1-column-order headers, repeat cells, group start and late heading" do
    for {a, b} <- [{"legal.col.1.4", "legal.col.1.5"}, {"lines.unit", "lines.qty_plan"}] do
      pkg =
        D.valid()
        |> D.replace("{{#{a}}}", "SWAP")
        |> D.replace("{{#{b}}}", "{{#{a}}}")
        |> D.replace("SWAP", "{{#{b}}}")

      has(pkg, :column_order, "D3.4")
    end

    has(
      D.valid()
      |> D.replace("{{legal.group.1.1}}", "SWAP")
      |> D.replace("{{legal.col.1.1}}", "{{legal.group.1.1}}")
      |> D.replace("SWAP", "{{legal.col.1.1}}"),
      :column_order,
      "D3.4"
    )

    late =
      D.valid()
      |> D.remove("legal.col.1.5")
      |> D.replace("{{legal.total.1}}", "{{legal.total.1}}{{legal.col.1.5}}")

    has(late, :column_order, "D3.4", "legal.col.1.5")
  end

  test "S1-column-order repeat row spread, extra field, outside table and early total" do
    has(D.valid() |> D.remove("lines.unit") |> D.body(D.p("lines.unit")), :repeat_row, "D3.4")
    pkg = D.valid() |> D.replace(D.cell("lines.unit"), D.cell("lines.unit") <> "</w:tr><w:tr>")
    has(pkg, :repeat_row, "D3.4")
    has(D.replace(D.valid(), "{{lines.unit}}", "{{lines.unit}}{{org_bin}}"), :repeat_row, "D3.4")

    has(
      D.valid()
      |> D.remove("legal.total.1")
      |> D.replace("{{legal.col.1.1}}", "{{legal.col.1.1}}{{legal.total.1}}"),
      :total_place,
      "D3.4",
      "legal.total.1"
    )
  end

  test "S1-collect sorted independent faults and refusal cap" do
    result =
      D.valid()
      |> D.remove("legal.title")
      |> D.remove("org_bin")
      |> D.body(D.p("private_marker"))
      |> errors()

    assert length(result) == 3
    assert result == Enum.sort_by(result, &{&1.rule, &1.place, &1.name})
    result = D.body(D.valid(), Enum.map_join(1..150, &D.p("private_marker#{&1}"))) |> errors()
    assert length(result) == 100
    assert Enum.all?(result, &(&1.code == :unknown_name and &1.name == nil))
    refute inspect(result) =~ "private_marker"
  end

  test "CK-T1 total values are required" do
    has(D.remove(D.valid(), "total.1.qty_issued"), :missing_data, "D3.2", "total.1.qty_issued")
  end

  test "CK-T2 total values cannot move into the repeat row" do
    D.valid()
    |> D.remove("total.1.qty_issued")
    |> D.replace("{{lines.qty_issued}}", "{{lines.qty_issued}}{{total.1.qty_issued}}")
    |> has(:total_place, "D3.4", "total.1.qty_issued")
  end

  test "CK-T3 total values retain their column positions" do
    D.valid()
    |> D.replace("{{total.1.qty_issued}}", "SWAP")
    |> D.replace("{{total.1.price}}", "{{total.1.qty_issued}}")
    |> D.replace("SWAP", "{{total.1.price}}")
    |> has(:total_place, "D3.4", "total.1.qty_issued")
  end

  @tag timeout: 10_000
  test "large paragraphs and many paragraphs still cap unknown-name refusals" do
    for xml <- [
          "<w:p>" <> Enum.map_join(1..10_000, &D.run("{{private_marker#{&1}}}")) <> "</w:p>",
          Enum.map_join(1..10_000, &D.p("private_marker#{&1}"))
        ] do
      result = D.body(D.valid(), xml) |> errors()
      assert length(result) == 100
      assert Enum.all?(result, &(&1.code == :unknown_name and &1.name == nil))
      refute inspect(result) =~ "private_marker"
    end
  end
end
