defmodule Letflow.Documents.FormTemplate.RunJoin do
  @moduledoc false
  alias Letflow.Documents.FormTemplate, as: F
  alias F.Xml
  @placeholder ~r/\{\{([a-z0-9_.]{1,64})\}\}/
  @markers ~w(w:proofErr w:bookmarkStart w:bookmarkEnd w:permStart w:permEnd)
  @bar "\uFFFC"

  def run(parts) do
    Enum.reduce_while(Enum.sort(parts), {:ok, %{}, []}, fn {part, tree}, {:ok, acc, all} ->
      if is_binary(tree) do
        {:cont, {:ok, Map.put(acc, part, tree), all}}
      else
        state = %{paragraph: 0, table: 0, occurrences: [], plain_count: 0, error: nil}

        {joined, state} =
          walk(tree, %{part: part, blocked: part != "word/document.xml", cell: nil}, state)

        total = tree |> Xml.named("w:t") |> Enum.map(&Xml.text/1) |> Enum.join() |> count_open()

        cond do
          state.error ->
            {:halt, state.error}

          total != state.plain_count ->
            {:halt, F.error(:placeholder_not_plain, "D4", %{part: place_part(part)})}

          true ->
            {:cont, {:ok, Map.put(acc, part, joined), all ++ Enum.reverse(state.occurrences)}}
        end
      end
    end)
  end

  defp place_part(n) do
    cond do
      String.contains?(n, "header") -> :header
      String.contains?(n, "footer") -> :footer
      String.contains?(n, "styles") -> :styles
      String.contains?(n, "settings") -> :settings
      String.contains?(n, "numbering") -> :numbering
      String.ends_with?(n, ".rels") -> :rels
      n == "[Content_Types].xml" -> :content_types
      true -> :document
    end
  end

  defp count_open(text), do: length(:binary.matches(text, "{{"))

  defp walk(text, _, s) when is_binary(text), do: {text, s}

  defp walk({name, attrs, children} = node, ctx, s) do
    ctx = if name in ["w:txbxContent", "mc:Fallback"], do: %{ctx | blocked: true}, else: ctx

    cond do
      name == "w:tbl" ->
        s = %{s | table: s.table + 1}
        table = s.table

        {children, s, _} =
          Enum.reduce(children, {[], s, 0}, fn child, {out, st, row} ->
            if is_tuple(child) and elem(child, 0) == "w:tr" do
              {new, st} = row(child, ctx, st, table, row + 1)
              {[new | out], st, row + 1}
            else
              {new, st} = walk(child, ctx, st)
              {[new | out], st, row}
            end
          end)

        {{name, attrs, Enum.reverse(children)}, s}

      name == "w:p" ->
        s = %{s | paragraph: s.paragraph + 1}
        {node, s} = if ctx.blocked, do: {node, s}, else: paragraph(node, ctx, s)
        {_, _, children} = node
        {children, s} = Enum.map_reduce(children, s, &walk(&1, ctx, &2))
        {{name, attrs, children}, s}

      true ->
        {children, s} = Enum.map_reduce(children, s, &walk(&1, ctx, &2))
        {{name, attrs, children}, s}
    end
  end

  defp row({name, attrs, children} = node, ctx, s, table, row) do
    before =
      case property(node, "w:trPr", "w:gridBefore") do
        [n | _] -> Xml.integer(Xml.attr(n, "w:val")) || 0
        _ -> 0
      end

    {children, s, _, _} =
      Enum.reduce(children, {[], s, 0, before}, fn child, {out, st, cell, grid} ->
        if is_tuple(child) and elem(child, 0) == "w:tc" do
          span =
            case property(child, "w:tcPr", "w:gridSpan") do
              [n | _] -> Xml.integer(Xml.attr(n, "w:val")) || 1
              _ -> 1
            end

          cell_ctx = %{ctx | cell: %{table: table, row: row, cell: cell + 1, grid: grid}}
          {new, st} = walk(child, cell_ctx, st)
          {[new | out], st, cell + 1, grid + max(span, 1)}
        else
          {new, st} = walk(child, ctx, st)
          {[new | out], st, cell, grid}
        end
      end)

    {{name, attrs, Enum.reverse(children)}, s}
  end

  defp paragraph({name, attrs, children}, ctx, s) do
    texts = Enum.map(children, &piece/1)
    text = Enum.join(texts)
    matches = Regex.scan(@placeholder, text, return: :index)
    leftover = Regex.replace(@placeholder, text, "")
    place = if ctx.cell, do: Map.delete(ctx.cell, :grid), else: %{paragraph: s.paragraph}

    error =
      if String.contains?(leftover, ["{{", "}}"]),
        do: F.error(:malformed_placeholder, "D4", place),
        else: s.error

    occurrences =
      Enum.map(matches, fn [_, {start, size}] ->
        %{
          name: binary_part(text, start, size),
          paragraph: s.paragraph,
          cell: ctx.cell,
          place: place
        }
      end)

    {_, segments} =
      Enum.reduce(Enum.with_index(texts), {0, []}, fn {t, i}, {offset, acc} ->
        {offset + byte_size(t), [{i, offset, offset + byte_size(t)} | acc]}
      end)

    ranges = matches |> ranges(Enum.reverse(segments)) |> merge_ranges()

    children = join(children, ranges)

    {{name, attrs, children},
     %{
       s
       | occurrences: Enum.reverse(occurrences, s.occurrences),
         plain_count: s.plain_count + count_open(text),
         error: error
     }}
  end

  defp property(node, parent, name),
    do: node |> Xml.children(parent) |> Enum.flat_map(&Xml.children(&1, name))

  # Both matches and segments are in byte order. Advance a cursor rather than
  # rescanning the entire paragraph for each placeholder in a large upload.
  defp ranges([], _segments), do: []

  defp ranges([[{start, size}, _] | matches], segments) do
    segments = Enum.drop_while(segments, fn {_, _, b} -> b <= start end)
    first = hd(segments)
    tail = Enum.drop_while(segments, fn {_, _, b} -> b < start + size end)
    [{elem(first, 0), elem(hd(tail), 0)} | ranges(matches, tail)]
  end

  defp whitespace?(text), do: Regex.match?(~r/^[ \t\r\n]*$/, text)
  defp piece(text) when is_binary(text), do: if(whitespace?(text), do: "", else: @bar)
  defp piece({"w:r", _, children}), do: children |> Enum.map(&run_piece/1) |> Enum.join()
  defp piece({n, _, _}) when n in @markers, do: ""
  defp piece(_), do: @bar
  defp run_piece({"w:t", _, _} = t), do: Xml.text(t)
  defp run_piece({"w:rPr", _, _}), do: ""
  defp run_piece({"w:tab", _, _}), do: "\t"
  defp run_piece({n, _, _}) when n in ["w:br", "w:cr"], do: "\n"
  defp run_piece(text) when is_binary(text), do: piece(text)
  defp run_piece(_), do: @bar

  defp merge_ranges(ranges) do
    Enum.reduce(ranges, [], fn {a, b}, acc ->
      case acc do
        [{x, y} | rest] when a <= y -> [{x, max(b, y)} | rest]
        _ -> [{a, b} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp join(children, ranges), do: join(children, ranges, 0)
  defp join(children, [], _base), do: children

  defp join(children, [{a, b} | ranges], base) do
    {before, rest} = Enum.split(children, a - base)
    {group, after_group} = Enum.split(rest, b - a + 1)
    runs = Enum.filter(group, fn n -> is_tuple(n) and elem(n, 0) == "w:r" end)
    first = hd(runs)
    properties = Xml.children(first, "w:rPr")

    content =
      Enum.flat_map(runs, fn {_, _, c} ->
        Enum.reject(c, fn n ->
          (is_tuple(n) and elem(n, 0) == "w:rPr") or (is_binary(n) and whitespace?(n))
        end)
      end)

    merged = merge_text(content)

    markers = Enum.filter(group, fn n -> is_tuple(n) and elem(n, 0) in @markers end)
    new = [{"w:r", elem(first, 1), properties ++ merged} | markers]
    before ++ new ++ join(after_group, ranges, b + 1)
  end

  defp merge_text([]), do: []

  defp merge_text([{"w:t", _, _} = first | rest]) do
    {texts, tail} = Enum.split_while(rest, fn n -> is_tuple(n) and elem(n, 0) == "w:t" end)

    node =
      if texts == [],
        do: first,
        else: {"w:t", [{"xml:space", "preserve"}], [Enum.map_join([first | texts], &Xml.text/1)]}

    [node | merge_text(tail)]
  end

  defp merge_text([node | rest]), do: [node | merge_text(rest)]
end
