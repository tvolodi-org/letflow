defmodule Letflow.TeamDbNotTrackedTest do
  @moduledoc """
  T-2706: the agent team's task database does not belong to the product repository.

  `state/team.db` is the SQLite file the agent team keeps its task store in. It is not
  product code, and the product reads nothing from it: the engine opens its own copy in
  the team repository, whose `.gitignore` already ignores `state/`. The file was tracked
  here by mistake since PR #3801 (2026-11-04) and four commits wrote to it.

  This guard pins the three halves of the removal:

    * the file is not tracked (`git ls-files`),
    * the path is ignored (`git check-ignore`), so a later `git add .` cannot put it back,
    * no product source reads it.

  The scan for the third half covers the roots the product runs from -- `lib/`, `priv/`,
  `config/`, `mix.exs` and `scripts/`. A hit in one of the two files of `@not_read_allowlist`
  is text ABOUT the path, not a read of it; a hit anywhere else in those roots is a reader
  and fails. `test/` and `docs/` are outside the scan: a test may build a fixture of the
  same name in a temporary directory, and a document may name the path in prose.

  Pure: no database, no network, no clock.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @db_path "state/team.db"
  @needle "team.db"

  @source_roots ["lib", "priv", "config", "mix.exs", "scripts"]

  # Files that may NAME the path without reading it. Each key is an exact tracked path
  # and the reason says why the mention is text, not a reader.
  @not_read_allowlist %{
    "scripts/oss_audit/README.md" =>
      "documents that the scanner opens SQLite files; the path is its example, not an input",
    "scripts/companion/move_list.tsv" =>
      "lists the path in the companion-repository migration as a file to drop, not to copy"
  }

  test "the team's task database is not tracked by the product repository" do
    assert git(["ls-files", "--", @db_path]) == "",
           "#{@db_path} is tracked again: the product repository carries no team task store"
  end

  test "the team's task database path is ignored, so it cannot be added back" do
    {out, code} = System.cmd("git", ["check-ignore", "--no-index", "-v", @db_path], cd: @root)

    assert code == 0,
           "git does not ignore #{@db_path} (exit #{code}): a `git add .` would track it again: #{out}"
  end

  test "no product source reads the team's task database" do
    hits = grep_hits()

    readers =
      Enum.reject(hits, fn {path, _line} -> Map.has_key?(@not_read_allowlist, path) end)

    assert readers == [],
           "a product source names #{@db_path}: " <>
             Enum.map_join(readers, ", ", fn {path, line} -> "#{path}:#{line}" end)

    # The scan itself must reach the sources, or "no hit" would prove nothing.
    assert grep_hits("defmodule Letflow.") != [],
           "the source scan found nothing at all: it cannot prove that nothing reads #{@db_path}"
  end

  # [{path, line}] for every tracked source that names the needle.
  defp grep_hits(needle \\ @needle) do
    {out, code} =
      System.cmd("git", ["grep", "-n", "-I", "-F", "-e", needle, "--" | @source_roots], cd: @root)

    case code do
      0 -> parse_hits(out)
      1 -> []
      other -> raise "git grep exited #{other}: #{out}"
    end
  end

  defp parse_hits(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [path, number] = String.split(line, ":", parts: 2)
      {path, number}
    end)
  end

  defp git(args) do
    {out, code} = System.cmd("git", args, cd: @root, stderr_to_stdout: true)
    if code == 0, do: out, else: raise("git #{Enum.join(args, " ")} exited #{code}: #{out}")
  end
end
