defmodule Letflow.Documents.FormTemplate.PackageTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  alias Letflow.Documents.FormTemplate.{Package, Xml}
  alias Letflow.FormTemplateDocx, as: D

  test "P1 escaped text, attributes, CDATA and whitespace survive the real writer" do
    xml =
      ~s(<w:document #{D.namespaces()} mc:Ignorable="w14"><w:p a="x&amp;&quot;y">\n<w:r><w:t xml:space="preserve">&lt;w:fldSimple/&gt; &amp;</w:t><w:t><![CDATA[<literal>]]></w:t></w:r>\n</w:p></w:document>)

    assert {:ok, tree} = Xml.parse(xml)
    assert Saxy.encode!(tree) =~ "<w:fldSimple/> &"
    assert {:ok, bytes} = Package.write(%{"word/document.xml" => tree})
    written = D.unpack(bytes)["word/document.xml"]
    assert written =~ "&lt;w:fldSimple/&gt; &amp;"
    assert written =~ "&amp;&quot;"
    assert {:ok, ^tree} = Xml.parse(written)
  end

  test "S1-not-docx malformed archives and nonbinary input fail closed" do
    for input <- [<<208, 207, 17, 224>>, "{\\rtf1", :crypto.strong_rand_bytes(100), nil] do
      assert {:error, [%{code: :not_docx, rule: "D4"}]} = Package.read(input)
    end
  end

  test "element depth includes the root but not its text child" do
    assert {:ok, _} =
             Xml.parse(String.duplicate("<x>", 256) <> "text" <> String.duplicate("</x>", 256))

    assert {:error, [%{code: :xml_unreadable, rule: "D4"}]} =
             Xml.parse(String.duplicate("<x>", 257) <> "text" <> String.duplicate("</x>", 257))
  end

  test "S1-zip-caps compressed bytes exact boundary" do
    base = D.zip(%{"padding" => ""}, stored: true)

    bytes =
      D.zip(%{"padding" => :crypto.strong_rand_bytes(1_048_576 - byte_size(base))}, stored: true)

    assert byte_size(bytes) == 1_048_576
    assert {:ok, _} = Package.read(bytes)
    assert {:error, [%{code: :too_large}]} = Package.read(bytes <> "x")
  end

  test "S1-zip-caps entry count exact boundary" do
    parts = Map.new(1..200, &{"p#{&1}", ""})
    assert {:ok, entries} = parts |> D.zip() |> Package.read()
    assert length(entries) == 200

    assert {:error, [%{code: :zip_too_many_entries}]} =
             parts |> Map.put("p201", "") |> D.zip() |> Package.read()
  end

  @tag timeout: 10_000
  test "S1-zip-caps actual inflated total exact boundary" do
    # Repeated random blocks compress to about 50:1, within each entry's ratio.
    block = :crypto.strong_rand_bytes(4096)
    data = :binary.copy(block, 2560)
    compressed = deflate(data)
    # Empty non-final DEFLATE stored blocks, before the final stream, contribute
    # five compressed bytes and zero inflated bytes each. No trailing garbage.
    compressed = pad(compressed, div(max(0, 120_000 - byte_size(compressed)), 5))
    bytes = raw_zip("p", compressed, byte_size(data), 0, 8, :erlang.crc32(data))
    assert {:ok, [{~c"p", ^data}]} = :zip.extract(bytes, [:memory])
    assert {:ok, [{"p", ^data}]} = Package.read(bytes)

    assert {:error, [%{code: :zip_inflated_too_large}]} =
             Package.read(raw_zip("p", deflate(data <> "x"), byte_size(data) + 1))
  end

  test "S1-zip-caps ratio exactly 100 and one real byte over" do
    n =
      Enum.find(Enum.map(100..300, &(&1 * 100)), fn size ->
        a = byte_size(deflate(:binary.copy(<<0>>, size)))
        b = byte_size(deflate(:binary.copy(<<0>>, size + 1)))
        a == b and rem(div(size, 100) - a, 5) == 0
      end)

    assert is_integer(n)

    for {size, expected} <- [{n, :ok}, {n + 1, :zip_ratio}] do
      data = :binary.copy(<<0>>, size)
      compressed = deflate(data)
      compressed = pad(compressed, div(div(n, 100) - byte_size(compressed), 5))
      assert n == 100 * byte_size(compressed)
      bytes = raw_zip("p", compressed, size, 0, 8, :erlang.crc32(data))
      assert {:ok, [{~c"p", ^data}]} = :zip.extract(bytes, [:memory])

      case expected do
        :ok -> assert {:ok, _} = Package.read(bytes)
        code -> assert {:error, [%{code: ^code}]} = Package.read(bytes)
      end
    end
  end

  @tag timeout: 10_000
  test "S1-zip-bomb and S1-lying-size use actual output budget" do
    data = :binary.copy(<<0>>, 50 * 1024 * 1024)
    compressed = deflate(data)
    start = System.monotonic_time(:millisecond)
    assert {:error, [%{code: code}]} = Package.read(raw_zip("p", compressed, 1))
    assert code in [:zip_ratio, :zip_inflated_too_large]
    assert System.monotonic_time(:millisecond) - start < 2000
    data = :binary.copy(:crypto.strong_rand_bytes(4096), 2816)
    compressed = deflate(data)
    compressed = pad(compressed, div(max(0, 150_000 - byte_size(compressed)), 5))

    assert {:error, [%{code: :zip_inflated_too_large}]} =
             Package.read(raw_zip("p", compressed, 1))
  end

  test "S1-entry-name unsafe, duplicate, encrypted and unsupported entries" do
    for name <- [
          "../x.xml",
          "/abs.xml",
          "word\\document.xml",
          "word/./x",
          "a/../../x",
          <<255>>,
          "a" <> <<0>>
        ] do
      assert {:error, [%{code: :zip_bad_entry}]} = raw_zip(name, "x", 1, 0, 0) |> Package.read()
    end

    assert {:error, [%{code: :zip_bad_entry}]} =
             D.zip(%{"word/Document.xml" => "a", "word/document.xml" => "b"}) |> Package.read()

    for {flags, method} <- [{1, 8}, {0, 12}] do
      assert {:error, [%{code: :zip_bad_entry}]} =
               Package.read(raw_zip("p", "", 0, flags, method))
    end
  end

  defp deflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      :zlib.deflate(z, data, :finish) |> IO.iodata_to_binary()
    after
      :zlib.close(z)
    end
  end

  defp pad(compressed, count), do: :binary.copy(<<0, 0, 0, 255, 255>>, count) <> compressed

  defp raw_zip(name, data, usize, flags \\ 0, method \\ 8, crc \\ 0) do
    n = byte_size(name)
    c = byte_size(data)

    local =
      <<0x04034B50::32-little, 20::16-little, flags::16-little, method::16-little, 0::32,
        crc::32-little, c::32-little, usize::32-little, n::16-little, 0::16, name::binary,
        data::binary>>

    dir =
      <<0x02014B50::32-little, 20::16-little, 20::16-little, flags::16-little, method::16-little,
        0::32, crc::32-little, c::32-little, usize::32-little, n::16-little, 0::16, 0::16, 0::16,
        0::16, 0::32, 0::32, name::binary>>

    local <>
      dir <>
      <<0x06054B50::32-little, 0::16, 0::16, 1::16-little, 1::16-little,
        byte_size(dir)::32-little, byte_size(local)::32-little, 0::16>>
  end
end
