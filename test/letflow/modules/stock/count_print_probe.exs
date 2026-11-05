defmodule Letflow.Modules.Stock.CountPrintTest.PdfProbe do
  @moduledoc false
  # Test-side reader of the PrintLayout renderer's PDF: the text items in page order (same reader
  # as print_override_attach_test.exs).

  def items(bin) do
    streams = streams(bin)
    {8, cmap_text, _} = List.keyfind(streams, 8, 0)

    cmap =
      ~r/<([0-9A-F]{4})> <([0-9A-F]+)>/
      |> Regex.scan(cmap_text)
      |> Map.new(fn [_, cid, hex] ->
        {String.to_integer(cid, 16),
         :unicode.characters_to_binary(Base.decode16!(hex), {:utf16, :big})}
      end)

    streams
    |> Enum.filter(fn {n, _, _} -> n >= 10 and rem(n, 2) == 0 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_, text, _} ->
      for [_, group] <- Regex.scan(~r/BT\n(.*?)ET\n/s, text) do
        for [_, hex] <- Regex.scan(~r/<([0-9A-F]*)> Tj/, group), into: "" do
          for <<cid::binary-4 <- hex>>, into: "", do: Map.fetch!(cmap, String.to_integer(cid, 16))
        end
      end
    end)
  end

  defp streams(bin) do
    for [{s, l}, {ns, nl}, {ds, dl}] <-
          Regex.scan(~r/(\d+) 0 obj\n<< ([^>]*)>>\nstream\n/, bin, return: :index) do
      n = bin |> binary_part(ns, nl) |> String.to_integer()
      [_, len] = Regex.run(~r/\/Length (\d+)/, binary_part(bin, ds, dl))
      {n, :zlib.uncompress(binary_part(bin, s + l, String.to_integer(len))), nil}
    end
  end
end
