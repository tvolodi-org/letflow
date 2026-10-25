defmodule Letflow.Documents.PrintLayout.FontTest do
  @moduledoc """
  REQ-571 / GH #3250 (decision 0068 D8 S1, part 2): the bundled font. Design tests T-F1..T-F3.
  Pure, no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.PrintLayout.{Font, Pdf}

  @ru Enum.to_list(0x410..0x44F) ++ [0x401, 0x451]
  @kk [
    0x4D8,
    0x4D9,
    0x492,
    0x493,
    0x49A,
    0x49B,
    0x4A2,
    0x4A3,
    0x4E8,
    0x4E9,
    0x4B0,
    0x4B1,
    0x4AE,
    0x4AF,
    0x4BA,
    0x4BB,
    0x406,
    0x456
  ]

  test "T-F1 every RU letter and every KK letter, both cases, has a glyph" do
    missing = for cp <- @ru ++ @kk, Font.glyph_id(cp) == nil, do: cp
    assert missing == []
  end

  test "T-F2 space is mapped and an unmapped code point exists in the font's cmap" do
    assert Font.glyph_id(0x20) != nil
    assert Enum.find(0x3400..0x4DBF, &(Font.glyph_id(&1) == nil)) != nil
    assert Font.codepoints() == Enum.sort(Font.codepoints())
  end

  test "T-F3 metrics are sane and the ToUnicode encoder handles an astral code point" do
    assert Font.units_per_em() == 2048
    assert [x0, y0, x1, y1] = Font.bbox()
    assert x0 < x1 and y0 < y1
    assert Font.ascent() > 0 and Font.descent() < 0
    assert Font.advance(Font.glyph_id(?A)) > 0
    assert Pdf.utf16_hex(0x1F600) == "D83DDE00"
    assert Pdf.utf16_hex(0x416) == "0416"
  end

  test "the bundled bytes are the font file" do
    assert Font.data() == File.read!(Path.join(["priv", "fonts", "DejaVuSans.ttf"]))
    assert :zlib.uncompress(Font.data_flate()) == Font.data()
  end
end
