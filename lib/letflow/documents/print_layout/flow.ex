defmodule Letflow.Documents.PrintLayout.Flow do
  @moduledoc """
  Lays out the blocks of a validated print layout into pages of positioned text items and rules
  (REQ-571, decision 0068 D8 S1). Pure: integers only, unit `u` = 1/100 point, font size 10 pt
  (so a glyph is as wide in `u` as its 1/1000-em advance).

  Reads from the projection only the pairs the layout names (`projection[entity_type][field]`
  and, for tables, `row[field]`); never iterates a whole projection map or row. Every failure is
  a violation `%{rule, path}`; a value, a code point or a count is never part of one.

  Text recovery rule: one item (text block, field, header cell, data cell) is one `BT`/`ET`
  group; its lines are runs; the break space is drawn at the end of its line; a hard break adds
  nothing; the paragraph newline is not drawn.
  """

  alias Letflow.Documents.PrintLayout.Font

  @line_h 1200
  @gap 200
  @pad 200
  @sizes %{
    "A4" => {59_500, 84_200},
    "A4-landscape" => {84_200, 59_500},
    "Letter" => {61_200, 79_200}
  }
  # A table up to this many data rows is kept whole on one page when it fits a page.
  @small_table_rows 3

  @type violation :: %{rule: atom, path: list}

  @doc "Page size in `u` for a validated size name."
  def page_size(name), do: Map.fetch!(@sizes, name)

  @doc "Layout of a validated layout. `{:ok, doc}` with `pages`, `cps` and `size`, or violations."
  @spec run(map, map) :: {:ok, map} | {:error, [violation]}
  def run(%{"blocks" => [page | blocks]}, projection) do
    {pw, ph} = page_size(page["size"])
    m = mm_to_u(page["margin_mm"])

    st = %{
      ph: ph,
      m: m,
      cw: pw - 2 * m,
      ch: ph - 2 * m,
      pages: [],
      ops: [],
      used: 0,
      cps: MapSet.new(),
      vs: []
    }

    indexed = Enum.with_index(blocks, 1)
    nexts = Enum.drop(blocks, 1) ++ [nil]

    st =
      indexed
      |> Enum.zip(nexts)
      |> Enum.reduce(st, fn {{block, i}, next}, st -> block(block, i, projection, st, next) end)

    case st.vs do
      [] ->
        pages = Enum.reverse([Enum.reverse(st.ops) | st.pages])
        {:ok, %{pages: pages, cps: Enum.sort(st.cps), size: {pw, ph}, margin: m}}

      vs ->
        {:error, vs |> Enum.uniq() |> Enum.sort_by(& &1.path)}
    end
  end

  defp mm_to_u(mm), do: round(mm * 7200 / 25.4)

  # -- blocks ----------------------------------------------------------------------------------

  # A text block directly before a table is kept with the start of that table (rule a).
  defp block(%{"type" => "text", "text" => text}, i, proj, st, next) do
    case prepare(text, ["blocks", i, "text"]) do
      {:ok, cps} -> flow_item(keep_with_table(st, cps, i, proj, next), cps)
      {:error, v} -> violate(st, v)
    end
  end

  defp block(%{"type" => "spacer", "height_mm" => mm}, _i, _proj, st, _next) do
    used = st.used + mm_to_u(mm)
    if used > st.ch, do: %{new_page(st) | used: 0}, else: %{st | used: used}
  end

  defp block(%{"type" => "field"} = b, i, proj, st, _next) do
    path = ["blocks", i]

    case read_field(proj, b["entity_type"], b["field_name"]) do
      :invalid ->
        violate(st, v(:invalid_projection, path))

      {:ok, raw} ->
        with {:ok, value} <- to_text(raw, path ++ ["field_name"]) do
          field(st, b, value, path)
        else
          {:error, v} -> violate(st, v)
        end
    end
  end

  defp block(%{"type" => "table"} = b, i, proj, st, _next) do
    path = ["blocks", i]

    case read_rows(proj, b["entity_type"]) do
      :invalid -> violate(st, v(:invalid_projection, path))
      {:ok, rows} -> table(st, b, rows, path)
    end
  end

  defp block(_other, _i, _proj, st, _next), do: st

  defp keep_with_table(st, cps, i, proj, %{"type" => "table"} = tb) do
    with {:ok, rows} <- read_rows(proj, tb["entity_type"]),
         {:ok, need} <- table_need(st, tb, rows, ["blocks", i + 1]) do
      text_h = length(wrap(cps, st.cw)) * @line_h + @gap

      if text_h + need <= st.ch and st.used + text_h + need > st.ch and st.used > 0,
        do: new_page(st),
        else: st
    else
      _ -> st
    end
  end

  defp keep_with_table(st, _cps, _i, _proj, _next), do: st

  defp field(st, b, value, path) do
    if b["show_if_nonempty"] == true and String.trim(value) == "" do
      st
    else
      with {:ok, label} <- label_cps(b["label"], path ++ ["label"]),
           {:ok, val} <- prepare(value, path ++ ["field_name"]) do
        flow_item(st, label ++ val)
      else
        {:error, v} -> violate(st, v)
      end
    end
  end

  defp label_cps(nil, _path), do: {:ok, []}

  defp label_cps(label, path) do
    with {:ok, cps} <- prepare(label <> ": ", path), do: {:ok, cps}
  end

  # -- projection reads (named pairs only) -----------------------------------------------------

  defp read_field(proj, et, fname) do
    case Map.fetch(proj, et) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, ent} when is_map(ent) -> {:ok, Map.get(ent, fname)}
      {:ok, _} -> :invalid
    end
  end

  defp read_rows(proj, et) do
    case Map.fetch(proj, et) do
      :error ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, rows} when is_list(rows) ->
        if Enum.all?(rows, &is_map/1), do: {:ok, rows}, else: :invalid

      {:ok, _} ->
        :invalid
    end
  end

  defp to_text(bin, path) when is_binary(bin) do
    if String.valid?(bin), do: {:ok, bin}, else: {:error, v(:unrenderable_value, path)}
  end

  defp to_text(nil, _path), do: {:ok, ""}
  defp to_text(v, _path) when is_integer(v), do: {:ok, Integer.to_string(v)}
  defp to_text(v, _path) when is_float(v), do: {:ok, Float.to_string(v)}
  defp to_text(v, _path) when is_boolean(v), do: {:ok, Atom.to_string(v)}
  defp to_text(%Decimal{} = d, _path), do: {:ok, Decimal.to_string(d, :normal)}
  defp to_text(_v, path), do: {:error, v(:unrenderable_value, path)}

  # -- text ------------------------------------------------------------------------------------

  # Code points of a string, or the :unsupported_glyph violation (no value in it).
  defp prepare(text, path) do
    cps = text |> String.replace("\r\n", "\n") |> String.to_charlist()

    if Enum.all?(cps, &drawable?/1),
      do: {:ok, cps},
      else: {:error, v(:unsupported_glyph, path)}
  end

  defp drawable?(10), do: true
  defp drawable?(cp) when cp < 0x20 or cp in 0x7F..0x9F, do: false
  defp drawable?(cp), do: Font.glyph_id(cp) != nil

  defp width(cps), do: Enum.reduce(cps, 0, &(width1(&1) + &2))
  defp width1(cp), do: Font.advance(Font.glyph_id(cp))

  @doc """
  Greedy wrap of code points into lines of at most `inner_w` units. Every line takes at least one
  glyph whatever `inner_w` is (zero or negative included), so it ends in O(n); stops once more
  than `limit` lines exist. Break spaces stay at the end of their line; a hard break adds nothing.
  """
  @spec wrap([non_neg_integer], integer, non_neg_integer | :infinity) :: [[non_neg_integer]]
  def wrap(cps, inner_w, limit \\ :infinity) do
    cps
    |> paragraphs([], [])
    |> Enum.reduce_while({[], 0}, fn par, {acc, n} ->
      remaining = if limit == :infinity, do: :infinity, else: limit - n
      lines = wrap_par(par, inner_w, remaining)
      n = n + length(lines)
      acc = Enum.reverse(lines, acc)
      if n > limit, do: {:halt, {acc, n}}, else: {:cont, {acc, n}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp paragraphs([], cur, acc), do: Enum.reverse([Enum.reverse(cur) | acc])
  defp paragraphs([10 | t], cur, acc), do: paragraphs(t, [], [Enum.reverse(cur) | acc])
  defp paragraphs([c | t], cur, acc), do: paragraphs(t, [c | cur], acc)

  defp wrap_par(par, inner_w, limit) do
    st = place_tokens(tokens(par, []), inner_w, limit, %{lines: [], n: 0, cur: [], w: 0})
    st = flush(st)
    Enum.reverse(st.lines)
  end

  defp tokens([], acc), do: Enum.reverse(acc)

  defp tokens(cps, acc) do
    {word, rest} = Enum.split_while(cps, &(&1 != 32))
    {spaces, rest} = Enum.split_while(rest, &(&1 == 32))
    tokens(rest, [{word, spaces} | acc])
  end

  defp place_tokens([], _w, _limit, st), do: st
  defp place_tokens(_tokens, _w, limit, %{n: n} = st) when n > limit, do: st

  defp place_tokens([{word, spaces} | rest], inner_w, limit, st) do
    ww = width(word)

    st =
      if st.w + ww <= inner_w do
        add(st, word, ww)
      else
        st = if st.cur == [], do: st, else: flush(st)

        if ww <= inner_w,
          do: add(st, word, ww),
          else: hard_break(word, inner_w, limit, st)
      end

    place_tokens(rest, inner_w, limit, add(st, spaces, width(spaces)))
  end

  defp hard_break([], _inner_w, _limit, st), do: st
  defp hard_break(_word, _inner_w, limit, %{n: n} = st) when n > limit, do: st

  defp hard_break([cp | rest], inner_w, limit, st) do
    w = width1(cp)
    st = if st.cur != [] and st.w + w > inner_w, do: flush(st), else: st
    hard_break(rest, inner_w, limit, add(st, [cp], w))
  end

  defp add(st, cps, w), do: %{st | cur: Enum.reverse(cps, st.cur), w: st.w + w}

  defp flush(st) do
    %{st | lines: [Enum.reverse(st.cur) | st.lines], n: st.n + 1, cur: [], w: 0}
  end

  # A text/field item over the whole content width; lines flow across pages.
  defp flow_item(st, cps) do
    st = mark_used(st, cps)
    lines = wrap(cps, st.cw, :infinity)

    {st, group} =
      Enum.reduce(lines, {st, []}, fn line, {st, group} ->
        {st, group} =
          if st.used + @line_h > st.ch and st.used > 0,
            do: {new_page(emit(st, group)), []},
            else: {st, group}

        group = if line == [], do: group, else: [{st.m, baseline(st, st.used), line} | group]
        {%{st | used: st.used + @line_h}, group}
      end)

    st = emit(st, group)
    %{st | used: st.used + @gap}
  end

  defp emit(st, []), do: st
  defp emit(st, group), do: %{st | ops: [{:item, Enum.reverse(group)} | st.ops]}

  defp baseline(st, used), do: st.ph - st.m - used - 1000

  defp new_page(st), do: %{st | pages: [Enum.reverse(st.ops) | st.pages], ops: [], used: 0}

  defp mark_used(st, cps) do
    %{st | cps: cps |> Enum.reject(&(&1 == 10)) |> Enum.reduce(st.cps, &MapSet.put(&2, &1))}
  end

  # -- tables ----------------------------------------------------------------------------------

  defp table(st, b, rows, path) do
    {geo, header, cols} = table_geo(st, b, path)
    rep = repeat_header(st, geo, header)

    st =
      case table_need(st, b, rows, path) do
        {:ok, need} when need <= st.ch ->
          if st.used + need > st.ch and st.used > 0, do: new_page(st), else: st

        _ ->
          st
      end

    st = row(st, geo, header, path)

    Enum.reduce(rows, st, fn r, st -> row(st, geo, data_cells(r, cols, geo, path), path, rep) end)
  end

  # Geometry (column x/width/index), header cells and columns of a table block.
  defp table_geo(st, b, path) do
    cols = b["columns"]
    weights = Enum.map(cols, &max(1, round(Map.get(&1, "width", 1) * 1000)))
    total = Enum.sum(weights)
    widths = Enum.map(weights, &div(st.cw * &1, total))

    header =
      for {col, j} <- Enum.with_index(cols) do
        prepare(Map.get(col, "header", ""), path ++ ["columns", j, "header"])
      end

    widths = fit_header_words(widths, header, st.cw)
    {xs, _} = Enum.map_reduce(widths, st.m, fn w, x -> {x, x + w} end)
    {Enum.zip([xs, widths, 0..(length(cols) - 1)]), header, cols}
  end

  defp data_cells(r, cols, geo, path) do
    for {{_x, _w, j}, col} <- Enum.zip(geo, cols) do
      vpath = path ++ ["columns", j, "field_name"]

      with {:ok, text} <- to_text(Map.get(r, col["field_name"]), vpath),
           do: prepare(text, vpath)
    end
  end

  # No header word is broken in the middle while every column can hold its longest word.
  defp fit_header_words(widths, header, cw) do
    mins =
      for h <- header do
        case h do
          {:ok, cps} -> longest_word(cps) + 2 * @pad
          _ -> 0
        end
      end

    if Enum.sum(mins) > cw do
      widths
    else
      w1 = Enum.zip_with(widths, mins, &max/2)
      surplus = max(0, Enum.sum(w1) - cw)
      excess = Enum.zip_with(w1, mins, &-/2)
      total_excess = Enum.sum(excess)

      if surplus == 0 or total_excess == 0 do
        w1
      else
        take = Enum.map(excess, &div(surplus * &1, total_excess))
        w2 = Enum.zip_with(w1, take, &-/2)
        take_rest(w2, mins, surplus - Enum.sum(take))
      end
    end
  end

  defp take_rest(ws, _mins, 0), do: ws

  defp take_rest(ws, mins, n) do
    room = Enum.zip_with(ws, mins, &-/2)
    {best, idx} = room |> Enum.with_index() |> Enum.max_by(&elem(&1, 0), fn a, b -> a >= b end)

    if best <= 0,
      do: ws,
      else: take_rest(List.update_at(ws, idx, &(&1 - 1)), mins, n - 1)
  end

  defp longest_word(cps) do
    cps
    |> Enum.chunk_by(&(&1 in [32, 10]))
    |> Enum.reject(&(hd(&1) in [32, 10]))
    |> Enum.map(&width/1)
    |> Enum.max(fn -> 0 end)
  end

  # Header repeated on each new page of the table; nil when a header cell is not drawable.
  defp repeat_header(st, geo, header) do
    if Enum.all?(header, &match?({:ok, _}, &1)) do
      cps = Enum.map(header, &elem(&1, 1))
      wrapped = wrap_cells(geo, cps, max_lines_for(st.ch))
      %{wrapped: wrapped, h: row_h(wrapped)}
    end
  end

  # Space needed to start a table: whole table when small, else header and first row.
  defp table_need(st, b, rows, path) do
    {geo, header, cols} = table_geo(st, b, path)
    max_lines = max_lines_for(st.ch)
    first = Enum.take(rows, @small_table_rows + 1)
    cells = Enum.map(first, &data_cells(&1, cols, geo, path))
    all = [header | cells]

    if Enum.all?(all, fn r -> Enum.all?(r, &match?({:ok, _}, &1)) end) do
      hs =
        for r <- all do
          wrapped = wrap_cells(geo, Enum.map(r, &elem(&1, 1)), max_lines)
          if Enum.any?(wrapped, &(length(&1) > max_lines)), do: :tall, else: row_h(wrapped)
        end

      if :tall in hs do
        :skip
      else
        [hdr | data] = hs

        {:ok,
         if(length(rows) <= @small_table_rows, do: hdr + Enum.sum(data), else: hdr + hd(data))}
      end
    else
      :skip
    end
  end

  defp max_lines_for(avail), do: max(1, div(avail - 2 * @pad, @line_h))

  defp wrap_cells(geo, cell_cps, max_lines) do
    for {{_x, w, _j}, cps} <- Enum.zip(geo, cell_cps),
        do: wrap(cps, w - 2 * @pad, max_lines + 1)
  end

  defp row_h(wrapped),
    do: wrapped |> Enum.map(&length/1) |> Enum.max() |> Kernel.*(@line_h) |> Kernel.+(2 * @pad)

  defp row(st, geo, cells, path, rep \\ nil) do
    case for({:error, v} <- cells, do: v) do
      [] -> place_row(st, geo, Enum.map(cells, &elem(&1, 1)), path, rep)
      vs -> Enum.reduce(vs, st, &violate(&2, &1))
    end
  end

  defp place_row(st, geo, cell_cps, path, rep) do
    avail = if rep, do: st.ch - rep.h, else: st.ch
    max_lines = max_lines_for(avail)
    st = Enum.reduce(cell_cps, st, &mark_used(&2, &1))
    wrapped = wrap_cells(geo, cell_cps, max_lines)

    if Enum.any?(wrapped, &(length(&1) > max_lines)) or (rep && rep.h + row_h(wrapped) > st.ch) do
      violate(st, v(:row_too_tall, path))
    else
      h = row_h(wrapped)

      st =
        if st.used + h > st.ch and st.used > 0 do
          st = new_page(st)
          if rep, do: draw_row(st, geo, rep.wrapped, rep.h), else: st
        else
          st
        end

      draw_row(st, geo, wrapped, h)
    end
  end

  defp draw_row(st, geo, wrapped, h) do
    top = st.used + @pad

    ops =
      for {{x, _w, _j}, lines} <- Enum.zip(geo, wrapped), lines != [] do
        items =
          for {line, k} <- Enum.with_index(lines), line != [] do
            {x + @pad, baseline(st, top + k * @line_h), line}
          end

        {:item, items}
      end

    ops = Enum.reject(ops, &match?({:item, []}, &1))
    x_end = geo |> List.last() |> then(fn {x, w, _} -> x + w end)
    x_start = geo |> hd() |> elem(0)
    rule = {:rule, x_start, x_end, st.ph - st.m - st.used - h}
    %{st | ops: [rule | Enum.reverse(ops, st.ops)], used: st.used + h}
  end

  # -- violations ------------------------------------------------------------------------------

  defp v(rule, path), do: %{rule: rule, path: path}
  defp violate(st, v), do: %{st | vs: [v | st.vs]}
end
