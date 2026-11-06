defmodule Letflow.Modules.Assets.RunbookTest do
  @moduledoc """
  REQ-749 / GH #3893 criterion 6 (A8-RUN-1): `docs/runbooks/wms-foundation.md` has the "Assets module
  limits" section with the four limits, and `docs/roles.md` names the four atoms. No network and no
  database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @runbook Path.expand("../../../../docs/runbooks/wms-foundation.md", __DIR__)
  @roles Path.expand("../../../../docs/roles.md", __DIR__)
  @heading "## Assets module limits"

  defp section do
    @runbook
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != @heading))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.join("\n")
  end

  test "A8-RUN-1 the section follows the Stock section and lists four limits" do
    lines = @runbook |> File.read!() |> String.split("\n")
    assert Enum.member?(lines, @heading)

    assert Enum.find_index(lines, &(&1 == "## Stock module limits")) <
             Enum.find_index(lines, &(&1 == @heading))

    text = section()

    numbers =
      Regex.scan(~r/^(\d+)\. /m, text) |> Enum.map(&(&1 |> List.last() |> String.to_integer()))

    assert numbers == [1, 2, 3, 4]

    for word <- ~w(REQ-752 L7 L6 OQ-21 C19 3893 AssetsPost AssetsReconcile),
        do: assert(text =~ word)

    for [path] <- Regex.scan(~r{`((?:lib|docs)/[A-Za-z0-9_./-]+\.[a-z]+)`}, text) do
      assert File.exists?(Path.expand("../../../../" <> path, __DIR__)), path
    end
  end

  test "A8-RUN-2 docs/roles.md names the four atoms with no role grants" do
    text = File.read!(@roles)
    assert text =~ "Module `assets` (GH #3893, REQ-749)"

    for atom <- ~w(AssetsPost AssetsReverse AssetsRead AssetsReconcile),
        do: assert(text =~ "`#{atom}`")
  end
end
