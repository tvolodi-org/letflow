defmodule Letflow.Modules.Codes.Labels do
  @moduledoc """
  GH #4017 / REQ-779: renders code labels (`code_tag` records of kind `barcode` or `qr`) into a
  PDF sheet through `Letflow.Documents.PrintLayout.Pdf`. Pure: no database, no clock, no random;
  equal input gives equal bytes.

  Sheet (a UAT assumption: the KZ MinFin catalog has no label form): A4 portrait, 3 columns x 8
  rows, 24 labels per page, no gaps, 0.5 mm top margin. A label box is 19,833 x 10,488 units
  (unit u = 1/100 pt), that is 69.97 x 37 mm: 70 mm would be 19,843 u and three of them would not
  fit the 59,500 u engine page, so the width is `div(59_500, 3)`. Inside a 2 mm margin
  (567 u) a label carries the code text on one line (10 pt, centred) and below it the symbol:
  Code 128 (10 empty modules each side, `mw <= 200` u) or QR level M (at least 4 empty modules
  around the symbol, `qm <= 400` u). A value longer than 20 characters, or wider than 66 mm in the
  font, is refused (UAT assumption).

  `render/1` takes maps with string keys `"value"`, `"kind"`, `"status"` (the shape of
  `Letflow.Modules.Codes.lookup/2`) and returns `{:ok, pdf}` or
  `{:error, {:entry_invalid, index, reason}}` for the first failing code (reason atoms
  `kind_not_printable`, `code_retired`, `value_not_encodable`, `unsupported_glyph`,
  `value_too_long`, checked in that order); `[]` is `{:error, :no_codes}`.
  """

  alias Letflow.Documents.PrintLayout.{Font, Pdf}
  alias Letflow.Modules.Codes.Code128

  @page {59_500, 84_200}
  @box_w 19_833
  @box_h 10_488
  @cols 3
  @rows 8
  @top_margin 142
  @margin 567
  @text_h 1_200
  @text_descent 300
  @gap 250
  @sym_h @box_h - 2 * @margin - @text_h - @gap
  @max_chars 20
  @max_text_w 18_709
  @bar_mw 200
  @qr_mw 400

  @spec render([map()]) ::
          {:ok, binary()} | {:error, :no_codes | {:entry_invalid, non_neg_integer(), atom()}}
  def render([]), do: {:error, :no_codes}

  def render(codes) when is_list(codes) do
    case validate(codes) do
      :ok -> {:ok, codes |> layout() |> Pdf.build()}
      {:error, _} = error -> error
    end
  end

  @doc false
  # The document handed to `Pdf.build/1`; the codes must have passed `render/1`'s validation.
  @spec layout([map()]) :: map()
  def layout(codes) do
    boxes = Enum.with_index(codes)

    pages =
      boxes
      |> Enum.chunk_every(@cols * @rows)
      |> Enum.map(fn chunk ->
        placed = Enum.map(chunk, fn {code, i} -> {code, box(i)} end)
        rects = Enum.flat_map(placed, fn {code, b} -> symbol(code, b) end)
        texts = Enum.map(placed, fn {code, b} -> text(code["value"], b) end)
        rects ++ [{:item, texts}]
      end)

    cps =
      codes
      |> Enum.flat_map(&String.to_charlist(&1["value"]))
      |> Enum.uniq()
      |> Enum.sort()

    %{pages: pages, cps: cps, size: @page}
  end

  # -- validation ------------------------------------------------------------------------------

  defp validate(codes) do
    codes
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {code, i} ->
      case check(code) do
        :ok -> nil
        {:error, reason} -> {:error, {:entry_invalid, i, reason}}
      end
    end)
  end

  defp check(%{"value" => value, "kind" => kind, "status" => status})
       when is_binary(value) and is_binary(kind) do
    cond do
      kind not in ["barcode", "qr"] ->
        {:error, :kind_not_printable}

      status == "retired" ->
        {:error, :code_retired}

      value == "" or not String.valid?(value) ->
        {:error, :value_not_encodable}

      kind == "barcode" and match?({:error, _}, Code128.encode(value)) ->
        {:error, :value_not_encodable}

      Enum.any?(String.to_charlist(value), &is_nil(Font.glyph_id(&1))) ->
        {:error, :unsupported_glyph}

      String.length(value) > @max_chars or text_width(value) > @max_text_w ->
        {:error, :value_too_long}

      kind == "qr" and not qr_ok?(value) ->
        {:error, :value_not_encodable}

      true ->
        :ok
    end
  end

  defp check(_other), do: {:error, :value_not_encodable}

  defp qr_ok?(value) do
    match?(%{matrix: m} when is_tuple(m), EQRCode.encode(value, :m))
  rescue
    _ -> false
  end

  defp text_width(value) do
    value |> String.to_charlist() |> Enum.reduce(0, &(Font.advance(Font.glyph_id(&1)) + &2))
  end

  # -- geometry --------------------------------------------------------------------------------

  defp box(i) do
    on_page = rem(i, @cols * @rows)
    row = div(on_page, @cols)
    {rem(i, @cols) * @box_w, elem(@page, 1) - @top_margin - (row + 1) * @box_h}
  end

  defp text(value, {x0, y0}) do
    x = x0 + div(@box_w - text_width(value), 2)
    {x, y0 + @margin + @text_descent, String.to_charlist(value)}
  end

  defp symbol(%{"kind" => "barcode", "value" => value}, {x0, y0}) do
    {:ok, widths} = Code128.encode(value)
    total = Enum.sum(widths)
    mw = min(@bar_mw, div(@box_w - 2 * @margin, total + 20))
    left = x0 + div(@box_w - (total + 20) * mw, 2) + 10 * mw
    bottom = y0 + @margin + @text_h + @gap

    {rects, _} =
      widths
      |> Enum.with_index()
      |> Enum.reduce({[], left}, fn {w, idx}, {acc, x} ->
        acc = if rem(idx, 2) == 0, do: [{:rect, x, bottom, w * mw, @sym_h} | acc], else: acc
        {acc, x + w * mw}
      end)

    Enum.reverse(rects)
  end

  defp symbol(%{"kind" => "qr", "value" => value}, {x0, y0}) do
    %{matrix: matrix} = EQRCode.encode(value, :m)
    side = tuple_size(matrix)
    qm = min(@qr_mw, div(@sym_h, side + 4))
    left = x0 + div(@box_w - (side + 4) * qm, 2) + 2 * qm
    bottom = y0 + @margin + @text_h + @gap + div(@sym_h - (side + 4) * qm, 2) + 2 * qm

    for {row, r} <- matrix |> Tuple.to_list() |> Enum.with_index(),
        {1, c} <- row |> Tuple.to_list() |> Enum.with_index() do
      {:rect, left + c * qm, bottom + (side - 1 - r) * qm, qm, qm}
    end
  end
end
