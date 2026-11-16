defmodule Letflow.Documents.FormTemplate.StarterTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.{FormPrint, FormTemplate}
  alias FormTemplate.{Keys, Xml}
  alias Letflow.FormTemplateDocx, as: D

  defp tree(bytes) do
    {:ok, tree} = bytes |> D.unpack() |> Map.fetch!("word/document.xml") |> Xml.parse()
    tree
  end

  test "ST1 every starter is a canonical valid upload" do
    for form <- FormPrint.forms() do
      assert {:ok, bytes} = FormTemplate.starter(form), form
      assert {:ok, checked} = FormTemplate.check(form, bytes), form
      assert checked.bytes == bytes
      {:ok, k} = Keys.for_form(form)
      assert checked.summary.placeholders == %{legal: length(k.legal), data: length(k.data)}
    end

    assert {:error, [%{code: :unknown_form}]} = FormTemplate.starter("unknown")
  end

  test "ST2 page structure and weighted grids match the platform layout" do
    for form <- FormPrint.forms() do
      {:ok, starter} = FormTemplate.starter(form)
      {:ok, platform} = FormPrint.build(form, %{}, "ru", :docx)
      a = tree(starter)
      b = tree(platform)

      for name <- ~w(w:pgSz w:pgMar) do
        assert Xml.named(a, name) == Xml.named(b, name), form
      end

      at = Xml.named(a, "w:tbl")
      bt = Xml.named(b, "w:tbl")
      assert length(at) == length(bt), form

      for {x, y} <- Enum.zip(at, bt) do
        assert length(Xml.named(x, "w:gridCol")) == length(Xml.named(y, "w:gridCol"))

        if form != "inv8",
          do: assert(Xml.named(x, "w:gridCol") == Xml.named(y, "w:gridCol"), form)
      end
    end
  end

  test "ST3 starters contain legal placeholders rather than catalog wording" do
    for form <- FormPrint.forms() do
      {:ok, starter} = FormTemplate.starter(form)
      xml = D.unpack(starter)["word/document.xml"]
      assert xml =~ "{{legal.title}}"
      {:ok, k} = Keys.for_form(form)
      texts = tree(starter) |> Xml.named("w:t") |> Enum.map(&Xml.text/1)

      for {_, {:catalog, key}} <- k.sources, lang <- ~w(ru kk) do
        refute FormPrint.catalog()[key][lang] in texts
      end
    end
  end

  test "ST4 da2 span heading remains one four-column cell" do
    {:ok, starter} = FormTemplate.starter("da2")

    cells =
      tree(starter)
      |> Xml.named("w:tc")
      |> Enum.filter(fn c ->
        c |> Xml.named("w:t") |> Enum.any?(&(Xml.text(&1) == "{{legal.col.6.3}}"))
      end)

    assert [cell] = cells
    assert [span] = Xml.named(cell, "w:gridSpan")
    assert Xml.attr(span, "w:val") == "4"
  end
end
