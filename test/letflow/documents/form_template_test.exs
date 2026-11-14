defmodule Letflow.Documents.FormTemplateTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.{FormPrint, FormTemplate}
  alias FormTemplate.{Keys, Xml}
  alias Letflow.FormTemplateDocx, as: D

  defmodule RaisingScanner do
    def scan(_, _), do: raise("private_marker")
  end

  defmodule ErrorScanner do
    def scan(_, _), do: {:error, "private_marker"}
  end

  defmodule ThrowingScanner do
    def scan(_, _), do: throw("private_marker")
  end

  defmodule RecordingScanner do
    def scan(bytes, type) do
      send(self(), {:scanned, bytes, type})
      {:ok, :clean}
    end
  end

  test "S1-accept all shipped forms and S1-one-parse fixed point" do
    for form <- FormPrint.forms() do
      assert {:ok, first} = FormTemplate.check(form, D.valid(form) |> D.zip()), form
      assert {:ok, second} = FormTemplate.check(form, first.bytes), form
      assert second.bytes == first.bytes
      assert second.sha256 == first.sha256
      assert first.sha256 == Base.encode16(:crypto.hash(:sha256, first.bytes), case: :lower)
      parts = D.unpack(first.bytes)

      assert Map.keys(parts) |> Enum.sort() ==
               Enum.sort(
                 ~w([Content_Types].xml _rels/.rels word/document.xml word/styles.xml word/settings.xml word/_rels/document.xml.rels)
               )

      refute parts["word/settings.xml"] =~ "footnotePr"
      refute parts["word/settings.xml"] =~ "endnotePr"
      refute parts["word/settings.xml"] =~ "rsids"

      assert Enum.sort(first.summary.dropped) == [
               :doc_props,
               :endnotes,
               :footnotes,
               :web_settings
             ]

      {:ok, ct} = Xml.parse(parts["[Content_Types].xml"])

      for node <- Xml.named(ct, "Override") do
        assert Map.has_key?(parts, String.trim_leading(Xml.attr(node, "PartName"), "/"))
      end

      {:ok, rel} = Xml.parse(parts["_rels/.rels"])

      for node <- Xml.named(rel, "Relationship"),
          do: assert(Map.has_key?(parts, Xml.attr(node, "Target")))
    end
  end

  test "S1-summary structured page, margins, fonts, tables and key counts" do
    assert {:ok, out} = FormTemplate.check("z2", D.valid() |> D.zip())
    assert out.summary.page == %{width: 11906, height: 16838, orientation: "portrait"}
    assert out.summary.margins == %{top: 1134, right: 850, bottom: 1134, left: 1276}
    assert out.summary.tables == [%{table: 1, rows: 5, grid_columns: 9}]
    assert out.summary.fonts == ["Times New Roman"]
    assert out.summary.sections == 1
    {:ok, keys} = Keys.for_form("z2")
    assert out.summary.placeholders == %{legal: length(keys.legal), data: length(keys.data)}
    pkg = D.valid() |> D.replace(~s(w:w="11906"), ~s(w:w="oops"))
    assert {:ok, out} = FormTemplate.check("z2", D.zip(pkg))
    assert out.summary.page.width == nil
  end

  test "S1-escape escaped markup remains text, including attribute values" do
    text = ~s(&lt;w:fldSimple w:instr="INCLUDETEXT x"/&gt; &amp; R&amp;D)

    pkg =
      D.body(
        D.valid(),
        ~s(<w:p><w:pPr><w:pStyle w:val="a&amp;b&quot;"/></w:pPr>#{D.run(text)}</w:p>)
      )

    assert {:ok, out} = FormTemplate.check("z2", D.zip(pkg))
    {:ok, checked} = Xml.parse(pkg["word/document.xml"])
    {:ok, written} = Xml.parse(D.unpack(out.bytes)["word/document.xml"])
    assert Xml.named(written, "w:fldSimple") == []

    assert Enum.map(Xml.nodes(checked), &elem(&1, 0)) ==
             Enum.map(Xml.nodes(written), &elem(&1, 0))

    assert Enum.any?(
             Xml.named(written, "w:t"),
             &(Xml.text(&1) == ~s(<w:fldSimple w:instr="INCLUDETEXT x"/> & R&D))
           )

    assert [style] = Xml.named(written, "w:pStyle")
    assert Xml.attr(style, "w:val") == "a&b\""
    assert {:ok, %{bytes: fixed}} = FormTemplate.check("z2", out.bytes)
    assert fixed == out.bytes
  end

  test "S1-split joins split placeholders, preserves first style and bookmarks" do
    for pretty <- [false, true] do
      runs = D.split_runs("{{legal.title}}", 3)
      runs = if pretty, do: String.replace(runs, "><", ">\n  <"), else: runs
      pkg = D.replace(D.valid(), D.p("legal.title"), "<w:p>#{runs}</w:p>")
      assert {:ok, out} = FormTemplate.check("z2", D.zip(pkg))
      {:ok, tree} = Xml.parse(D.unpack(out.bytes)["word/document.xml"])

      assert [p] =
               Enum.filter(Xml.named(tree, "w:p"), fn p ->
                 Enum.any?(Xml.named(p, "w:t"), &(Xml.text(&1) == "{{legal.title}}"))
               end)

      assert length(Xml.children(p, "w:r")) == 1
      assert length(Xml.named(p, "w:b")) == 1
      assert length(Xml.named(p, "w:bookmarkStart")) == 1
      assert length(Xml.named(p, "w:bookmarkEnd")) == 1
    end
  end

  test "S1-split stray text breaks placeholders and overlapping ranges merge once" do
    pkg =
      D.replace(
        D.valid(),
        D.p("legal.title"),
        "<w:p>#{D.run("{{legal.")}x#{D.run("title}}")}</w:p>"
      )

    assert {:error, [%{code: :malformed_placeholder}]} = FormTemplate.check("z2", D.zip(pkg))

    pkg =
      D.replace(
        D.valid(),
        D.p("legal.title"),
        "<w:p>#{D.run("{{legal.")}\u00A0#{D.run("title}}")}</w:p>"
      )

    assert {:error, [%{code: :malformed_placeholder}]} = FormTemplate.check("z2", D.zip(pkg))

    runs =
      ~s(<w:r><w:rPr><w:b/></w:rPr><w:t>{{legal.label.or</w:t></w:r>) <>
        D.run("g_bin}}{{org") <> D.run("_bin}}")

    pkg =
      D.valid()
      |> D.remove("org_bin")
      |> D.replace(D.p("legal.label.org_bin"), "<w:p>#{runs}</w:p>")

    assert {:ok, out} = FormTemplate.check("z2", D.zip(pkg))
    {:ok, tree} = Xml.parse(D.unpack(out.bytes)["word/document.xml"])

    assert Enum.any?(Xml.named(tree, "w:r"), fn r ->
             Enum.any?(
               Xml.named(r, "w:t"),
               &(Xml.text(&1) == "{{legal.label.org_bin}}{{org_bin}}")
             ) and length(Xml.named(r, "w:b")) == 1
           end)
  end

  test "S1-pretty indented parts retain the same placeholder counts" do
    compact = D.valid()
    pretty = Map.new(compact, fn {n, bytes} -> {n, String.replace(bytes, "><", ">\n  <")} end)
    assert {:ok, a} = FormTemplate.check("z2", D.zip(compact))
    assert {:ok, b} = FormTemplate.check("z2", D.zip(pretty))
    assert a.summary.placeholders == b.summary.placeholders
  end

  test "S1-scan upload and inflated parts, fail closed for all scanner errors" do
    eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
    pkg = Map.put(D.valid(), "word/styles.xml", "<x><!--#{eicar}--></x>")

    for stored <- [false, true] do
      bytes = D.zip(pkg, stored: stored)
      if not stored, do: refute(String.contains?(bytes, eicar))
      assert {:error, [%{code: :infected}]} = FormTemplate.check("z2", bytes)
    end

    for scanner <- [RaisingScanner, ErrorScanner, ThrowingScanner] do
      assert {:error, [%{code: :scan_unavailable}]} =
               result = FormTemplate.check("z2", D.valid() |> D.zip(), scanner: scanner)

      refute inspect(result) =~ "private_marker"
    end

    pkg = D.valid()
    bytes = D.zip(pkg)
    assert {:ok, _} = FormTemplate.check("z2", bytes, scanner: RecordingScanner)

    assert_received {:scanned, ^bytes,
                     "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}

    for part <-
          ~w([Content_Types].xml _rels/.rels word/document.xml word/styles.xml word/settings.xml word/_rels/document.xml.rels) do
      value = pkg[part]
      assert_received {:scanned, ^value, "application/xml"}
    end

    refute_received {:scanned, _, _}
  end

  test "public limits and unique refusal code inventory" do
    assert length(Enum.uniq(FormTemplate.refusal_codes())) == length(FormTemplate.refusal_codes())

    assert FormTemplate.limits() == %{
             compressed: 1_048_576,
             inflated: 10_485_760,
             entries: 200,
             ratio: 100,
             image: 524_288,
             depth: 256,
             name: 64,
             refusals: 100
           }
  end
end
