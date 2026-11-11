defmodule Letflow.Documents.NumberLabelTest do
  @moduledoc """
  Canary for CORE slice S1: `Letflow.Documents.number_label/3` is the one home of the document
  number label that assets, stock and the core used to build with five copies.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents

  defp type(scope, pad), do: %{number_prefix: "INV", number_pad: pad, numbering_scope: scope}

  test "scope :none ignores the period" do
    assert Documents.number_label(type(:none, 6), 123, nil) == "INV-000123"
    assert Documents.number_label(type(:none, 6), 123, "2026") == "INV-000123"
  end

  test "a yearly scope puts the period between prefix and number" do
    assert Documents.number_label(type(:year, 6), 123, "2026") == "INV-2026-000123"
  end

  test "pad 1 does not add zeros" do
    assert Documents.number_label(type(:none, 1), 7, nil) == "INV-7"
    assert Documents.number_label(type(:year, 1), 7, "2026") == "INV-2026-7"
  end

  test "a number wider than the pad is not cut" do
    assert Documents.number_label(type(:none, 3), 123_456, nil) == "INV-123456"
    assert Documents.number_label(type(:year, 3), 123_456, "2026") == "INV-2026-123456"
  end
end
