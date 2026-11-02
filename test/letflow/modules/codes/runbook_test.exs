defmodule Letflow.Modules.Codes.RunbookTest do
  @moduledoc """
  GH #3588 / REQ-648 criterion 10 (tests B-1..B-4): `docs/runbooks/wms-foundation.md` has the
  "Codes module limits" section with a numbered list, and every limit names a GH number or a
  code path that exists on this checkout. Scoped to the Codes section only (the Org and Catalog
  sections have their own tests). The section cites symbols and plain paths, never line numbers.
  No network and no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @runbook Path.expand("../../../../docs/runbooks/wms-foundation.md", __DIR__)
  @root Path.expand("../../../..", __DIR__)
  @heading "## Codes module limits"

  @path_re ~r{`?((?:lib|priv|test|docs|config)/[A-Za-z0-9_./-]+\.[a-z]+[a-z0-9]*)`?}
  @gh_re ~r/GH #(\S+)/

  # Returns the numbered items of the section as `[{number, text}]`.
  defp items do
    lines = @runbook |> File.read!() |> String.split("\n")

    lines
    |> Enum.drop_while(&(&1 != @heading))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.reduce([], fn line, acc ->
      case {Regex.run(~r/^(\d+)\. (.*)$/, line), acc} do
        {[_, n, rest], _} -> [{String.to_integer(n), rest} | acc]
        {nil, [{n, text} | tail]} -> [{n, text <> " " <> String.trim(line)} | tail]
        {nil, []} -> []
      end
    end)
    |> Enum.reverse()
  end

  test "B-1: the file has the exact section heading" do
    assert @runbook |> File.read!() |> String.split("\n") |> Enum.member?(@heading)
  end

  test "B-2: the section is a numbered list 1..14 with the known limits" do
    numbers = Enum.map(items(), &elem(&1, 0))
    assert numbers == Enum.to_list(1..14)

    text = items() |> Enum.map_join("\n", &elem(&1, 1))

    for word <- [
          "entity_type_managed",
          "/3",
          "REQ-663",
          "D3.6",
          "R1 to R8",
          "uq_code_tag_value",
          "Per-target",
          "trailing space",
          "partial unique",
          "import",
          "OQ-23",
          "print",
          "same 404",
          "allowed?/3"
        ] do
      assert text =~ word, "missing #{word}"
    end
  end

  test "B-3: every limit names a GH number or a code path, and every GH ref is a plain number" do
    for {n, text} <- items() do
      assert Regex.match?(@gh_re, text) or Regex.match?(@path_re, text),
             "limit #{n} cites neither a GH number nor a path"
    end

    refs = for {_n, text} <- items(), [_, ref] <- Regex.scan(@gh_re, text), do: ref
    assert refs != []

    for ref <- refs do
      assert Regex.match?(~r/^\d+[).,;:]*$/, ref), "GH ref #{inspect(ref)} is not a plain number"
    end
  end

  test "B-4: every cited path exists" do
    cited = for {n, text} <- items(), [_, path] <- Regex.scan(@path_re, text), do: {n, path}
    assert cited != []

    for {n, path} <- cited do
      assert File.exists?(Path.join(@root, path)), "limit #{n}: cited path #{path} does not exist"
    end
  end
end
