defmodule Letflow.Modules.Stock.RunbookTest do
  @moduledoc """
  REQ-687 / GH #3707 criterion 9 (T-RUN-1..3): `docs/runbooks/wms-foundation.md` has the
  "Stock module limits" section with a numbered list, every item names a GH number or an existing
  path. Scoped to the Stock section only. No network and no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @runbook Path.expand("../../../../docs/runbooks/wms-foundation.md", __DIR__)
  @root Path.expand("../../../..", __DIR__)
  @heading "## Stock module limits"

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

  test "T-RUN-1: the file has the exact section heading, after the Codes section" do
    lines = @runbook |> File.read!() |> String.split("\n")
    assert Enum.member?(lines, @heading)

    assert Enum.find_index(lines, &(&1 == "## Codes module limits")) <
             Enum.find_index(lines, &(&1 == @heading))
  end

  test "T-RUN-2: the section is a numbered list 1..12 with the required limits" do
    assert Enum.map(items(), &elem(&1, 0)) == Enum.to_list(1..12)
    text = items() |> Enum.map_join("\n", &elem(&1, 1))

    for word <-
          ~w(L7 OQ-20 OQ-13 OQ-23 REQ-679 L5 404 REQ-682 OQ-11 export T-LD-1 3772 ledger_seq) ++
            [
              "NOT enabled for a customer tenant until L6",
              "one chunk",
              "owner may change at GATE B"
            ] do
      assert text =~ word, "missing #{word}"
    end
  end

  test "T-RUN-3: every item cites a GH number or a path, GH refs are plain, cited paths exist" do
    for {n, text} <- items() do
      assert Regex.match?(@gh_re, text) or Regex.match?(@path_re, text),
             "limit #{n} cites nothing"
    end

    for {_n, text} <- items(), [_, ref] <- Regex.scan(@gh_re, text) do
      assert Regex.match?(~r/^\d+[).,;:]*$/, ref)
    end

    cited = for {n, text} <- items(), [_, path] <- Regex.scan(@path_re, text), do: {n, path}
    assert cited != []

    for {n, path} <- cited do
      assert File.exists?(Path.join(@root, path)), "limit #{n}: #{path} does not exist"
    end

    refute Enum.any?(items(), fn {_n, text} -> text =~ ~r/\.ex:\d+/ end)
  end
end
