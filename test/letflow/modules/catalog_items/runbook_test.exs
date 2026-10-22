defmodule Letflow.Modules.CatalogItems.RunbookTest do
  @moduledoc """
  GH #2664 / REQ-507 AC5 (spec `test/specs/GH-2664.md`, tests B-*): `docs/runbooks/wms-foundation.md`
  has the "Catalog module limits" section with a numbered list, and every limit names a GH number
  or a code path that exists on this checkout. Scoped to the Catalog section only (the Org
  section has its own test). No network and no database.
  """

  use ExUnit.Case, async: true

  @runbook Path.expand("../../../../docs/runbooks/wms-foundation.md", __DIR__)
  @root Path.expand("../../../..", __DIR__)
  @heading "## Catalog module limits"

  @path_re ~r{`?((?:lib|priv|test|docs|config)/[A-Za-z0-9_./-]+\.[a-z]+[a-z0-9]*)(?::(\d+))?`?}
  @gh_re ~r/GH #(\S+)/

  # Returns the numbered items of the section as `[{number, text}]`.
  defp items do
    lines = @runbook |> File.read!() |> String.split("\n")

    section =
      lines
      |> Enum.drop_while(&(&1 != @heading))
      |> Enum.drop(1)
      |> Enum.take_while(&(not String.starts_with?(&1, "## ")))

    section
    |> Enum.reduce([], fn line, acc ->
      case {Regex.run(~r/^(\d+)\. (.*)$/, line), acc} do
        {[_, n, rest], _} -> [{String.to_integer(n), rest} | acc]
        {nil, [{n, text} | tail]} -> [{n, text <> " " <> String.trim(line)} | tail]
        {nil, []} -> []
      end
    end)
    |> Enum.reverse()
  end

  test "B-01: the file has the exact section heading" do
    assert File.exists?(@runbook)
    assert @runbook |> File.read!() |> String.split("\n") |> Enum.member?(@heading)
  end

  test "B-02: the section is a numbered list 1..N with the known limits" do
    numbers = Enum.map(items(), &elem(&1, 0))
    assert length(numbers) >= 8
    assert numbers == Enum.to_list(1..length(numbers))

    text = items() |> Enum.map_join("\n", &elem(&1, 1))
    assert text =~ "entity_type_managed"
    assert text =~ "#2582"
    assert text =~ "reserved_idempotency_key"
    assert text =~ "/3"
    assert text =~ "base_uom_id"
    assert text =~ "item_uom_valid?"
    assert text =~ "undefined_table"
  end

  test "B-03: every limit names a GH number or a code path" do
    for {n, text} <- items() do
      gh? = Regex.match?(@gh_re, text)
      path? = Regex.match?(@path_re, text)
      assert gh? or path?, "limit #{n} cites neither a GH number nor a path"
    end
  end

  test "B-04: every GH reference is a plain number" do
    refs = for {_n, text} <- items(), [_, ref] <- Regex.scan(@gh_re, text), do: ref
    assert refs != []

    for ref <- refs do
      assert Regex.match?(~r/^\d+[).,;:]*$/, ref), "GH ref #{inspect(ref)} is not a plain number"
    end
  end

  test "B-05: every cited path exists and every cited line is within the file" do
    cited =
      for {n, text} <- items(),
          [_, path | line] <- Regex.scan(@path_re, text) do
        {n, path, line}
      end

    assert cited != []

    for {n, path, line} <- cited do
      full = Path.join(@root, path)
      assert File.exists?(full), "limit #{n}: cited path #{path} does not exist"

      case line do
        [l] when l != "" ->
          count = full |> File.read!() |> String.split("\n") |> length()
          line_no = String.to_integer(l)

          assert line_no >= 1 and line_no <= count,
                 "limit #{n}: #{path}:#{line_no} is beyond the #{count}-line file"

        _ ->
          :ok
      end
    end
  end

  test "B-06: the cited code lines still hold the symbol the limit names" do
    expect = [
      {"lib/letflow/entities/records.ex", 1893, "check_write_authority"},
      {"lib/letflow/entities/records.ex", 385, "create_record"},
      {"lib/letflow/entities/records.ex", 1066, "reject_step_key"},
      {"lib/letflow/entities/records.ex", 1010, "reject_reserved_attributes"},
      {"lib/letflow/entities/records.ex", 332, "step_key_prefix"},
      {"lib/letflow/routers/entities.ex", 538, "entity_type_managed"},
      {"lib/letflow/entities/step_writes.ex", 755, "command_multi"},
      {"lib/letflow/entities/handler_writes.ex", 249, "command_multi"}
    ]

    section = items() |> Enum.map_join("\n", &elem(&1, 1))

    for {path, line_no, symbol} <- expect do
      assert section =~ "#{path}:#{line_no}" or section =~ "line #{line_no}",
             "catalog section no longer cites #{path}:#{line_no}"

      line =
        @root |> Path.join(path) |> File.read!() |> String.split("\n") |> Enum.at(line_no - 1)

      assert line =~ symbol, "#{path}:#{line_no} no longer holds #{symbol}: #{inspect(line)}"
    end
  end

  test "B-07: the catalog section cites the catalog module and item definition paths" do
    text = items() |> Enum.map_join("\n", &elem(&1, 1))
    assert text =~ "lib/letflow/modules/catalog_items/catalog_items.ex"
    assert text =~ "priv/modules/catalog_items/entity_definitions/catalog_item.json"
  end
end
