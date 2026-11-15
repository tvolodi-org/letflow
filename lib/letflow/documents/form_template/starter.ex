defmodule Letflow.Documents.FormTemplate.Starter do
  @moduledoc false
  alias Letflow.Documents.{FormPrint, FormTemplate}
  alias FormTemplate.Keys

  def build(form, opts) do
    with {:ok, keys} <- Keys.for_form(form), {:ok, layout} <- FormPrint.layout(form) do
      model = Enum.zip_with(layout["blocks"], keys.blocks, &block(&1, &2, keys))

      with {:ok, bytes} <- FormPrint.Docx.render(model, nil, FormPrint.page(layout)),
           {:ok, checked} <- FormTemplate.check(form, bytes, opts) do
        {:ok, checked.bytes}
      end
    else
      :error -> FormTemplate.error(:unknown_form, "D3")
    end
  end

  defp p(name), do: "{{" <> name <> "}}"

  defp block(%{"type" => "table"} = b, names, keys) do
    t = Enum.find(keys.tables, &(hd(&1.lines) in names.data))
    [{:table, model}] = FormPrint.resolve(%{"blocks" => [b]}, %{}, "ru", FormPrint.catalog())

    headings =
      Enum.filter(t.headings, fn {name, _} -> String.starts_with?(name, "legal.col.") end)

    columns =
      Enum.with_index(model.columns)
      |> Enum.map(fn {c, i} ->
        {name, _} = headings |> Enum.filter(&(elem(&1, 1) <= i)) |> List.last()

        {number, _} =
          Enum.find(t.headings, fn {name, start} ->
            String.starts_with?(name, "legal.colno.") and start == i
          end)

        raw = Enum.at(t.columns, i)
        path = raw["groups"] || List.wrap(raw["group"])

        groups =
          path
          |> Enum.with_index(1)
          |> Enum.map(fn {_, level} ->
            group = Enum.find(t.groups, &(&1.path == Enum.take(path, level)))
            p(group.name)
          end)

        %{
          c
          | label: p(name),
            group: if(raw["group"], do: hd(groups)),
            groups: if(raw["groups"], do: groups, else: [])
        }
        |> Map.put(:no_text, p(number))
      end)

    row = Map.new(Enum.zip(t.columns, t.lines), fn {c, name} -> {c["key"], p(name)} end)

    total =
      if t.total do
        base = Map.new(t.columns, &{&1["key"], ""})

        base =
          Enum.reduce(t.totals, base, fn {name, i}, acc ->
            Map.put(acc, Enum.at(t.columns, i)["key"], p(name))
          end)

        Map.put(base, (Enum.at(t.columns, 1) || hd(t.columns))["key"], p(t.total))
      end

    {:table, %{columns: columns, rows: [row], total: total}}
  end

  defp block(b, names, keys) do
    data = Map.new(names.data, &{&1, p(&1)})

    [model] = FormPrint.resolve(%{"blocks" => [b]}, data, "ru", catalog(names.legal, keys))

    case model do
      {tag, label, _values, captions, stamp} when tag in [:signature, :signature_table] ->
        {tag, label, Enum.map(names.data, &p/1), captions, stamp}

      other ->
        other
    end
  end

  defp catalog(names, keys) do
    Map.new(names, fn name ->
      case Map.fetch!(keys.sources, name) do
        {:catalog, key} -> {key, %{"ru" => p(name)}}
        {:text, _} -> {name, %{"ru" => p(name)}}
      end
    end)
  end
end
