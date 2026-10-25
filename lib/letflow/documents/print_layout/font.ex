defmodule Letflow.Documents.PrintLayout.Font.Parser do
  @moduledoc false
  # Compile-time TrueType reader for `Letflow.Documents.PrintLayout.Font`. Big-endian, no
  # dependencies. It runs while the font module compiles, so a font that cannot be parsed
  # does not compile; nothing here runs on a request path.

  import Bitwise

  @cmap_prefs [{3, 10}, {0, 4}, {3, 1}, {0, 3}]

  def parse(data) do
    <<_::32, num_tables::16, _::binary>> = data

    tables =
      for i <- 0..(num_tables - 1), into: %{} do
        <<tag::binary-4, _sum::32, off::32, len::32>> = binary_part(data, 12 + i * 16, 16)
        {tag, binary_part(data, off, len)}
      end

    <<_::binary-18, upm::16, _::binary-16, x_min::signed-16, y_min::signed-16, x_max::signed-16,
      y_max::signed-16, _::binary>> = Map.fetch!(tables, "head")

    <<_::binary-4, ascent::signed-16, descent::signed-16, _::binary-26, n_metrics::16, _::binary>> =
      Map.fetch!(tables, "hhea")

    advances = advances(Map.fetch!(tables, "hmtx"), n_metrics)
    last = Map.fetch!(advances, n_metrics - 1)

    %{
      units_per_em: upm,
      bbox: Enum.map([x_min, y_min, x_max, y_max], &scale(&1, upm)),
      ascent: scale(ascent, upm),
      descent: scale(descent, upm),
      advances: Map.new(advances, fn {gid, adv} -> {gid, scale(adv, upm)} end),
      last_advance: scale(last, upm),
      cmap: cmap(Map.fetch!(tables, "cmap"))
    }
  end

  defp scale(v, upm), do: round(v * 1000 / upm)

  defp advances(hmtx, n) do
    for i <- 0..(n - 1), into: %{} do
      <<adv::16>> = binary_part(hmtx, i * 4, 2)
      {i, adv}
    end
  end

  defp cmap(table) do
    <<_ver::16, n::16, _::binary>> = table

    subtables =
      for i <- 0..(n - 1), into: %{} do
        <<plat::16, enc::16, off::32>> = binary_part(table, 4 + i * 8, 8)
        {{plat, enc}, binary_part(table, off, byte_size(table) - off)}
      end

    sub =
      Enum.find_value(@cmap_prefs, fn key -> Map.get(subtables, key) end) ||
        raise "font has no usable cmap subtable"

    sub |> subtable() |> Map.reject(fn {_cp, gid} -> gid == 0 end)
  end

  defp subtable(<<12::16, _::binary>> = sub) do
    <<_::binary-12, groups::32, rest::binary>> = sub

    for i <- 0..(groups - 1), reduce: %{} do
      acc ->
        <<s::32, e::32, gid::32>> = binary_part(rest, i * 12, 12)
        Enum.reduce(s..e//1, acc, fn cp, m -> Map.put(m, cp, gid + cp - s) end)
    end
  end

  defp subtable(<<4::16, _::binary>> = sub) do
    <<_::binary-6, seg_x2::16, _::binary>> = sub
    segs = div(seg_x2, 2)
    u16 = fn off -> u16(sub, off) end

    for i <- 0..(segs - 1), reduce: %{} do
      acc ->
        end_c = u16.(14 + 2 * i)
        start_c = u16.(16 + 2 * segs + 2 * i)
        delta = u16.(16 + 4 * segs + 2 * i)
        range_off = u16.(16 + 6 * segs + 2 * i)

        Enum.reduce(start_c..end_c//1, acc, fn cp, m ->
          gid =
            cond do
              cp == 0xFFFF -> 0
              range_off == 0 -> band(cp + delta, 0xFFFF)
              true -> glyph_from_array(u16, segs, i, range_off, cp - start_c, delta)
            end

          Map.put(m, cp, gid)
        end)
    end
  end

  defp u16(bin, off) do
    <<v::16>> = binary_part(bin, off, 2)
    v
  end

  defp glyph_from_array(u16, segs, i, range_off, k, delta) do
    pos = 16 + 6 * segs + 2 * i + range_off + 2 * k

    case u16.(pos) do
      0 -> 0
      g -> band(g + delta, 0xFFFF)
    end
  end
end

defmodule Letflow.Documents.PrintLayout.Font do
  @moduledoc """
  The one bundled font of the print renderer: DejaVu Sans (`priv/fonts/DejaVuSans.ttf`, licence
  in `priv/fonts/DejaVuSans.LICENSE`). The file is read and parsed at compile time
  (`@external_resource`), so the renderer does no file access at run time.

  Widths are in 1/1000 em. A code point that the font's cmap does not map (or maps to the
  `.notdef` glyph 0) has no glyph: `glyph_id/1` returns `nil`.
  """

  alias Letflow.Documents.PrintLayout.Font.Parser

  @path Path.expand("../../../../priv/fonts/DejaVuSans.ttf", __DIR__)
  @external_resource @path
  @data File.read!(@path)
  @data_flate :zlib.compress(@data)
  @parsed Parser.parse(@data)
  @cmap @parsed.cmap
  @advances @parsed.advances
  @last_advance @parsed.last_advance
  @codepoints @cmap |> Map.keys() |> Enum.sort()

  @doc "Glyph id of a code point, or `nil` when the font has no glyph for it."
  @spec glyph_id(non_neg_integer) :: non_neg_integer | nil
  def glyph_id(codepoint), do: Map.get(@cmap, codepoint)

  @doc "Advance width of a glyph in 1/1000 em."
  @spec advance(non_neg_integer) :: non_neg_integer
  def advance(gid), do: Map.get(@advances, gid, @last_advance)

  @doc "The whole TrueType file."
  @spec data() :: binary
  def data, do: @data

  @doc "The whole TrueType file, zlib-compressed (the Flate stream payload)."
  @spec data_flate() :: binary
  def data_flate, do: @data_flate

  @spec units_per_em() :: pos_integer
  def units_per_em, do: @parsed.units_per_em

  @doc "`[x_min, y_min, x_max, y_max]` in 1/1000 em."
  @spec bbox() :: [integer]
  def bbox, do: @parsed.bbox

  @spec ascent() :: integer
  def ascent, do: @parsed.ascent

  @spec descent() :: integer
  def descent, do: @parsed.descent

  @doc "All mapped code points, ascending."
  @spec codepoints() :: [non_neg_integer]
  def codepoints, do: @codepoints
end
