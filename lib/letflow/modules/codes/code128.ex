defmodule Letflow.Modules.Codes.Code128 do
  @moduledoc """
  GH #4017 / REQ-779: a pure Code 128 encoder, code set B only (ASCII 32..126), for the code
  labels of `Letflow.Modules.Codes.Labels`.

  `encode/1` returns the element widths in modules: bar, space, bar, space, ... from the start
  character to the end of the stop pattern (the stop pattern has seven widths, 13 modules). No
  quiet zone is included; bars are the elements at even indexes. The check symbol is
  `(104 + sum(position * value)) rem 103`. Total modules: `11 * (n + 2) + 13` for `n` characters.

  The 107 patterns (values 0..106, ISO/IEC 15417) are the digit strings of `@patterns`; every
  pattern but the stop sums to 11 modules.
  """

  @patterns ~w(
    212222 222122 222221 121223 121322 131222 122213 122312 132212 221213
    221312 231212 112232 122132 122231 113222 123122 123221 223211 221132
    221231 213212 223112 312131 311222 321122 321221 312212 322112 322211
    212123 212321 232121 111323 131123 131321 112313 132113 132311 211313
    231113 231311 112133 112331 132131 113123 113321 133121 313121 211331
    231131 213113 213311 213131 311123 311321 331121 312113 312311 332111
    314111 221411 431111 111224 111422 121124 121421 141122 141221 112214
    112412 122114 122411 142112 142211 241211 221114 413111 241112 134111
    111242 121142 121241 114212 124112 124211 411212 421112 421211 212141
    214121 412121 111143 111341 131141 114113 114311 411113 411311 113141
    114131 311141 411131 211412 211214 211232 2331112
  )

  @start_b 104
  @stop 106

  @doc "The pattern table as digit strings, index = symbol value (for tests)."
  @spec patterns() :: [String.t()]
  def patterns, do: @patterns

  @doc "Element widths of `value`, or `{:error, :value_not_encodable}`."
  @spec encode(term()) :: {:ok, [pos_integer()]} | {:error, :value_not_encodable}
  def encode(value) when is_binary(value) and value != "" do
    if String.valid?(value) and printable_ascii?(value) do
      values = for <<c <- value>>, do: c - 32

      check =
        values
        |> Enum.with_index(1)
        |> Enum.reduce(@start_b, fn {v, i}, acc -> acc + v * i end)
        |> rem(103)

      widths =
        [@start_b | values]
        |> Kernel.++([check, @stop])
        |> Enum.flat_map(&pattern/1)

      {:ok, widths}
    else
      {:error, :value_not_encodable}
    end
  end

  def encode(_value), do: {:error, :value_not_encodable}

  defp printable_ascii?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 32..126))

  defp pattern(symbol) do
    @patterns |> Enum.at(symbol) |> String.to_charlist() |> Enum.map(&(&1 - ?0))
  end
end
