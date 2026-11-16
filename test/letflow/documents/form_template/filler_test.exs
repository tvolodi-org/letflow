defmodule Letflow.Documents.FormTemplate.FillerTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.{FormPrint, FormTemplate}
  alias FormTemplate.{Keys, Xml}
  alias Letflow.FormTemplateDocx, as: D

  defmodule Infected do
    def scan(_, _), do: {:ok, :infected, "private"}
  end

  defp tree(bytes) do
    {:ok, t} = bytes |> D.unpack() |> Map.fetch!("word/document.xml") |> Xml.parse()
    t
  end

  defp texts(t), do: t |> Xml.named("w:t") |> Enum.map_join(&Xml.text/1)
  defp paragraphs(bytes), do: bytes |> tree() |> Xml.named("w:p") |> Enum.map(&texts/1)

  defp sample(form) do
    {:ok, keys} = Keys.for_form(form)
    fields = Map.new(keys.data, &{&1, "v_" <> &1})

    fields =
      Enum.reduce(keys.signatures, fields, fn b, acc ->
        acc |> Map.put(b["key"], "person") |> Map.put(b["key"] <> "_position", "position")
      end)

    {:ok, layout} = FormPrint.layout(form)

    for b <- layout["blocks"], b["type"] == "table", reduce: fields do
      acc ->
        rows =
          for n <- 1..2 do
            Map.new(b["columns"], fn c ->
              {c["key"],
               if(c["key"] in ((b["totals"] || %{})["sum"] || []),
                 do: "1.500000000",
                 else: "#{n}_#{c["key"]}"
               )}
            end)
          end

        Map.put(acc, b["rows"], rows)
    end
  end

  @tag timeout: 60_000
  test "FL1 filled starters have the platform paragraph texts for every form and language" do
    for form <- FormPrint.forms(), lang <- ~w(ru kk), data <- [sample(form), %{}] do
      assert {:ok, starter} = FormTemplate.starter(form), form
      assert {:ok, filled} = FormTemplate.fill(form, starter, data, lang), form
      assert {:ok, platform} = FormPrint.build(form, data, lang, :docx)
      assert paragraphs(filled) == paragraphs(platform), "#{form} #{lang} #{inspect(data)}"
    end
  end

  test "FL2 draft notice is appended outside company control, only in kk" do
    catalog = put_in(FormPrint.catalog(), ["z2.title", "kk_status"], "machine_draft")
    {:ok, starter} = FormTemplate.starter("z2")

    company =
      D.valid()
      |> D.edit(
        "word/document.xml",
        &String.replace(&1, "<w:sectPr>", "<w:p>#{D.run("Утверждаю")}</w:p><w:sectPr>")
      )
      |> D.zip()

    for template <- [starter, company] do
      {:ok, filled} = FormTemplate.fill("z2", template, %{}, "kk", catalog: catalog)
      body = filled |> tree() |> Xml.named("w:body") |> hd() |> elem(2)
      assert {"w:sectPr", _, _} = List.last(body)
      notice = Enum.at(body, -2)
      assert texts(notice) == catalog["draft_notice"]["kk"]
      assert [_] = Xml.named(notice, "w:i")
      {:ok, ru} = FormTemplate.fill("z2", template, %{}, "ru", catalog: catalog)
      refute catalog["draft_notice"]["kk"] in paragraphs(ru)
    end
  end

  test "FL3 values remain literal text with single escaping and no recursive substitution" do
    {:ok, starter} = FormTemplate.starter("z2")
    attack = "</w:t><w:fldSimple w:instr=\"INCLUDETEXT x\"/>"
    literal = "{{legal.title}} & \\1"

    {:ok, filled} =
      FormTemplate.fill("z2", starter, %{"org_name" => attack, "org_bin" => literal}, "ru")

    t = tree(filled)
    assert Xml.named(t, "w:fldSimple") == []
    values = t |> Xml.named("w:t") |> Enum.map(&Xml.text/1)
    assert attack in values
    assert literal in values
  end

  test "FL4 repeat rows expand zero, one and three times, including both da1 tables" do
    for form <- ~w(z2 da1), n <- [0, 1, 3] do
      {:ok, starter} = FormTemplate.starter(form)
      data = %{"lines" => List.duplicate(%{"name" => "ROW_MARKER", "inv" => "ROW_MARKER"}, n)}
      {:ok, filled} = FormTemplate.fill(form, starter, data, "ru")
      {:ok, layout} = FormPrint.layout(form)
      model = FormPrint.resolve(layout, data, "ru", FormPrint.catalog())
      # Include boxed/signature tables when aligning with the actual document grid.
      {:ok, platform} = FormPrint.build(form, data, "ru", :docx)
      a = tree(filled) |> Xml.named("w:tbl")
      b = tree(platform) |> Xml.named("w:tbl")

      assert Enum.map(a, &length(Xml.named(&1, "w:tr"))) ==
               Enum.map(b, &length(Xml.named(&1, "w:tr")))

      for {:table, t} <- model, do: assert(length(t.rows) == n)

      assert Enum.count(paragraphs(filled), &(&1 == "ROW_MARKER")) ==
               n * if(form == "da1", do: 2, else: 1)
    end
  end

  test "FL5 totals sum clean decimals, mark cells and blank invalid sums" do
    {:ok, starter} = FormTemplate.starter("z2")

    for {rows, expected} <- [
          {[%{"qty_issued" => "1.5"}, %{"qty_issued" => "2"}], "3.5"},
          {[%{"qty_issued" => "abc"}], ""}
        ] do
      {:ok, filled} = FormTemplate.fill("z2", starter, %{"lines" => rows}, "ru")

      total =
        filled |> tree() |> Xml.named("w:tbl") |> Enum.at(3) |> Xml.named("w:tr") |> List.last()

      cells = total |> Xml.children("w:tc") |> Enum.map(&texts/1)
      assert Enum.at(cells, 5) == expected
      for i <- [4, 6, 7, 8], do: assert(Enum.at(cells, i) == "x")
    end
  end

  test "FL6 invalid templates and scanner failures fail closed" do
    assert {:error, errors} =
             FormTemplate.fill("z2", D.valid() |> D.remove("org_name") |> D.zip(), %{}, "ru")

    assert Enum.any?(errors, &(&1.code == :missing_data))
    assert {:error, [%{code: :not_docx}]} = FormTemplate.fill("z2", "bad", %{}, "ru")
    assert {:error, :lang_not_supported} = FormTemplate.fill("z2", "bad", %{}, "en")
    {:ok, starter} = FormTemplate.starter("z2")

    assert {:error, [%{code: :infected}]} =
             FormTemplate.fill("z2", starter, %{}, "ru", scanner: Infected)
  end

  test "FL7 company skin and package parts survive filling" do
    company =
      D.valid()
      |> D.body("<w:p>#{D.run("Утверждаю")}</w:p>")
      |> D.replace("w:top=\"1134\"", "w:top=\"777\"")
      |> D.zip()

    {:ok, checked} = FormTemplate.check("z2", company)
    {:ok, filled} = FormTemplate.fill("z2", company, %{}, "ru")
    assert "Утверждаю" in paragraphs(filled)
    assert filled |> tree() |> Xml.named("w:pgMar") |> hd() |> Xml.attr("w:top") == "777"
    a = D.unpack(checked.bytes)
    b = D.unpack(filled)
    assert Enum.sort(Map.keys(a)) == Enum.sort(Map.keys(b))
    for {name, bytes} <- a, name != "word/document.xml", do: assert(b[name] == bytes)
  end

  test "FL8 one template supplies both catalog languages" do
    {:ok, starter} = FormTemplate.starter("z2")

    for lang <- ~w(ru kk) do
      {:ok, filled} = FormTemplate.fill("z2", starter, %{}, lang)
      assert FormPrint.catalog()["z2.title"][lang] in paragraphs(filled)
    end
  end

  test "FL9 cleaning, non-map rows and optional logo follow platform values" do
    {:ok, starter} = FormTemplate.starter("z2")
    long = String.duplicate("a", 510) <> <<0>> <> "\n"

    data = %{
      "org_name" => long,
      "org_bin" => 123,
      "lines" => [nil, 1, "bad", %{"name" => 77}, %{"name" => <<0>> <> "x\ny"}]
    }

    {:ok, filled} = FormTemplate.fill("z2", starter, data, "ru")
    output = paragraphs(filled)
    assert String.duplicate("a", 500) in output
    assert "123" in output
    assert "77" in output
    assert "x y" in output
    {:ok, platform} = FormPrint.build("z2", data, "ru", :docx)
    assert output == paragraphs(platform)

    company =
      D.valid()
      |> D.body(D.p("tenant.logo") <> "<w:p><w:r><w:t>free<w:b/></w:t></w:r></w:p>")
      |> D.zip()

    assert {:ok, filled} = FormTemplate.fill("z2", company, %{}, "ru")
    refute D.unpack(filled)["word/document.xml"] =~ "{{tenant.logo}}"
    assert "free" in paragraphs(filled)
  end
end
