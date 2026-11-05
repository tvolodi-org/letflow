Code.require_file("../modules/stock/count_print_probe.exs", __DIR__)

defmodule Letflow.Documents.FormPrintTest do
  @moduledoc """
  T-1416 (E5b), design tests K1..K8: the form print engine, pure (no database).
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.FormPrint
  alias Letflow.Modules.Stock.CountPrintTest.PdfProbe

  @ru_title "Накладная на отпуск запасов на сторону"
  @kk_title "ҚОРЛАРДЫ ШЕТКЕ БЕРУГЕ АРНАЛҒАН ЖҮКҚҰЖАТ"

  defp data(extra \\ %{}) do
    Map.merge(
      %{
        "org_name" => "ТОО Ромашка",
        "sender" => "ТОО Ромашка",
        "org_bin" => "123456789012",
        "number" => "DOC-7",
        "date" => "05.11.2026",
        "responsible" => "Иванов И.",
        "released" => "Иванов И.",
        "lines" => [
          %{"no" => "1", "name" => "Болт", "nom" => "B-1", "unit" => "шт", "qty_issued" => "1.5"},
          %{"no" => "2", "name" => "Гайка", "nom" => "G-2", "unit" => "шт", "qty_issued" => "2"}
        ]
      },
      extra
    )
  end

  defp docx_text(bin) do
    {:ok, files} = :zip.unzip(bin, [:memory])
    {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
    xml |> String.replace("</w:p>", "\n") |> String.replace(~r/<[^>]+>/, "")
  end

  defp unescape(t),
    do:
      t
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
      |> String.replace("&amp;", "&")

  describe "K1 layout loader" do
    test "accepts z2.json" do
      {:ok, layout} = FormPrint.layout("z2")
      assert FormPrint.validate_layout(layout, FormPrint.catalog()) == :ok
      assert "z2" in FormPrint.forms()
    end

    test "rejects an unknown block type, an unknown key and a missing catalog key" do
      {:ok, layout} = FormPrint.layout("z2")
      cat = FormPrint.catalog()
      put = fn blocks -> %{layout | "blocks" => blocks} end

      assert {:error, {:unknown_block_type, _}} =
               FormPrint.validate_layout(put.([%{"type" => "image", "label" => "z2.title"}]), cat)

      assert {:error, {:unknown_key, _}} =
               FormPrint.validate_layout(
                 put.([%{"type" => "text", "label" => "z2.title", "script" => "x"}]),
                 cat
               )

      assert {:error, {:missing_catalog_key, ["blocks", 0]}} =
               FormPrint.validate_layout(put.([%{"type" => "text", "label" => "nope"}]), cat)

      assert {:error, {:bad_version, []}} =
               FormPrint.validate_layout(%{layout | "form_layout_version" => 2}, cat)
    end
  end

  describe "K2 catalog" do
    test "every key used by z2 has ru and kk text and kk is official" do
      {:ok, layout} = FormPrint.layout("z2")
      cat = FormPrint.catalog()

      keys =
        for b <- layout["blocks"],
            k <-
              [b["label"], b["stamp"]] ++
                Enum.flat_map(b["columns"] || [], &[&1["label"], &1["group"]]) ++
                [get_in(b, ["totals", "label"])],
            k != nil,
            do: k

      assert keys != []

      for k <- keys do
        assert %{"ru" => ru, "kk" => kk, "kk_status" => "official"} = cat[k], k
        assert ru != "" and kk != ""
      end
    end
  end

  describe "K3 PDF" do
    test "ru and kk are non-empty PDFs with the title and a table header of the language" do
      for {lang, title, header} <- [
            {"ru", @ru_title, "Номенклатурный номер"},
            {"kk", @kk_title, "Номенклатуралық нөмірі"}
          ] do
        assert {:ok, pdf} = FormPrint.build("z2", data(), lang, :pdf)
        assert byte_size(pdf) > 1000
        assert String.starts_with?(pdf, "%PDF")
        items = PdfProbe.items(pdf)
        assert title in items
        assert Enum.any?(items, &String.contains?(&1, header))
        assert "Болт" in items
        assert "3.5" in items
      end
    end

    test "a language other than ru and kk, and an unknown form, are refused" do
      assert {:error, :lang_not_supported} = FormPrint.build("z2", data(), "en", :pdf)
      assert {:error, :unknown_form} = FormPrint.build("z9", data(), "ru", :docx)
    end
  end

  describe "K4 machine-draft notice" do
    test "a kk draft label adds the notice in kk, not in ru" do
      cat = put_in(FormPrint.catalog(), ["z2.title", "kk_status"], "machine_draft")
      {:ok, layout} = FormPrint.layout("z2")

      kk = FormPrint.resolve(layout, data(), "kk", cat)
      ru = FormPrint.resolve(layout, data(), "ru", cat)
      assert {:notice, "Машиналық аударма, тексеруді қажет етеді"} = List.last(kk)
      refute Enum.any?(ru, &match?({:notice, _}, &1))

      official = FormPrint.resolve(layout, data(), "kk", FormPrint.catalog())
      refute Enum.any?(official, &match?({:notice, _}, &1))

      {:ok, docx} = FormPrint.build("z2", data(), "kk", :docx, catalog: cat)
      assert docx_text(docx) =~ "Машиналық аударма"
    end
  end

  describe "K5 docx" do
    test "valid package; ru text" do
      assert {:ok, bin} = FormPrint.build("z2", data(), "ru", :docx)
      assert {:ok, files} = :zip.unzip(bin, [:memory])
      names = Enum.map(files, fn {n, _} -> to_string(n) end)
      assert "word/document.xml" in names and "[Content_Types].xml" in names
      assert "_rels/.rels" in names and "word/styles.xml" in names
      text = docx_text(bin)

      for t <- [
            @ru_title,
            "Форма З-2",
            "Приложение 26 к приказу",
            "Номер по порядку",
            "Наименование, характеристика",
            "Номенклатурный номер",
            "Единица измерения",
            "подлежит отпуску",
            "отпущено",
            "Цена за единицу, в теңге",
            "Сумма с НДС, в теңге",
            "Сумма НДС, в теңге",
            "Количество",
            "Итого",
            "ТОО Ромашка",
            "123456789012",
            "05.11.2026",
            "Болт",
            "Гайка",
            "3.5"
          ] do
        assert text =~ t, "missing #{t}"
      end
    end

    test "valid package; kk text with the official wording" do
      assert {:ok, bin} = FormPrint.build("z2", data(), "kk", :docx)
      text = docx_text(bin)

      for t <- [
            @kk_title,
            "Қ-2 нысаны",
            "Алушы ұйым (жеке кәсіпкер)",
            "Номенклатуралық нөмірі",
            "Жиыны",
            "Саны",
            "беруге жатады",
            "26-қосымша"
          ] do
        assert text =~ t, "missing #{t}"
      end

      refute text =~ "Машиналық аударма"
    end

    test "the merged group header and the numbers row are in the XML" do
      {:ok, bin} = FormPrint.build("z2", data(), "ru", :docx)
      {:ok, files} = :zip.unzip(bin, [:memory])
      {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
      assert xml =~ ~s(<w:gridSpan w:val="2"/>)
      assert xml =~ ~s(<w:vMerge w:val="restart"/>)
      assert xml =~ "<w:vMerge/>"
    end
  end

  describe "K6 blanks" do
    test "values Letflow does not hold print as blank lines, nothing is invented" do
      {:ok, layout} = FormPrint.layout("z2")
      model = FormPrint.resolve(layout, data(), "ru", FormPrint.catalog())

      for label <- [
            "Организация (индивидуальный предприниматель) - получатель",
            "Транспортная организация",
            "Товарно-транспортная накладная (номер, дата)"
          ] do
        assert {:field, ^label, ""} = List.keyfind(model, label, 1)
      end

      {:ok, docx} = FormPrint.build("z2", data(), "ru", :docx)
      {:ok, pdf} = FormPrint.build("z2", data(), "ru", :pdf)
      assert docx_text(docx) =~ "Транспортная организация: ____________"
      items = PdfProbe.items(pdf)
      assert "Транспортная организация: ____________" in items
      assert "Запасы получил: ____________ / ____________" in items

      assert {:signature, "Запасы получил", ["", ""], _, nil} = List.last(model)
      assert docx_text(docx) =~ "Запасы получил ____________ / ____________"
    end

    test "the total is the sum of the stored texts; an invalid text blanks it; no rows blanks it" do
      {:ok, layout} = FormPrint.layout("z2")

      total = fn d ->
        model = FormPrint.resolve(layout, d, "ru", FormPrint.catalog())
        {:table, t} = List.keyfind(model, :table, 0)
        t.total
      end

      assert %{"qty_issued" => "3.5", "qty_plan" => "x", "price" => "x", "name" => "Итого"} =
               total.(data())

      bad = data(%{"lines" => [%{"qty_issued" => "1"}, %{"qty_issued" => "abc"}]})
      assert total.(bad)["qty_issued"] == ""
      assert total.(data(%{"lines" => []}))["qty_issued"] == ""
    end
  end

  describe "K7 hostile values" do
    test "markup, control characters and a 600-char name never crash either path" do
      hostile = "<w:t>&\"'" <> <<1>> <> String.duplicate("Я", 600)

      d =
        data(%{
          "org_name" => hostile,
          "lines" => [%{"no" => "1", "name" => hostile, "qty_issued" => "1"}]
        })

      assert {:ok, bin} = FormPrint.build("z2", d, "ru", :docx)
      {:ok, files} = :zip.unzip(bin, [:memory])
      {_, xml} = Enum.find(files, fn {n, _} -> n == ~c"word/document.xml" end)
      assert {_doc, _rest} = :xmerl_scan.string(:erlang.binary_to_list(xml), quiet: true)
      assert unescape(docx_text(bin)) =~ "<w:t>&\"'"
      refute xml =~ <<1>>

      assert {:ok, pdf} = FormPrint.build("z2", d, "kk", :pdf)
      assert String.starts_with?(pdf, "%PDF")
      assert {:ok, _} = FormPrint.build("z2", d, "kk", :docx)
    end

    test "clean/1 caps, strips and normalises" do
      assert FormPrint.clean(nil) == ""
      assert FormPrint.clean(12) == "12"
      assert FormPrint.clean("a\r\nb\tc") == "a b c"
      assert FormPrint.clean("a" <> <<0, 1, 11, 12>> <> "b") == "ab"
      assert String.length(FormPrint.clean(String.duplicate("x", 900))) == 500
      assert FormPrint.clean(<<255, 254>>) == ""
      assert FormPrint.clean(%{}) == ""
    end
  end

  describe "K8 determinism" do
    test "equal inputs give equal docx bytes" do
      assert {:ok, a} = FormPrint.build("z2", data(), "ru", :docx)
      assert {:ok, b} = FormPrint.build("z2", data(), "ru", :docx)
      assert a == b
    end
  end
end
