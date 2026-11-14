defmodule Letflow.Documents.FormTemplate.SanitizerTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.FormTemplate, as: F
  alias Letflow.FormTemplateDocx, as: D

  defp refused(pkg, code, category \\ :any) do
    result = F.check("z2", D.zip(pkg))
    assert {:error, [%{code: ^code, rule: "D4"} = error]} = result
    if category != :any, do: assert(error.category == category)
    refute inspect(result) =~ "private_marker"
    result
  end

  test "S1-macro, S1-ole and S1-custom-xml forbidden parts" do
    for {name, cat} <- [
          {"word/vbaProject.bin", :macro},
          {"word/embeddings/oleObject1.bin", :ole},
          {"word/activeX/activeX1.xml", :activex},
          {"customXml/item1.xml", :custom_xml},
          {"word/fonts/font1.odttf", :embedded_font},
          {"word/afchunk1.xml", :alt_chunk},
          {"word/x.bin", :binary}
        ] do
      refused(Map.put(D.valid(), name, "private_marker"), :forbidden_part, cat)
    end

    refused(
      D.edit(
        D.valid(),
        "[Content_Types].xml",
        &String.replace(
          &1,
          D.main_type(),
          "application/vnd.ms-word.document.macroEnabled.main+xml"
        )
      ),
      :macro_enabled
    )
  end

  test "S1-ole active elements, embedded fonts and attached templates" do
    for {xml, code, cat} <- [
          {"<w:object/>", :forbidden_part, :ole},
          {"<w:control/>", :forbidden_part, :activex},
          {"<w:altChunk/>", :forbidden_part, :alt_chunk},
          {"<w:attachedTemplate/>", :forbidden_part, :attached_template},
          {"<w:embedTrueTypeFonts/>", :forbidden_part, :embedded_font},
          {"<w:mailMerge/>", :forbidden_part, :mail_merge},
          {"<w:dataBinding/>", :data_binding, nil},
          {"<w:ins/>", :tracked_change, nil},
          {"<w:del/>", :tracked_change, nil},
          {"<w:moveFrom/>", :tracked_change, nil},
          {"<w:moveTo/>", :tracked_change, nil},
          {"<w:footnoteReference/>", :unsupported_reference, :footnote},
          {"<w:endnoteReference/>", :unsupported_reference, :footnote},
          {"<w:commentReference/>", :unsupported_reference, :comment}
        ] do
      refused(D.body(D.valid(), xml), code, cat)
    end
  end

  test "S1-external-link remote links, images, escaping root and dangling references" do
    for xml <- [
          D.relationship("x", "https://private_marker", ~s(TargetMode="External")),
          D.relationship("x", "https://private_marker/p.png", ~s(TargetMode="eXtErNaL"))
        ] do
      refused(
        Map.put(D.valid(), "word/_rels/document.xml.rels", D.rels(xml)),
        :external_relationship
      )
    end

    refused(
      Map.put(D.valid(), "word/_rels/document.xml.rels", D.rels(D.relationship("x", "../../x"))),
      :zip_bad_entry
    )

    for target <- ["webSettings.xml", "extra/pic.xml"] do
      pkg =
        D.valid()
        |> Map.put("word/_rels/document.xml.rels", D.rels(D.relationship("x", target)))
        |> Map.put("word/extra/pic.xml", "<x/>")
        |> D.body(~s(<w:drawing r:embed="x"/>))

      refused(pkg, :unsupported_reference)
    end

    refused(D.body(D.valid(), ~s(<w:drawing r:embed="absent"/>)), :unsupported_reference)
  end

  test "S1-field-code only page fields, balanced and non-nested" do
    for instr <- ["INCLUDETEXT x", "DDEAUTO x", "PAGE evil"] do
      refused(D.body(D.valid(), ~s(<w:p><w:fldSimple w:instr="#{instr}"/></w:p>)), :field_code)
    end

    complex =
      ~s(<w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText>DDE</w:instrText><w:instrText>AUTO x</w:instrText><w:fldChar w:fldCharType="end"/></w:r></w:p>)

    refused(D.body(D.valid(), complex), :field_code)

    nested =
      ~s(<w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText>PAGE</w:instrText><w:fldChar w:fldCharType="begin"/></w:r></w:p>)

    refused(D.body(D.valid(), nested), :field_code)

    unbalanced =
      ~s(<w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText>PAGE</w:instrText></w:r></w:p>)

    refused(D.body(D.valid(), unbalanced), :field_code)

    for instr <- ["PAGE \\* MERGEFORMAT", "NUMPAGES"] do
      assert {:ok, _} =
               F.check(
                 "z2",
                 D.valid() |> D.body(~s(<w:p><w:fldSimple w:instr="#{instr}"/></w:p>)) |> D.zip()
               )

      xml =
        ~s(<w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText>#{instr}</w:instrText><w:fldChar w:fldCharType="separate"/><w:t>1</w:t><w:fldChar w:fldCharType="end"/></w:r></w:p>)

      assert {:ok, _} = F.check("z2", D.valid() |> D.body(xml) |> D.zip())
    end
  end

  test "S1-doctype, encoding, depth and namespace bypasses" do
    for xml <- ["<!DOCTYPE x><x/>", "<!ENTITY private_marker 'x'><x/>"] do
      refused(Map.put(D.valid(), "word/styles.xml", xml), :doctype)
    end

    for xml <- [
          ~s(<?xml version="1.0" encoding="UTF-16"?><x/>),
          "<x>",
          <<255>>,
          :binary.copy("<x>", 257) <> :binary.copy("</x>", 257)
        ] do
      refused(Map.put(D.valid(), "word/styles.xml", xml), :xml_unreadable)
    end

    # Equivalent aliases and prefix rebinding are refused, never silently bypassed.
    for xml <- [
          ~s(<x:object xmlns:x="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>),
          ~s(<w:object xmlns:w="urn:other"/>),
          ~s(<w:p xmlns:r="urn:other" r:embed="x"/>)
        ] do
      refused(D.body(D.valid(), xml), :xml_unreadable)
    end
  end

  test "S1-image magic bytes and exact logo cap" do
    refused(Map.put(D.valid(), "word/media/a.gif", "GIF89a"), :image_type)
    refused(Map.put(D.valid(), "word/media/a.png", <<255, 216, 255>>), :image_type)
    magic = <<137, 80, 78, 71, 13, 10, 26, 10>>
    # Random bytes avoid the independent 100:1 ZIP cap.
    png = magic <> :crypto.strong_rand_bytes(524_288 - 8)
    assert {:ok, out} = F.check("z2", Map.put(D.valid(), "word/media/a.png", png) |> D.zip())
    assert D.unpack(out.bytes)["word/media/a.png"] == png
    assert out.summary.images == 1
    refused(Map.put(D.valid(), "word/media/a.png", png <> "x"), :image_too_large)
  end

  test "S1-not-docx missing document and dotx main type" do
    refused(
      D.edit(
        D.valid(),
        "[Content_Types].xml",
        &String.replace(
          &1,
          D.main_type(),
          "application/vnd.ms-word.template.macroEnabledTemplate.main+xml"
        )
      ),
      :not_docx
    )

    refused(Map.delete(D.valid(), "word/document.xml"), :not_docx)

    refused(
      D.edit(
        D.valid(),
        "[Content_Types].xml",
        &String.replace(
          &1,
          D.main_type(),
          "application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml"
        )
      ),
      :not_docx
    )
  end

  test "namespace defaults, undeclared prefixes and duplicate attributes fail closed" do
    for xml <- [
          ~s(<object xmlns="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>),
          ~s(<x:object/>),
          ~s(<w:fldSimple w:instr="PAGE" w:instr="INCLUDETEXT private_marker"/>)
        ] do
      refused(D.body(D.valid(), xml), :xml_unreadable)
    end
  end

  test "strict namespace aliases and legacy inline remote resources cannot bypass D4" do
    for uri <- [
          "http://purl.oclc.org/ooxml/wordprocessingml/main",
          "http://purl.oclc.org/ooxml/officeDocument/relationships"
        ] do
      refused(
        D.body(
          D.valid(),
          ~s(<x:fldSimple xmlns:x="#{uri}" x:instr="INCLUDETEXT private_marker"/>)
        ),
        :xml_unreadable
      )
    end

    for key <- ["src", "href"] do
      xml =
        ~s(<w:p><w:r><w:pict><v:imagedata xmlns:v="urn:schemas-microsoft-com:vml" #{key}="https://private_marker/p.png"/></w:pict></w:r></w:p>)

      refused(D.body(D.valid(), xml), :external_relationship)
    end

    refused(
      D.body(
        D.valid(),
        ~s(<w:p xmlns:o="urn:schemas-microsoft-com:office:office" o:relid="absent"/>)
      ),
      :unsupported_reference
    )
  end

  test "relationships of nested kept parts use their own directory" do
    pkg =
      D.valid()
      |> Map.put("word/media/a.png", <<137, 80, 78, 71, 13, 10, 26, 10>>)
      |> Map.put(
        "word/theme/theme1.xml",
        ~s(<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><a:blip r:embed="image1"/></a:theme>)
      )
      |> Map.put(
        "word/theme/_rels/theme1.xml.rels",
        D.rels(D.relationship("image1", "../media/a.png"))
      )

    assert {:ok, out} = F.check("z2", D.zip(pkg))
    assert Map.has_key?(D.unpack(out.bytes), "word/theme/_rels/theme1.xml.rels")
    assert {:ok, %{bytes: fixed}} = F.check("z2", out.bytes)
    assert fixed == out.bytes
  end

  test "nested simple and complex page fields are refused" do
    for xml <- [
          ~s(<w:fldSimple w:instr="PAGE"><w:fldSimple w:instr="PAGE"/></w:fldSimple>),
          ~s(<w:r><w:fldChar w:fldCharType="begin"/><w:instrText>PAGE</w:instrText></w:r><w:fldSimple w:instr="PAGE"/><w:r><w:fldChar w:fldCharType="end"/></w:r>)
        ] do
      refused(D.body(D.valid(), "<w:p>#{xml}</w:p>"), :field_code)
    end
  end

  test "image relationships survive in body and headers and every r id resolves" do
    pkg =
      D.valid()
      |> Map.put("word/media/a.png", <<137, 80, 78, 71, 13, 10, 26, 10>>)
      |> Map.put("word/_rels/document.xml.rels", D.rels(D.relationship("img1", "media/a.png")))
      |> Map.put(
        "word/header1.xml",
        ~s(<w:hdr #{D.namespaces()}><w:p><w:r><w:drawing r:embed="img2"/></w:r></w:p></w:hdr>)
      )
      |> Map.put("word/_rels/header1.xml.rels", D.rels(D.relationship("img2", "media/a.png")))
      |> D.body(~s(<w:p><w:r><w:drawing r:embed="img1"/></w:r></w:p>))

    assert {:ok, out} = F.check("z2", D.zip(pkg))
    parts = D.unpack(out.bytes)

    for part <- ["document.xml", "header1.xml"] do
      assert {:ok, rels} = F.Xml.parse(parts["word/_rels/#{part}.rels"])

      for rel <- F.Xml.named(rels, "Relationship") do
        assert Map.has_key?(parts, "word/" <> F.Xml.attr(rel, "Target"))
      end

      ids = Enum.map(F.Xml.named(rels, "Relationship"), &F.Xml.attr(&1, "Id"))
      assert {:ok, tree} = F.Xml.parse(parts["word/#{part}"])

      for {_, attrs, _} <- F.Xml.nodes(tree),
          {key, id} <- attrs,
          String.starts_with?(key, "r:") do
        assert id in ids
      end
    end

    assert {:ok, %{bytes: fixed}} = F.check("z2", out.bytes)
    assert fixed == out.bytes
  end
end
