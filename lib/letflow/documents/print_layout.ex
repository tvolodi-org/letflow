defmodule Letflow.Documents.PrintLayout do
  @moduledoc """
  Closed, declarative print layout and its validator (REQ-571 / GH #3250, decision 0068 D8 S1,
  part 1: layout-level limits only).

  A layout is decoded JSON (string keys):

      %{"layout_schema_version" => 1,
        "blocks" => [%{"type" => "page", ...}, %{"type" => "text" | "field" | "table" | "spacer", ...}]}

  The page block comes exactly once, first. There is no image block and no key that carries a
  link, script or expression: any key outside the allow-list of its map is `:unknown_key`.
  The layout is data and is never evaluated; no atom is created from it.

  `validate/3` is the projection boundary: a field or column must be declared in
  `declared_fields` (`%{entity_type => [field_name]}`), must not be in `opts.restricted`, and
  every pair of `opts.locked` must be referenced by a field block (table columns do not count).

  A violation is `%{rule: atom, path: [String.t() | non_neg_integer]}` and never carries a
  value, literal text or field name. The only layout text in a path is the name of an unknown
  key (at most 64 bytes). Row limits belong to the renderer, not to this module.

  ## Renderer (part 2)

  `render/4` is a pure function of `(layout, projection, declared_fields, opts)`: it runs
  `validate/3` first and returns `{:error, violations}` unchanged on failure, else
  `{:ok, pdf_binary}`. It reads no database, clock, environment or network, and reads from the
  projection only the declared, unrestricted pairs the layout names. A table has at most 1000
  rows (`:too_many_rows`). A character the font has no glyph for gives `:unsupported_glyph`; it
  is never replaced by `?` or drawn as an empty box. A violation carries a rule and a path,
  never a value.

  This module is the first renderer with a Unicode font path. The PDF is written by hand
  (`Font`, `Flow`, `Pdf` under `print_layout/`): Type0, CIDFontType2, Identity-H, a CIDToGIDMap
  stream, a W array and a ToUnicode CMap, with the whole of `priv/fonts/DejaVuSans.ttf`
  embedded (licence: `priv/fonts/DejaVuSans.LICENSE`). Decision 0068 D2 (closed schema, text and
  vector shapes only) and 0068 D5 (no restricted or undeclared field in the output) bound it;
  0068 Q2 (how much flexibility the tenant gets) and Q5 (core-locked blocks) are the owner's
  open questions and are not decided here. Decision 0033, whose ISS-0679 addendum was
  re-opened by an amendment for this font path, keeps `certificate_document.ex` on the `pdf`
  library and its Latin-1 path; that file is unchanged.

  The output has no `/Info`, no date, no producer and no action, annotation, form or embedded
  file object. Equal inputs give equal bytes (compressed bytes are stable per OTP/zlib build).
  """

  alias Letflow.Documents.PrintLayout.{Flow, Pdf}

  @type violation :: %{rule: atom, path: [String.t() | non_neg_integer]}

  @max_rows 1000
  @max_blocks 200
  @max_literal 500
  @max_columns 12
  @version 1
  @font "dejavu-sans"
  @sizes ["A4", "Letter"]
  @types ["page", "text", "field", "table", "spacer"]

  @layout_keys ["layout_schema_version", "blocks"]
  @allowed %{
    "page" => ["type", "size", "margin_mm", "font"],
    "text" => ["type", "text"],
    "field" => ["type", "entity_type", "field_name", "label", "show_if_nonempty"],
    "table" => ["type", "entity_type", "columns"],
    "spacer" => ["type", "height_mm"]
  }
  @required %{
    "page" => ["size", "margin_mm", "font"],
    "text" => ["text"],
    "field" => ["entity_type", "field_name"],
    "table" => ["entity_type", "columns"],
    "spacer" => ["height_mm"]
  }
  @column_keys ["field_name", "header", "width"]

  @doc """
  Validates `layout` against the closed schema and the projection. Returns `:ok` or
  `{:error, violations}`; never raises on a malformed input.
  """
  @spec validate(term, term, keyword | map) :: :ok | {:error, [violation]}
  def validate(layout, declared_fields, opts \\ [])

  def validate(layout, declared_fields, opts) when is_map(layout) do
    ctx = %{
      declared: declared_pairs(declared_fields),
      restricted: MapSet.new(pairs(opt(opts, :restricted))),
      locked: pairs(opt(opts, :locked))
    }

    violations =
      check_keys(layout, @layout_keys, []) ++ check_version(layout) ++ check_blocks(layout, ctx)

    if violations == [], do: :ok, else: {:error, violations}
  end

  def validate(_layout, _declared_fields, _opts), do: {:error, [v(:invalid_layout, [])]}

  @doc """
  Renders `layout` over `projection` (`%{entity_type => %{field => value}}` for field blocks,
  `%{entity_type => [row]}` for tables) into PDF bytes. Validates first (same violations, same
  order); a projection that is not a map is `:invalid_projection` at `[]`; more than 1000 rows
  in a table is `:too_many_rows` at the table block. Never raises on runtime input.
  """
  @spec render(term, term, term, keyword | map) :: {:ok, binary} | {:error, [violation]}
  def render(layout, projection, declared_fields, opts \\ []) do
    with :ok <- validate(layout, declared_fields, opts),
         :ok <- check_projection(layout, projection),
         {:ok, doc} <- Flow.run(layout, projection) do
      {:ok, Pdf.build(doc)}
    end
  end

  defp check_projection(_layout, projection) when not is_map(projection),
    do: {:error, [v(:invalid_projection, [])]}

  defp check_projection(%{"blocks" => blocks}, projection) do
    vs =
      for {%{"type" => "table", "entity_type" => et}, i} <- Enum.with_index(blocks),
          is_list(projection[et]),
          length(projection[et]) > @max_rows,
          do: v(:too_many_rows, ["blocks", i])

    if vs == [], do: :ok, else: {:error, vs}
  end

  # -- layout level ----------------------------------------------------------------------------

  defp check_version(%{"layout_schema_version" => @version}), do: []
  defp check_version(_), do: [v(:unsupported_version, ["layout_schema_version"])]

  defp check_blocks(%{"blocks" => blocks}, ctx) when is_list(blocks) do
    if length(blocks) > @max_blocks do
      [v(:too_many_blocks, ["blocks"])]
    else
      indexed = Enum.with_index(blocks)

      Enum.flat_map(indexed, fn {block, i} -> check_block(block, ["blocks", i], ctx) end) ++
        check_pages(indexed) ++ check_locked(blocks, ctx)
    end
  end

  defp check_blocks(_layout, _ctx), do: [v(:invalid_blocks, ["blocks"])]

  defp check_pages(indexed) do
    pages = for {%{"type" => "page"}, i} <- indexed, do: i

    case pages do
      [] ->
        [v(:missing_page, ["blocks"])]

      [first | rest] ->
        first_v = if first > 0, do: [v(:page_not_first, ["blocks", first])], else: []
        first_v ++ Enum.map(rest, &v(:repeated_page, ["blocks", &1]))
    end
  end

  defp check_locked(blocks, ctx) do
    referenced =
      for %{"type" => "field", "entity_type" => et, "field_name" => fname} <- blocks,
          is_binary(et),
          is_binary(fname),
          into: MapSet.new(),
          do: {et, fname}

    for pair <- ctx.locked,
        not MapSet.member?(referenced, pair),
        do: v(:locked_field_missing, ["blocks"])
  end

  # -- blocks ----------------------------------------------------------------------------------

  defp check_block(block, path, ctx) when is_map(block) do
    case Map.get(block, "type") do
      type when type in @types ->
        check_keys(block, Map.fetch!(@allowed, type), path) ++
          check_required(block, Map.fetch!(@required, type), path) ++
          check_type(type, block, path, ctx)

      _ ->
        [v(:unknown_block_type, path ++ ["type"])]
    end
  end

  defp check_block(_block, path, _ctx), do: [v(:invalid_block, path)]

  defp check_type("page", block, path, _ctx) do
    size = field_check(block, "size", path, &(&1 in @sizes))
    margin = field_check(block, "margin_mm", path, &in_range?(&1, 0, 50, true))
    font = font_check(block, path)
    size ++ margin ++ font
  end

  defp check_type("text", block, path, _ctx), do: literal(block, "text", path)

  defp check_type("spacer", block, path, _ctx) do
    field_check(block, "height_mm", path, &in_range?(&1, 0, 200, false))
  end

  defp check_type("field", block, path, ctx) do
    et = text(block, "entity_type", path)
    fname = text(block, "field_name", path)
    label = if Map.has_key?(block, "label"), do: literal(block, "label", path), else: []

    flag =
      if Map.has_key?(block, "show_if_nonempty"),
        do: field_check(block, "show_if_nonempty", path, &(&1 == true)),
        else: []

    et ++
      fname ++
      label ++
      flag ++ projection(block["entity_type"], block["field_name"], path ++ ["field_name"], ctx)
  end

  defp check_type("table", block, path, ctx) do
    et = text(block, "entity_type", path)

    cols =
      case Map.fetch(block, "columns") do
        :error ->
          []

        {:ok, [_ | _] = columns} ->
          check_columns(columns, block["entity_type"], path ++ ["columns"], ctx)

        {:ok, _} ->
          [v(:invalid_value, path ++ ["columns"])]
      end

    et ++ cols
  end

  defp check_columns(columns, _et, path, _ctx) when length(columns) > @max_columns do
    [v(:too_many_columns, path)]
  end

  defp check_columns(columns, et, path, ctx) do
    columns
    |> Enum.with_index()
    |> Enum.flat_map(fn {col, j} -> check_column(col, et, path ++ [j], ctx) end)
  end

  defp check_column(col, et, path, ctx) when is_map(col) do
    header = if Map.has_key?(col, "header"), do: literal(col, "header", path), else: []

    check_keys(col, @column_keys, path) ++
      check_required(col, @column_keys, path) ++
      text(col, "field_name", path) ++
      header ++
      field_check(col, "width", path, &in_range?(&1, 0, 1000, false)) ++
      projection(et, col["field_name"], path ++ ["field_name"], ctx)
  end

  defp check_column(_col, _et, path, _ctx), do: [v(:invalid_block, path)]

  # -- projection ------------------------------------------------------------------------------

  defp projection(et, fname, path, ctx) when is_binary(et) and is_binary(fname) do
    pair = {et, fname}

    cond do
      MapSet.member?(ctx.restricted, pair) -> [v(:field_restricted, path)]
      not MapSet.member?(ctx.declared, pair) -> [v(:field_not_projected, path)]
      true -> []
    end
  end

  defp projection(_et, _fname, _path, _ctx), do: []

  # -- helpers ---------------------------------------------------------------------------------

  # Unknown keys: the key name goes into the path only when it is a short binary.
  defp check_keys(map, allowed, path) do
    for key <- Map.keys(map), key not in allowed do
      v(:unknown_key, if(is_binary(key) and byte_size(key) <= 64, do: path ++ [key], else: path))
    end
  end

  defp check_required(map, required, path) do
    for key <- required, not Map.has_key?(map, key), do: v(:missing_key, path ++ [key])
  end

  # Present key must satisfy the predicate, otherwise :invalid_value (absent is :missing_key).
  defp field_check(map, key, path, pred) do
    case Map.fetch(map, key) do
      {:ok, value} -> if pred.(value), do: [], else: [v(:invalid_value, path ++ [key])]
      :error -> []
    end
  end

  defp text(map, key, path), do: field_check(map, key, path, &valid_string?/1)

  defp literal(map, key, path) do
    case Map.fetch(map, key) do
      :error ->
        []

      {:ok, value} ->
        cond do
          not valid_string?(value) -> [v(:invalid_value, path ++ [key])]
          String.length(value) > @max_literal -> [v(:literal_too_long, path ++ [key])]
          true -> []
        end
    end
  end

  defp font_check(block, path) do
    case Map.fetch(block, "font") do
      {:ok, @font} ->
        []

      {:ok, f} when is_binary(f) ->
        if String.valid?(f),
          do: [v(:unsupported_font, path ++ ["font"])],
          else: [v(:invalid_value, path ++ ["font"])]

      {:ok, _} ->
        [v(:invalid_value, path ++ ["font"])]

      :error ->
        []
    end
  end

  defp valid_string?(value), do: is_binary(value) and String.valid?(value)

  defp in_range?(n, lo, hi, lo_inclusive) when is_number(n) do
    n <= hi and (n > lo or (lo_inclusive and n == lo))
  end

  defp in_range?(_, _, _, _), do: false

  defp v(rule, path), do: %{rule: rule, path: path}

  defp opt(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key, []), else: []
  end

  defp opt(opts, key) when is_map(opts), do: Map.get(opts, key, [])
  defp opt(_opts, _key), do: []

  defp pairs(list) when is_list(list),
    do: for({a, b} <- list, is_binary(a), is_binary(b), do: {a, b})

  defp pairs(_), do: []

  defp declared_pairs(declared) when is_map(declared) do
    for {et, fields} <- declared,
        is_binary(et),
        is_list(fields),
        f <- fields,
        is_binary(f),
        into: MapSet.new() do
      {et, f}
    end
  end

  defp declared_pairs(_), do: MapSet.new()
end
