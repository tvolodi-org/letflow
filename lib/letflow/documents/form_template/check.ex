defmodule Letflow.Documents.FormTemplate.Check do
  @moduledoc """
  Legal-field rules D3.1–D3.5 on the same joined tree the package writer receives.

  D3 rule 4 as applied: heading grid position, several header rows allowed;
  differs from the record's 'exactly one header row' wording, see T-1981.
  Ungrouped headings span the platform's two-row grouped headers. Required group,
  caption, stamp and other catalog-text names tighten the D2 list (0089 D1).
  """
  alias Letflow.Documents.FormTemplate, as: F

  def run(occurrences, keys) do
    by_name = Enum.group_by(occurrences, & &1.name)
    known = MapSet.new(keys.legal ++ keys.data ++ [keys.logo])

    unknown =
      for o <- occurrences,
          not MapSet.member?(known, o.name),
          do: refusal(:unknown_name, "D3.3", o.place)

    legal = Enum.flat_map(keys.legal, fn name -> count(by_name[name] || [], name, :legal) end)
    data = Enum.flat_map(keys.data, fn name -> count(by_name[name] || [], name, :data) end)

    logo =
      case by_name[keys.logo] || [] do
        [_, second | _] -> [refusal(:duplicate_legal, "D3.1", second.place, keys.logo)]
        _ -> []
      end

    tables = Enum.flat_map(keys.tables, &table(&1, by_name, occurrences))

    errors =
      (unknown ++ legal ++ data ++ logo ++ tables)
      |> Enum.sort_by(&{&1.rule, &1.place, &1.name})
      |> Enum.take(F.limits().refusals)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp refusal(code, rule, place, name \\ nil) do
    {:error, [error]} = F.error(code, rule, place, name)
    error
  end

  defp count(found, name, kind) do
    signature = String.starts_with?(name, ["sig.", "legal.sig.", "legal.cap.", "legal.stamp."])
    rule = if signature, do: "D3.5", else: if(kind == :legal, do: "D3.1", else: "D3.2")

    case {found, kind} do
      {[], :legal} -> [refusal(:missing_legal, rule, nil, name)]
      {[], :data} -> [refusal(:missing_data, rule, nil, name)]
      {[_, second | _], :legal} -> [refusal(:duplicate_legal, rule, second.place, name)]
      _ -> []
    end
  end

  defp table(t, by_name, all) do
    lines = Enum.flat_map(t.lines, &(by_name[&1] || []))
    rows = lines |> Enum.map(&row_key/1) |> Enum.uniq()

    if lines == [] do
      []
    else
      case rows do
        [{table, row}] ->
          cells = Enum.filter(all, &(row_key(&1) == {table, row}))
          ordered = Enum.sort_by(lines, & &1.cell.cell)

          valid =
            Enum.map(ordered, & &1.name) == t.lines and
              length(Enum.uniq_by(ordered, & &1.cell.cell)) == length(t.lines)

          extra = Enum.any?(cells, &(&1.name not in t.lines))

          row_errors =
            cond do
              extra -> [refusal(:repeat_row, "D3.4", hd(lines).place)]
              not valid -> [refusal(:column_order, "D3.4", hd(lines).place)]
              true -> []
            end

          header_errors =
            Enum.flat_map(t.headings, fn {name, start} ->
              expected = Enum.at(ordered, start)

              Enum.flat_map(by_name[name] || [], fn o ->
                same =
                  o.cell && expected && o.cell.table == table && o.cell.row < row &&
                    o.cell.grid == expected.cell.grid

                alone =
                  Enum.count(all, fn x ->
                    x.cell == o.cell and
                      String.starts_with?(x.name, ["legal.col.", "legal.colno."])
                  end) <= 1

                if same and alone, do: [], else: [refusal(:column_order, "D3.4", o.place, name)]
              end)
            end)

          totals =
            Enum.flat_map(by_name[t.total] || [], fn o ->
              if o.cell && o.cell.table == table && o.cell.row > row,
                do: [],
                else: [refusal(:total_place, "D3.4", o.place, t.total)]
            end)

          row_errors ++ header_errors ++ totals

        _ ->
          [refusal(:repeat_row, "D3.4", hd(lines).place)]
      end
    end
  end

  defp row_key(%{cell: nil}), do: nil
  defp row_key(%{cell: c}), do: {c.table, c.row}
end
