defmodule Letflow.Documents.FormTemplate.Sanitizer do
  @moduledoc """
  Decision 0089 D4 allow-list, content checks and canonical package rewrite.
  The scanner runs on the compressed upload and each inflated kept part. It fails
  closed. The default scanner detects EICAR; it is not a general antivirus engine.
  XML is parsed once; RunJoin rewrites that tree and Check consumes its occurrences.
  """
  alias Letflow.Documents.FormTemplate, as: F
  alias F.{RunJoin, Xml}
  @rel_ns "http://schemas.openxmlformats.org/package/2006/relationships"
  @office "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
  @type_ns "http://schemas.openxmlformats.org/package/2006/content-types"
  @main "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
  @word "application/vnd.openxmlformats-officedocument.wordprocessingml."

  def scan(bytes, type, opts) do
    scanner =
      Keyword.get(
        opts,
        :scanner,
        Application.get_env(
          :letflow,
          :attachment_scanner,
          Letflow.Repository.AttachmentScanner.SignatureHeuristic
        )
      )

    case scanner.scan(bytes, type) do
      {:ok, :clean} -> :ok
      {:ok, :infected, _} -> F.error(:infected)
      _ -> F.error(:scan_unavailable)
    end
  rescue
    _ -> F.error(:scan_unavailable)
  catch
    _, _ -> F.error(:scan_unavailable)
  end

  def run(parts, opts \\ []) do
    with {:ok, kept, dropped} <- classify(parts),
         {:ok, trees} <- parse_parts(kept, opts),
         :ok <- docx(trees),
         {:ok, rewritten} <- rewrite(trees),
         {:ok, joined, occurrences} <- RunJoin.run(rewritten) do
      {:ok, %{parts: joined, occurrences: occurrences, summary: summary(joined, dropped)}}
    end
  rescue
    _ -> F.error(:xml_unreadable)
  catch
    _, _ -> F.error(:xml_unreadable)
  end

  defp classify(parts) do
    Enum.reduce_while(parts, {:ok, [], []}, fn {name, bytes}, {:ok, kept, dropped} ->
      case classification(name) do
        {:refuse, code, category} -> {:halt, F.error(code, "D4", nil, nil, category)}
        :keep -> {:cont, {:ok, [{name, bytes} | kept], dropped}}
        {:drop, cat} -> {:cont, {:ok, kept, Enum.uniq([cat | dropped])}}
      end
    end)
  end

  defp classification(name) do
    n = String.downcase(name)

    cond do
      String.contains?(n, "vbaproject.bin") ->
        {:refuse, :forbidden_part, :macro}

      String.contains?(n, "/activex/") ->
        {:refuse, :forbidden_part, :activex}

      String.contains?(n, "oleobject") ->
        {:refuse, :forbidden_part, :ole}

      String.contains?(n, "/embeddings/") ->
        {:refuse, :forbidden_part, :embedding}

      String.ends_with?(n, ".bin") ->
        {:refuse, :forbidden_part, :binary}

      String.starts_with?(n, "customxml/") ->
        {:refuse, :forbidden_part, :custom_xml}

      String.starts_with?(n, "word/fonts/") ->
        {:refuse, :forbidden_part, :embedded_font}

      String.contains?(n, ["afchunk", "altchunk"]) ->
        {:refuse, :forbidden_part, :alt_chunk}

      String.starts_with?(n, "word/media/") and not Regex.match?(~r/\.(png|jpg|jpeg)$/, name) ->
        {:refuse, :image_type, nil}

      keep?(name) ->
        :keep

      String.starts_with?(n, "docprops/") ->
        {:drop, :doc_props}

      n == "word/websettings.xml" ->
        {:drop, :web_settings}

      n == "word/footnotes.xml" ->
        {:drop, :footnotes}

      n == "word/endnotes.xml" ->
        {:drop, :endnotes}

      n == "word/comments.xml" ->
        {:drop, :comments}

      true ->
        {:drop, :other}
    end
  end

  defp keep?(n) do
    n in [
      "[Content_Types].xml",
      "_rels/.rels",
      "word/document.xml",
      "word/styles.xml",
      "word/settings.xml",
      "word/fontTable.xml",
      "word/numbering.xml",
      "word/theme/theme1.xml"
    ] or
      Regex.match?(~r/^word\/(header[0-9]+|footer[0-9]+)\.xml$/, n) or
      Regex.match?(~r/^word\/media\/[^\/]+\.(png|jpg|jpeg)$/, n) or
      (String.starts_with?(n, "word/") and String.ends_with?(n, ".rels") and
         Path.basename(Path.dirname(n)) == "_rels" and
         keep?(Path.join(Path.dirname(Path.dirname(n)), Path.basename(n, ".rels"))))
  end

  defp parse_parts(parts, opts) do
    Enum.reduce_while(Enum.sort(parts), {:ok, %{}}, fn {name, bytes}, {:ok, acc} ->
      image = String.starts_with?(name, "word/media/")

      type =
        if image,
          do: if(String.ends_with?(name, ".png"), do: "image/png", else: "image/jpeg"),
          else: "application/xml"

      result =
        with :ok <- scan(bytes, type, opts) do
          if image do
            with :ok <- image(bytes, type), do: {:ok, bytes}
          else
            with {:ok, tree} <- Xml.parse(bytes), :ok <- content(tree), do: {:ok, tree}
          end
        end

      case result do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp image(bytes, type) do
    magic =
      case {type, bytes} do
        {"image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>} -> true
        {"image/jpeg", <<255, 216, 255, _::binary>>} -> true
        _ -> false
      end

    cond do
      not magic -> F.error(:image_type)
      byte_size(bytes) > Letflow.Identity.TenantLogo.max_bytes() -> F.error(:image_too_large)
      true -> :ok
    end
  end

  defp docx(parts) do
    ct = parts["[Content_Types].xml"]
    rels = parts["_rels/.rels"]

    override =
      if ct,
        do:
          Enum.find(
            Xml.named(ct, "Override"),
            &(Xml.attr(&1, "PartName") == "/word/document.xml")
          )

    type = if override, do: Xml.attr(override, "ContentType")

    office =
      if rels,
        do:
          Enum.any?(
            Xml.named(rels, "Relationship"),
            &(Xml.attr(&1, "Type") == @office and
                Xml.attr(&1, "Target") in ["word/document.xml", "/word/document.xml"])
          )

    cond do
      is_binary(type) and String.contains?(String.downcase(type), ".template.") ->
        F.error(:not_docx)

      is_binary(type) and String.contains?(String.downcase(type), "macroenabled") ->
        F.error(:macro_enabled)

      type != @main or office != true or is_nil(parts["word/document.xml"]) ->
        F.error(:not_docx)

      elem(ct, 0) != "Types" or Xml.attr(ct, "xmlns") != @type_ns or
        elem(rels, 0) != "Relationships" or Xml.attr(rels, "xmlns") != @rel_ns ->
        F.error(:not_docx)

      elem(parts["word/document.xml"], 0) != "w:document" ->
        F.error(:not_docx)

      true ->
        :ok
    end
  end

  defp content(tree) do
    # Legacy VML can carry a remote URL inline, without an External relationship.
    # Require resource links to use the checked relationship surface instead.
    inline_link =
      Enum.any?(Xml.nodes(tree), fn {_, attrs, _} ->
        Enum.any?(attrs, fn {key, value} ->
          List.last(String.split(key, ":")) in ["src", "href"] and value != ""
        end)
      end)

    result =
      Enum.reduce_while(Xml.nodes(tree), :ok, fn {name, _, _} = node, :ok ->
        error =
          case name do
            n when n in ["w:object", "o:OLEObject"] ->
              F.error(:forbidden_part, "D4", nil, nil, :ole)

            "w:control" ->
              F.error(:forbidden_part, "D4", nil, nil, :activex)

            "w:altChunk" ->
              F.error(:forbidden_part, "D4", nil, nil, :alt_chunk)

            "w:attachedTemplate" ->
              F.error(:forbidden_part, "D4", nil, nil, :attached_template)

            "w:embedTrueTypeFonts" ->
              F.error(:forbidden_part, "D4", nil, nil, :embedded_font)

            "w:mailMerge" ->
              F.error(:forbidden_part, "D4", nil, nil, :mail_merge)

            n when n in ["w:ins", "w:del", "w:moveFrom", "w:moveTo"] ->
              F.error(:tracked_change)

            "w:dataBinding" ->
              F.error(:data_binding)

            n when n in ["w:footnoteReference", "w:endnoteReference"] ->
              F.error(:unsupported_reference, "D4", nil, nil, :footnote)

            n when n in ["w:commentReference", "w:commentRangeStart", "w:commentRangeEnd"] ->
              F.error(:unsupported_reference, "D4", nil, nil, :comment)

            "w:fldSimple" ->
              nested =
                node
                |> Xml.nodes()
                |> tl()
                |> Enum.any?(&(elem(&1, 0) in ["w:fldChar", "w:fldSimple"]))

              if not nested and valid_field?(Xml.attr(node, "w:instr") || ""),
                do: :ok,
                else: F.error(:field_code)

            _ ->
              :ok
          end

        if error == :ok, do: {:cont, :ok}, else: {:halt, error}
      end)

    if inline_link do
      F.error(:external_relationship)
    else
      with :ok <- result, do: fields(Xml.nodes(tree), nil)
    end
  end

  defp valid_field?(s), do: Regex.match?(~r/^\s*(PAGE|NUMPAGES)(\s+\\\*\s+[A-Za-z]+)*\s*$/i, s)
  defp fields([], nil), do: :ok
  defp fields([], _), do: F.error(:field_code)
  defp fields([{"w:fldSimple", _, _} | _], state) when not is_nil(state), do: F.error(:field_code)

  defp fields([{"w:fldChar", _, _} = n | rest], state) do
    case {Xml.attr(n, "w:fldCharType"), state} do
      {"begin", nil} ->
        fields(rest, {:instruction, ""})

      {"separate", {:instruction, text}} ->
        if valid_field?(text), do: fields(rest, :result), else: F.error(:field_code)

      {"end", {:instruction, text}} ->
        if valid_field?(text), do: fields(rest, nil), else: F.error(:field_code)

      {"end", :result} ->
        fields(rest, nil)

      _ ->
        F.error(:field_code)
    end
  end

  defp fields([{"w:instrText", _, _} = n | rest], {:instruction, text}),
    do: fields(rest, {:instruction, text <> Xml.text(n)})

  defp fields([{"w:instrText", _, _} | _], _), do: F.error(:field_code)
  defp fields([_ | rest], state), do: fields(rest, state)

  defp rewrite(parts) do
    with {:ok, parts} <- relationships(parts), :ok <- references(parts) do
      parts =
        Map.new(parts, fn {name, tree} ->
          value =
            if is_binary(tree),
              do: tree,
              else:
                Xml.map(tree, fn {n, a, c} ->
                  if n in ["w:rsids", "w:proofErr", "w:footnotePr", "w:endnotePr"],
                    do: nil,
                    else: {n, a, c}
                end)

          {name, value}
        end)

      {:ok,
       parts
       |> Map.put(
         "_rels/.rels",
         {"Relationships", [{"xmlns", @rel_ns}],
          [
            {"Relationship", [{"Id", "rId1"}, {"Type", @office}, {"Target", "word/document.xml"}],
             []}
          ]}
       )
       |> Map.put("[Content_Types].xml", content_types(parts))}
    end
  end

  defp relationships(parts) do
    Enum.reduce_while(parts, {:ok, parts}, fn {name, tree}, {:ok, acc} ->
      if String.ends_with?(name, ".rels") do
        result =
          Enum.reduce_while(Xml.named(tree, "Relationship"), {:ok, [], MapSet.new()}, fn rel,
                                                                                         {:ok,
                                                                                          kept,
                                                                                          ids} ->
            target = Xml.attr(rel, "Target") || ""
            id = Xml.attr(rel, "Id")
            resolved = resolve(name, target)

            cond do
              String.downcase(Xml.attr(rel, "TargetMode") || "") == "external" ->
                {:halt, F.error(:external_relationship)}

              resolved == :error ->
                {:halt, F.error(:zip_bad_entry)}

              is_nil(id) or MapSet.member?(ids, id) ->
                {:halt, F.error(:unsupported_reference)}

              Map.has_key?(parts, resolved) ->
                {:cont,
                 {:ok,
                  kept ++
                    [
                      {"Relationship",
                       Enum.filter(elem(rel, 1), fn {k, _} -> k in ["Id", "Type", "Target"] end),
                       []}
                    ], MapSet.put(ids, id)}}

              true ->
                {:cont, {:ok, kept, MapSet.put(ids, id)}}
            end
          end)

        case result do
          {:ok, kept, _} ->
            {:cont, {:ok, Map.put(acc, name, {"Relationships", [{"xmlns", @rel_ns}], kept})}}

          error ->
            {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp resolve(rels, target) do
    base = if rels == "_rels/.rels", do: [], else: rels |> String.split("/") |> Enum.drop(-2)

    segments =
      if String.starts_with?(target, "/"),
        do: String.split(target, "/"),
        else: base ++ String.split(target, "/")

    if String.contains?(target, ["\\", ":", <<0>>, "%", "?", "#"]) do
      :error
    else
      Enum.reduce_while(segments, [], fn
        s, acc when s in ["", "."] -> {:cont, acc}
        "..", [] -> {:halt, :error}
        "..", acc -> {:cont, Enum.drop(acc, -1)}
        s, acc -> {:cont, acc ++ [s]}
      end)
      |> case do
        :error -> :error
        path -> Enum.join(path, "/")
      end
    end
  end

  defp references(parts) do
    bad =
      Enum.any?(parts, fn {name, tree} ->
        relpath = Path.dirname(name) <> "/_rels/" <> Path.basename(name) <> ".rels"

        ids =
          if parts[relpath],
            do: Enum.map(Xml.named(parts[relpath], "Relationship"), &Xml.attr(&1, "Id")),
            else: []

        Enum.any?(Xml.nodes(tree), fn {_, attrs, _} ->
          Enum.any?(attrs, fn {k, v} ->
            (String.starts_with?(k, "r:") or k == "o:relid") and v not in ids
          end)
        end)
      end)

    if bad, do: F.error(:unsupported_reference), else: :ok
  end

  defp content_types(parts) do
    defaults =
      for {ext, type} <- [
            {"rels", "application/vnd.openxmlformats-package.relationships+xml"},
            {"xml", "application/xml"},
            {"png", "image/png"},
            {"jpg", "image/jpeg"},
            {"jpeg", "image/jpeg"}
          ],
          do: {"Default", [{"Extension", ext}, {"ContentType", type}], []}

    overrides =
      parts
      |> Map.keys()
      |> Enum.sort()
      |> Enum.filter(&(String.ends_with?(&1, ".xml") and &1 != "[Content_Types].xml"))
      |> Enum.map(fn n ->
        {"Override", [{"PartName", "/" <> n}, {"ContentType", part_type(n)}], []}
      end)

    {"Types", [{"xmlns", @type_ns}], defaults ++ overrides}
  end

  defp part_type("word/document.xml"), do: @main

  defp part_type("word/theme/theme1.xml"),
    do: "application/vnd.openxmlformats-officedocument.theme+xml"

  defp part_type(n) do
    suffix =
      cond do
        String.contains?(n, "/header") -> "header"
        String.contains?(n, "/footer") -> "footer"
        true -> Path.basename(n, ".xml")
      end

    @word <> suffix <> "+xml"
  end

  defp summary(parts, dropped) do
    doc = parts["word/document.xml"]
    sections = Xml.named(doc, "w:sectPr")
    last = List.last(sections)
    pg = if last, do: List.first(Xml.named(last, "w:pgSz"))
    mar = if last, do: List.first(Xml.named(last, "w:pgMar"))

    page =
      if pg,
        do: %{
          width: Xml.integer(Xml.attr(pg, "w:w")),
          height: Xml.integer(Xml.attr(pg, "w:h")),
          orientation:
            if(Xml.attr(pg, "w:orient") == "landscape", do: "landscape", else: "portrait")
        }

    margins =
      if mar,
        do:
          Map.new([top: "w:top", right: "w:right", bottom: "w:bottom", left: "w:left"], fn {k, a} ->
            {k, Xml.integer(Xml.attr(mar, a))}
          end)

    fonts =
      Xml.named(parts["word/styles.xml"], "w:rFonts")
      |> Enum.map(&Xml.attr(&1, "w:ascii"))
      |> Enum.filter(&(is_binary(&1) and String.length(&1) <= 64))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(20)

    tables =
      Xml.named(doc, "w:tbl")
      |> Enum.with_index(1)
      |> Enum.map(fn {tbl, i} ->
        grid = List.first(Xml.children(tbl, "w:tblGrid"))

        %{
          table: i,
          rows: length(Xml.children(tbl, "w:tr")),
          grid_columns: if(grid, do: length(Xml.children(grid, "w:gridCol")), else: 0)
        }
      end)

    %{
      page: page,
      margins: margins,
      sections: length(sections),
      paragraphs: length(Xml.named(doc, "w:p")),
      images: Enum.count(parts, fn {n, _} -> String.starts_with?(n, "word/media/") end),
      tables: tables,
      fonts: fonts,
      dropped: Enum.sort(dropped)
    }
  end
end
