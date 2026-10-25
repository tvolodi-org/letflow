defmodule Letflow.Documents.PrintLayoutTest do
  @moduledoc """
  REQ-571 / GH #3250 (decision 0068 D8 S1, part 1): `Letflow.Documents.PrintLayout.validate/3`.
  Design: state/tasks/T-0569/design.md, tests V1..V11, P1..P3, L1..L3, S1, R1, N1, SC1.
  Pure, no database.
  """

  use ExUnit.Case, async: true

  alias Letflow.Documents.PrintLayout

  @declared %{"order" => ["number", "total", "secret"], "line" => ["sku"]}
  @page %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"}
  @field %{"type" => "field", "entity_type" => "order", "field_name" => "number"}

  defp layout(blocks), do: %{"layout_schema_version" => 1, "blocks" => blocks}
  defp full, do: layout([@page | tail_blocks()])

  defp tail_blocks do
    [
      %{"type" => "text", "text" => "Order {{order.number}}"},
      @field,
      %{
        "type" => "table",
        "entity_type" => "line",
        "columns" => [%{"field_name" => "sku", "header" => "SKU", "width" => 40}]
      },
      %{"type" => "spacer", "height_mm" => 5}
    ]
  end

  defp run(l, opts \\ []), do: PrintLayout.validate(l, @declared, opts)

  defp viols(l, opts \\ []) do
    {:error, vs} = run(l, opts)
    vs
  end

  defp rule(l, rule, opts \\ []), do: Enum.filter(viols(l, opts), &(&1.rule == rule))

  describe "S1-schema" do
    test "V1 all five block types are ok; image is refused" do
      assert :ok = run(full())
      img = layout([@page, %{"type" => "image"}])
      assert [%{rule: :unknown_block_type, path: ["blocks", 1, "type"]}] = viols(img)
    end

    test "V2 unknown block type" do
      l = layout([@page, %{"type" => "banner"}])
      assert [%{rule: :unknown_block_type, path: ["blocks", 1, "type"]}] = viols(l)
    end

    for key <- ~w(url href script expr if) do
      test "V3 unknown key #{key}" do
        l = layout([@page, %{"type" => "text", "text" => "x", unquote(key) => "y"}])
        assert [%{rule: :unknown_key, path: ["blocks", 1, unquote(key)]}] = viols(l)
      end
    end

    test "V4 missing page" do
      assert [%{rule: :missing_page, path: ["blocks"]}] = viols(layout([@field]))
    end

    test "V5 repeated page" do
      assert [%{rule: :repeated_page, path: ["blocks", 1]}] = viols(layout([@page, @page]))
    end

    test "page not first" do
      assert [%{rule: :page_not_first, path: ["blocks", 1]}] = viols(layout([@field, @page]))
    end

    test "V6 version other than 1 and missing" do
      assert [%{rule: :unsupported_version, path: ["layout_schema_version"]}] =
               viols(%{"layout_schema_version" => 2, "blocks" => [@page]})

      assert [%{rule: :unsupported_version}] = viols(%{"blocks" => [@page]})
    end

    test "V7 literal over 500 characters in text, label and header" do
      long = String.duplicate("a", 501)
      ok = String.duplicate("a", 500)
      assert :ok = run(layout([@page, %{"type" => "text", "text" => ok}]))

      assert [%{rule: :literal_too_long, path: ["blocks", 1, "text"]}] =
               viols(layout([@page, %{"type" => "text", "text" => long}]))

      assert [%{rule: :literal_too_long, path: ["blocks", 1, "label"]}] =
               viols(layout([@page, Map.put(@field, "label", long)]))

      col = %{"field_name" => "sku", "header" => long, "width" => 10}
      tbl = %{"type" => "table", "entity_type" => "line", "columns" => [col]}

      assert [%{rule: :literal_too_long, path: ["blocks", 1, "columns", 0, "header"]}] =
               viols(layout([@page, tbl]))
    end

    test "V8 more than 200 blocks" do
      two_hundred = layout([@page | List.duplicate(%{"type" => "spacer", "height_mm" => 1}, 199)])
      assert :ok = run(two_hundred)
      over = layout([@page | List.duplicate(%{"type" => "spacer", "height_mm" => 1}, 200)])
      assert [%{rule: :too_many_blocks, path: ["blocks"]}] = rule(over, :too_many_blocks)
    end

    test "V9 more than 12 columns" do
      col = fn -> %{"field_name" => "sku", "header" => "h", "width" => 1} end

      tbl = fn n ->
        %{"type" => "table", "entity_type" => "line", "columns" => for(_ <- 1..n, do: col.())}
      end

      assert :ok = run(layout([@page, tbl.(12)]))

      assert [%{rule: :too_many_columns, path: ["blocks", 1, "columns"]}] =
               viols(layout([@page, tbl.(13)]))
    end

    test "V10 font other than dejavu-sans" do
      l = layout([%{@page | "font" => "helvetica"}])
      assert [%{rule: :unsupported_font, path: ["blocks", 0, "font"]}] = viols(l)
    end

    test "V11 template and url-looking literals are plain text" do
      l = layout([@page, %{"type" => "text", "text" => "{{x.y}} http://example.test"}])
      assert :ok = run(l)
    end

    test "rule atoms for the listed faults are distinct" do
      rules = [
        hd(viols(layout([@page, %{"type" => "banner"}]))).rule,
        hd(viols(layout([@page, %{"type" => "text", "text" => "x", "url" => "u"}]))).rule,
        hd(viols(layout([@field]))).rule,
        hd(viols(layout([@page, @page]))).rule,
        hd(viols(%{"layout_schema_version" => 2, "blocks" => [@page]})).rule,
        hd(viols(layout([%{@page | "font" => "x"}]))).rule
      ]

      assert length(Enum.uniq(rules)) == length(rules)
    end
  end

  describe "criterion 6 projection (validate part)" do
    test "P1 field outside declared_fields" do
      l = layout([@page, %{@field | "field_name" => "nope"}])
      assert [%{rule: :field_not_projected, path: ["blocks", 1, "field_name"]}] = viols(l)
    end

    test "P2 column outside declared_fields" do
      tbl = %{
        "type" => "table",
        "entity_type" => "line",
        "columns" => [%{"field_name" => "nope", "header" => "h", "width" => 5}]
      }

      assert [%{rule: :field_not_projected, path: ["blocks", 1, "columns", 0, "field_name"]}] =
               viols(layout([@page, tbl]))
    end

    test "P3 restricted field and column" do
      restricted = [{"order", "secret"}, {"line", "sku"}]
      f = %{@field | "field_name" => "secret"}

      assert [%{rule: :field_restricted, path: ["blocks", 1, "field_name"]}] =
               viols(layout([@page, f]), restricted: restricted)

      assert [%{rule: :field_restricted, path: ["blocks", 3, "columns", 0, "field_name"]}] =
               rule(full(), :field_restricted, restricted: restricted)
    end
  end

  describe "D5-redact locked fields" do
    test "L1 locked pair not referenced" do
      l = layout([@page])

      assert [%{rule: :locked_field_missing, path: ["blocks"]}] =
               viols(l, locked: [{"order", "number"}])
    end

    test "L2 all locked pairs referenced" do
      assert :ok = run(full(), locked: [{"order", "number"}])
    end

    test "L3 a table column does not satisfy a lock" do
      assert [%{rule: :locked_field_missing, path: ["blocks"]}] =
               viols(full(), locked: [{"line", "sku"}])
    end
  end

  describe "D5-redact violations carry no values" do
    test "S1 sentinel never appears; keys are rule and path only" do
      s = "SENTINEL_9f3a"
      declared = %{s => [s]}

      scenarios = [
        layout([@page, %{"type" => "text", "text" => String.duplicate(s, 100)}]),
        layout([
          @page,
          %{
            "type" => "field",
            "entity_type" => s,
            "field_name" => s,
            "label" => String.duplicate(s, 100)
          }
        ]),
        layout([
          %{@page | "font" => s},
          %{"type" => "field", "entity_type" => s, "field_name" => "x#{s}"}
        ]),
        layout([@page, %{"type" => s}]),
        layout([@page, %{"type" => "text", "text" => 5}])
      ]

      for l <- scenarios do
        for opts <- [[], [restricted: [{s, s}], locked: [{s, "other"}]]] do
          {:error, vs} = PrintLayout.validate(l, declared, opts)
          refute inspect(vs) =~ s
          assert Enum.all?(vs, &(Map.keys(&1) |> Enum.sort() == [:path, :rule]))
        end
      end
    end
  end

  describe "robustness" do
    test "R1 malformed input does not raise" do
      assert {:error, [%{rule: :invalid_layout, path: []}]} =
               PrintLayout.validate("x", @declared, [])

      assert [%{rule: :invalid_blocks}] = viols(%{"layout_schema_version" => 1, "blocks" => "x"})
      assert {:error, _} = run(%{layout_schema_version: 1, blocks: [@page]})
      assert [%{rule: :invalid_block, path: ["blocks", 1]}] = viols(layout([@page, "x"]))
      assert :ok = PrintLayout.validate(layout([@page]), :nope, nil)
      assert :ok = PrintLayout.validate(layout([@page]), %{}, %{restricted: :x, locked: [1]})

      assert {:error, [%{rule: :field_not_projected}]} =
               PrintLayout.validate(layout([@page, @field]), :nope, [])
    end
  end

  describe "no row limit" do
    test "N1 validate/3 has no rows concept" do
      assert function_exported?(PrintLayout, :validate, 3)

      tbl = %{
        "type" => "table",
        "entity_type" => "line",
        "rows" => 5,
        "columns" => [%{"field_name" => "sku", "header" => "h", "width" => 1}]
      }

      assert [%{rule: :unknown_key, path: ["blocks", 1, "rows"]}] = viols(layout([@page, tbl]))
    end
  end

  describe "purity" do
    test "SC1 source scan: no Repo, DateTime, System or :httpc" do
      files = [
        "lib/letflow/documents/print_layout.ex"
        | Path.wildcard("lib/letflow/documents/print_layout/**/*.ex")
      ]

      for f <- files do
        refute File.read!(f) =~ ~r/\bRepo\b|DateTime|System\.|:httpc/, "#{f} is not pure"
      end
    end
  end
end
