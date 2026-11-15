defmodule Letflow.Documents.FormTemplate.Xml do
  @moduledoc false
  alias Letflow.Documents.FormTemplate, as: F

  @namespaces %{
    "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "r" => "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "o" => "urn:schemas-microsoft-com:office:office",
    "mc" => "http://schemas.openxmlformats.org/markup-compatibility/2006"
  }
  @strict_namespaces [
    "http://purl.oclc.org/ooxml/wordprocessingml/main",
    "http://purl.oclc.org/ooxml/officeDocument/relationships"
  ]

  def parse(bytes) do
    bytes =
      case bytes do
        <<239, 187, 191, rest::binary>> -> rest
        _ -> bytes
      end

    cond do
      not String.valid?(bytes) ->
        F.error(:xml_unreadable)

      Regex.match?(~r/<!\s*(DOCTYPE|ENTITY)/i, bytes) ->
        F.error(:doctype)

      Regex.match?(~r/<\?xml[^?]*encoding\s*=\s*["'](?!utf-8["'])/i, bytes) ->
        F.error(:xml_unreadable)

      true ->
        case Saxy.SimpleForm.parse_string(bytes, expand_entity: :skip, cdata_as_characters: true) do
          {:ok, tree} -> if safe?(tree, 1, %{}), do: {:ok, tree}, else: F.error(:xml_unreadable)
          _ -> F.error(:xml_unreadable)
        end
    end
  rescue
    _ -> F.error(:xml_unreadable)
  catch
    _, _ -> F.error(:xml_unreadable)
  end

  # A strict prefix policy prevents aliased/rebound Word namespaces bypassing
  # element and relationship-attribute checks. Other Word extension namespaces
  # are preserved. This deliberately refuses equivalent, noncanonical prefixes.
  defp safe?(text, _, _) when is_binary(text), do: true
  defp safe?(_, depth, _) when depth > 256, do: false

  defp safe?({name, attrs, children}, depth, inherited) do
    ns =
      Enum.reduce(attrs, inherited, fn {k, v}, acc ->
        if String.starts_with?(k, "xmlns:"),
          do: Map.put(acc, String.replace_prefix(k, "xmlns:", ""), v),
          else: acc
      end)

    declarations =
      Enum.all?(ns, fn {prefix, uri} ->
        uri not in @strict_namespaces and
          (not Map.has_key?(@namespaces, prefix) or @namespaces[prefix] == uri) and
          Enum.all?(@namespaces, fn {p, u} -> u != uri or p == prefix end)
      end)

    used = [name | Enum.map(attrs, &elem(&1, 0))]

    default_safe =
      Enum.all?(attrs, fn {k, v} ->
        k != "xmlns" or v not in (Map.values(@namespaces) ++ @strict_namespaces)
      end)

    unique_attrs = length(Enum.uniq_by(attrs, &elem(&1, 0))) == length(attrs)

    declarations and default_safe and unique_attrs and
      Enum.all?(used, fn n ->
        case String.split(n, ":", parts: 2) do
          [p, _] when is_map_key(@namespaces, p) -> ns[p] == @namespaces[p]
          [p, _] when p in ["xml", "xmlns"] -> true
          [p, _] -> Map.has_key?(ns, p)
          _ -> true
        end
      end) and Enum.all?(children, &safe?(&1, depth + 1, ns))
  end

  def nodes({_, _, children} = tree), do: [tree | Enum.flat_map(children, &nodes/1)]
  def nodes(_), do: []
  def named(tree, name), do: Enum.filter(nodes(tree), &(elem(&1, 0) == name))
  def attr({_, attrs, _}, name), do: proplist(attrs, name)

  def proplist(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      nil -> nil
      {_, v} -> v
    end
  end

  def text({_, _, children}), do: children |> Enum.filter(&is_binary/1) |> IO.iodata_to_binary()

  def children({_, _, children}, name),
    do: Enum.filter(children, fn x -> is_tuple(x) and elem(x, 0) == name end)

  def integer(nil), do: nil

  def integer(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def map({n, a, c}, fun), do: fun.({n, a, Enum.map(c, &map(&1, fun)) |> Enum.reject(&is_nil/1)})
  def map(text, _), do: text
end
