defmodule Letflow.Documents.FormTemplate.SampleTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.{FormPrint, FormTemplate}
  alias FormTemplate.{Sample, Xml}
  alias Letflow.FormTemplateDocx, as: D

  defp paragraphs(bytes) do
    {:ok, tree} = bytes |> D.unpack() |> Map.fetch!("word/document.xml") |> Xml.parse()

    tree
    |> Xml.named("w:p")
    |> Enum.map(fn p -> Enum.map_join(Xml.named(p, "w:t"), &Xml.text/1) end)
  end

  test "SA1 sample is fixed and complete for every form" do
    assert Sample.data("nope") == :error

    for form <- FormPrint.forms() do
      assert {:ok, data} = Sample.data(form)
      assert Sample.data(form) == {:ok, data}
      {:ok, layout} = FormPrint.layout(form)

      for b <- layout["blocks"] do
        keys =
          case b["type"] do
            "field" ->
              [b["key"]]

            "boxed_pairs" ->
              Enum.map(b["cells"], & &1["key"])

            type when type in ["signature", "signature_table"] ->
              [b["key"], b["key"] <> "_position"]

            _ ->
              []
          end

        for key <- keys, do: assert(data[key] == "[#{key}]")

        if b["type"] == "table" do
          assert [_, _] = data[b["rows"]]

          for {row, n} <- Enum.with_index(data[b["rows"]], 1) do
            columns =
              layout["blocks"]
              |> Enum.filter(&(&1["type"] == "table" and &1["rows"] == b["rows"]))
              |> Enum.flat_map(& &1["columns"])
              |> Enum.map(& &1["key"])
              |> Enum.uniq()

            assert Enum.sort(Map.keys(row)) == Enum.sort(columns)

            for c <- b["columns"] do
              key = c["key"]

              expected =
                if key in ((b["totals"] || %{})["sum"] || []),
                  do: "#{n}.000000000",
                  else: "[#{key} #{n}]"

              assert row[key] == expected
            end
          end
        end
      end
    end
  end

  @tag timeout: 60_000
  test "SA2 every starter preview matches the platform sample paragraphs" do
    for form <- FormPrint.forms(), lang <- ~w(ru kk) do
      {:ok, sample} = Sample.data(form)
      {:ok, starter} = FormTemplate.starter(form)
      assert {:ok, preview} = FormTemplate.preview(form, starter, lang)
      assert {:ok, platform} = FormPrint.build(form, sample, lang, :docx)
      assert paragraphs(preview) == paragraphs(platform), "#{form} #{lang}"
      refute Enum.join(paragraphs(preview)) =~ "{{"
      assert Enum.join(paragraphs(preview)) =~ "["
    end
  end

  test "SA3 preview delegates to fill with the sample and preserves errors" do
    {:ok, starter} = FormTemplate.starter("z2")
    {:ok, sample} = Sample.data("z2")
    {:ok, preview} = FormTemplate.preview("z2", starter, "ru")
    {:ok, filled} = FormTemplate.fill("z2", starter, sample, "ru")
    assert D.unpack(preview)["word/document.xml"] == D.unpack(filled)["word/document.xml"]
    assert FormTemplate.preview("z2", starter, "en") == {:error, :lang_not_supported}
    assert {:error, [%{code: :unknown_form}]} = FormTemplate.preview("nope", starter, "ru")
  end

  test "SA4 preview refuses templates rejected by the current check" do
    bad = D.valid("z2") |> D.body(D.p("unknown")) |> D.zip()
    assert {:error, [%{code: :unknown_name} | _]} = FormTemplate.preview("z2", bad, "ru")
  end
end
