defmodule Letflow.Documents.FormPrint do
  @moduledoc """
  T-1416 (phase E, E5b): the print engine for official forms, ru and kk, `.docx` and `.pdf`.

  A form is DATA: a layout file under `priv/print_forms/<form>.json` (closed schema "form layout
  v1": block types `text`, `title`, `field`, `table`, `signature`, `proxy`) and the message
  catalog `priv/print_forms/messages.json` (`key -> {ru, kk, kk_status}`). The layout holds no
  wording, only catalog keys; it reproduces the arrangement of an official form as our own data,
  the MinFin files themselves are never copied. Both files are read at compile time
  (`@external_resource`), so a release has no runtime path dependency.

  `build/5` fills the layout from a data map (string keys, supplied by a pure form mapper such as
  `Letflow.Modules.Stock.FormZ2`) and renders it:

      layout + catalog + data  ->  resolve/4 (one document model)  ->  Pdf.render/1 | Docx.render/1

  Rules, both formats:

    * Languages are `ru` and `kk` only (`{:error, :lang_not_supported}` otherwise).
    * A label comes from the catalog only, never from data; data never reaches a label.
    * An empty or missing field value prints as a blank line for the signer; signature parts and
      table cells that Letflow does not hold stay blank. Nothing is invented. The only computed
      value is the sum of the columns the layout names (`totals.sum`), as a `Decimal` of the
      stored texts; one invalid text makes the total blank.
    * A kk label whose catalog status is `machine_draft` adds the catalog's `draft_notice` as the
      last line of a kk output; official texts (all of Z-2) carry no notice.
    * Every data text is cleaned once (`clean/1`): characters illegal in XML 1.0 are dropped,
      line breaks become spaces, length is capped at #{500} characters, so a hostile value gives
      escaped text, not a crash (INV-8).

  A column may carry `"no"`, its official column number, when the table does not start at 1 (the
  back side of Inv-18 is columns 15 to 26); default is the position.

  Wider than 12 columns (Inv-18 has 14): the layout allows #{14}, the `.docx` keeps them in one
  table and the PDF cuts the table into column chunks (see `Pdf`). A signature block reads its
  position part from the data key `<key>_position`; a totals block may set `"skip_blank": true`
  so blank cells add nothing to a sum.

  The PDF side reuses `Letflow.Documents.PrintLayout` unchanged (closed one-row table header: a
  grouped header is flattened to `group: label`, the column number is a prefix); the `.docx` has
  the true merged header and the numbers row. No dependency is added: the `.docx` is a zip of
  XML written with OTP `:zip`.
  """

  alias Letflow.Documents.FormPrint.{Docx, Pdf}

  @max_text 500
  @langs ["ru", "kk"]
  @block_keys %{
    "text" => ["type", "label"],
    "title" => ["type", "label"],
    "field" => ["type", "label", "key"],
    "table" => ["type", "rows", "totals", "columns"],
    "signature" => ["type", "label", "key", "parts", "stamp"],
    "proxy" => ["type", "label"]
  }
  @parts ["position", "signature", "name"]
  @layout_keys ["form_layout_version", "form", "annex", "blocks"]
  @max_columns 14

  @catalog_path Path.join([__DIR__, "..", "..", "..", "priv", "print_forms", "messages.json"])
                |> Path.expand()
  @external_resource @catalog_path
  @catalog @catalog_path |> File.read!() |> Jason.decode!()

  @form_files Path.wildcard(Path.join(Path.dirname(@catalog_path), "*.json"))
              |> Enum.reject(&(Path.basename(&1) == "messages.json"))
  for f <- @form_files, do: @external_resource(f)

  @forms Map.new(@form_files, fn f ->
           {Path.basename(f, ".json"), f |> File.read!() |> Jason.decode!()}
         end)

  @type lang :: :ru | :kk
  @type format :: :pdf | :docx

  @doc "The message catalog: `key => %{\"ru\", \"kk\", \"kk_status\"}`."
  @spec catalog() :: map()
  def catalog, do: @catalog

  @doc "The shipped form ids."
  @spec forms() :: [String.t()]
  def forms, do: @forms |> Map.keys() |> Enum.sort()

  @doc "The decoded layout of a shipped form, or `:error`."
  @spec layout(String.t()) :: {:ok, map()} | :error
  def layout(form) when is_binary(form), do: Map.fetch(@forms, form)
  def layout(_), do: :error

  @doc """
  Validates a decoded layout against the closed schema and a catalog: version, known block types,
  only allowed keys per type, at most #{@max_columns} columns, every label present in the catalog for
  `ru` and `kk`. `{:error, reason}` carries an atom and a path, never a data value.
  """
  @spec validate_layout(term(), map()) :: :ok | {:error, {atom(), term()}}
  def validate_layout(%{} = layout, catalog) do
    with :ok <- known_keys(layout, @layout_keys, []),
         :ok <- check(layout["form_layout_version"] == 1, :bad_version, []),
         :ok <- check(is_binary(layout["form"]), :bad_form, []),
         :ok <- check(is_list(layout["blocks"]) and layout["blocks"] != [], :bad_blocks, []) do
      layout["blocks"]
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {b, i}, :ok ->
        case block(b, catalog, ["blocks", i]) do
          :ok -> {:cont, :ok}
          err -> {:halt, err}
        end
      end)
    end
  end

  def validate_layout(_, _), do: {:error, {:bad_layout, []}}

  defp block(%{"type" => type} = b, catalog, path) when is_map_key(@block_keys, type) do
    with :ok <- known_keys(b, Map.fetch!(@block_keys, type), path),
         :ok <- labels(b, catalog, path) do
      block_rules(type, b, catalog, path)
    end
  end

  defp block(_, _, path), do: {:error, {:unknown_block_type, path}}

  defp block_rules("field", b, _c, path), do: check(is_binary(b["key"]), :bad_key, path)

  defp block_rules("signature", b, c, path) do
    with :ok <- check(is_binary(b["key"]), :bad_key, path),
         :ok <-
           check(
             is_list(b["parts"]) and b["parts"] != [] and Enum.all?(b["parts"], &(&1 in @parts)),
             :bad_parts,
             path
           ) do
      if b["stamp"], do: label_present(b["stamp"], c, path ++ ["stamp"]), else: :ok
    end
  end

  defp block_rules("table", b, c, path) do
    cols = b["columns"]

    with :ok <-
           check(
             is_list(cols) and cols != [] and length(cols) <= @max_columns,
             :bad_columns,
             path
           ),
         :ok <- check(is_binary(b["rows"]), :bad_rows, path),
         :ok <- column_rules(cols, c, path) do
      totals_rules(b["totals"], c, path)
    end
  end

  defp block_rules(_, _, _, _), do: :ok

  defp column_rules(cols, catalog, path) do
    cols
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {col, i}, :ok ->
      p = path ++ ["columns", i]

      with :ok <- known_keys(col, ["key", "label", "group", "no"], p),
           :ok <- check(is_binary(col["key"]), :bad_key, p),
           :ok <- check(is_nil(col["no"]) or is_integer(col["no"]), :bad_column_no, p),
           :ok <- label_present(col["label"], catalog, p),
           :ok <- if(col["group"], do: label_present(col["group"], catalog, p), else: :ok) do
        {:cont, :ok}
      else
        err -> {:halt, err}
      end
    end)
  end

  defp totals_rules(nil, _c, _p), do: :ok

  defp totals_rules(%{} = t, c, p) do
    with :ok <- known_keys(t, ["label", "sum", "mark", "skip_blank"], p ++ ["totals"]),
         :ok <- label_present(t["label"], c, p ++ ["totals"]) do
      check(
        Enum.all?(t["sum"] || [], &is_binary/1) and Enum.all?(t["mark"] || [], &is_binary/1),
        :bad_totals,
        p ++ ["totals"]
      )
    end
  end

  defp totals_rules(_, _, p), do: {:error, {:bad_totals, p}}

  defp labels(%{"type" => "table"}, _catalog, _path), do: :ok
  defp labels(%{"label" => _} = b, catalog, path), do: label_present(b["label"], catalog, path)
  defp labels(_, _, path), do: {:error, {:missing_label, path}}

  defp label_present(key, catalog, path) do
    case catalog do
      %{^key => %{"ru" => ru, "kk" => kk}}
      when is_binary(ru) and ru != "" and is_binary(kk) and kk != "" ->
        :ok

      _ ->
        {:error, {:missing_catalog_key, path}}
    end
  end

  defp known_keys(%{} = m, allowed, path) do
    case Map.keys(m) -- allowed do
      [] -> :ok
      _ -> {:error, {:unknown_key, path}}
    end
  end

  defp known_keys(_, _, path), do: {:error, {:bad_layout, path}}

  defp check(true, _reason, _path), do: :ok
  defp check(_, reason, path), do: {:error, {reason, path}}

  # -- resolve ----------------------------------------------------------------------------------

  @doc """
  The document model both renderers read: a list of `{:text, s}`, `{:title, s}`, `{:field, label,
  value}` (value `""` = blank line), `{:signature, label, value_parts, captions}`, `{:proxy, s}`,
  `{:table, %{columns, rows, total}}` and, last, `{:notice, s}` when a kk draft label was used.
  """
  @spec resolve(map(), map(), String.t(), map()) :: [tuple()]
  def resolve(layout, data, lang, catalog) when lang in @langs do
    items = Enum.map(layout["blocks"], &item(&1, data, lang, catalog))

    if lang == "kk" and Enum.any?(layout["blocks"], &draft?(&1, catalog)),
      do: items ++ [{:notice, text(catalog, "draft_notice", lang)}],
      else: items
  end

  defp item(%{"type" => "text"} = b, _d, lang, c), do: {:text, text(c, b["label"], lang)}
  defp item(%{"type" => "title"} = b, _d, lang, c), do: {:title, text(c, b["label"], lang)}
  defp item(%{"type" => "proxy"} = b, _d, lang, c), do: {:proxy, text(c, b["label"], lang)}

  defp item(%{"type" => "field"} = b, d, lang, c),
    do: {:field, text(c, b["label"], lang), value(d, b["key"])}

  defp item(%{"type" => "signature"} = b, d, lang, c) do
    parts = b["parts"]
    name = value(d, b["key"])
    position = value(d, b["key"] <> "_position")

    values =
      Enum.map(parts, fn
        "name" -> name
        "position" -> position
        _ -> ""
      end)

    captions = Enum.map(parts, &text(c, "cap." <> &1, lang))
    stamp = if b["stamp"], do: text(c, b["stamp"], lang)
    {:signature, text(c, b["label"], lang), values, captions, stamp}
  end

  defp item(%{"type" => "table"} = b, d, lang, c) do
    rows =
      case d[b["rows"]] do
        l when is_list(l) -> l |> Enum.filter(&is_map/1) |> Enum.map(&clean_row(&1, b["columns"]))
        _ -> []
      end

    columns =
      b["columns"]
      |> Enum.with_index(1)
      |> Enum.map(fn {col, i} ->
        %{
          key: col["key"],
          no: col["no"] || i,
          label: text(c, col["label"], lang),
          group: col["group"] && text(c, col["group"], lang)
        }
      end)

    {:table,
     %{columns: columns, rows: rows, total: total(b["totals"], b["columns"], rows, lang, c)}}
  end

  defp clean_row(row, columns),
    do: Map.new(columns, fn col -> {col["key"], clean(row[col["key"]])} end)

  defp total(nil, _cols, _rows, _lang, _c), do: nil

  defp total(t, columns, rows, lang, c) do
    sums = t["sum"] || []
    marks = t["mark"] || []
    skip_blank = t["skip_blank"] == true

    cells =
      Map.new(columns, fn col ->
        k = col["key"]

        v =
          cond do
            k in sums -> sum(rows, k, skip_blank)
            k in marks -> "x"
            true -> ""
          end

        {k, v}
      end)

    label_col = (Enum.at(columns, 1) || hd(columns))["key"]
    Map.put(cells, label_col, text(c, t["label"], lang))
  end

  # `skip_blank`: a blank cell adds nothing (a line holds a surplus or a shortage, not both); a
  # non-blank invalid text still blanks the total; no non-blank cell at all gives a blank total.
  defp sum(rows, key, skip_blank) do
    rows = if skip_blank, do: Enum.reject(rows, &((&1[key] || "") == "")), else: rows

    case rows do
      [] -> ""
      _ -> sum_rows(rows, key)
    end
  end

  defp sum_rows(rows, key) do
    Enum.reduce_while(rows, Decimal.new(0), fn row, acc ->
      case Decimal.parse(row[key] || "") do
        {%Decimal{} = d, ""} -> {:cont, Decimal.add(acc, d)}
        _ -> {:halt, :invalid}
      end
    end)
    |> case do
      %Decimal{} = d -> Decimal.to_string(d, :normal)
      _ -> ""
    end
  end

  defp draft?(%{"label" => l} = b, c),
    do: draft_key?(l, c) or draft_key?(b["stamp"], c) or columns_draft?(b, c)

  defp draft?(b, c), do: columns_draft?(b, c)

  defp columns_draft?(%{"columns" => cols} = b, c) when is_list(cols) do
    Enum.any?(cols, &(draft_key?(&1["label"], c) or draft_key?(&1["group"], c))) or
      draft_key?(get_in(b, ["totals", "label"]), c)
  end

  defp columns_draft?(_, _), do: false

  defp draft_key?(nil, _c), do: false
  defp draft_key?(key, c), do: get_in(c, [key, "kk_status"]) == "machine_draft"

  defp text(catalog, key, lang), do: catalog |> Map.fetch!(key) |> Map.fetch!(lang)

  defp value(data, key), do: clean(data[key])

  @doc """
  The one cleaning of a data value: text only, XML-illegal characters dropped, line breaks and
  tabs as spaces, at most #{@max_text} characters.
  """
  @spec clean(term()) :: String.t()
  def clean(nil), do: ""

  def clean(v) when is_binary(v) do
    if String.valid?(v) do
      v
      |> String.replace(~r/[\r\n\t]+/u, " ")
      |> String.to_charlist()
      |> Enum.filter(&xml_char?/1)
      |> List.to_string()
      |> String.slice(0, @max_text)
    else
      ""
    end
  end

  def clean(v) when is_integer(v), do: Integer.to_string(v)
  def clean(_), do: ""

  defp xml_char?(c),
    do: c in [0x9, 0xA, 0xD] or c in 0x20..0xD7FF or c in 0xE000..0xFFFD or c in 0x10000..0x10FFFF

  @doc """
  Builds the output of `form` for `data`. `format` is `:pdf` or `:docx`, `lang` `\"ru\"` or
  `\"kk\"`. Options (test seam): `:layout` and `:catalog` replace the shipped ones.
  """
  @spec build(String.t(), map(), String.t(), format(), keyword()) ::
          {:ok, binary()}
          | {:error,
             :unknown_form | :lang_not_supported | :unsupported_glyph | {:render_failed, [atom()]}}
  def build(form, data, lang, format, opts \\ []) when format in [:pdf, :docx] do
    catalog = Keyword.get(opts, :catalog, @catalog)

    with {:lang, true} <- {:lang, lang in @langs},
         {:ok, layout} <- fetch_layout(form, opts) do
      model = resolve(layout, data, lang, catalog)

      case format do
        :pdf -> Pdf.render(model)
        :docx -> Docx.render(model)
      end
    else
      {:lang, false} -> {:error, :lang_not_supported}
      :error -> {:error, :unknown_form}
    end
  end

  defp fetch_layout(form, opts) do
    case Keyword.fetch(opts, :layout) do
      {:ok, layout} -> {:ok, layout}
      :error -> layout(form)
    end
  end
end
