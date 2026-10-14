defmodule Mix.Tasks.Letflow.CheckScopeNodePathsWriters do
  @shortdoc "Fails when module code names the scope_node_paths table or its internal modules"

  @moduledoc """
  Static writer scan for the `scope_node_paths` security index (REQ-496, decision
  0050 D8; design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §7).

  The table has exactly ONE writer, `Letflow.ScopeNodePaths.write/2`. Module code
  reaches the index only through that module's public functions (`write/2`,
  `lock!/1`, `ancestors/2`, `descendants_of/2`, `like_prefix_pattern/1`), never
  through SQL, the `Letflow.ScopeNodePaths.Node` schema or
  `Letflow.ScopeNodePaths.Consistency`.

  ## Roots and rules

  Scans every regular file, of any extension (`.ex`, `.exs`, `.json`, `.sql`,
  `.lua`, ...), under `lib/letflow/modules` and `priv/modules` (a missing root
  is skipped). A line is a violation when it matches:

    * `:table_name` -- `~r/scope_node_paths/i` anywhere: SQL, a string, an atom,
      or a comment. Module authors must not name the table even in a comment
      or moduledoc.
    * `:internal_module` -- `~r/ScopeNodePaths\\.[A-Z{]/`: the `Node` schema,
      `Consistency`, or a multi-alias, so a module cannot `Repo.insert/update/
      delete` through the schema.

  `Letflow.ScopeNodePaths.write(`, `alias Letflow.ScopeNodePaths` and the other
  public calls pass by construction.

  ## Known limit

  Line-oriented and textual: a table name split across a string concatenation
  (`"scope_" <> "node_paths"`) is not caught. REVIEWER and 0050 D8's "no
  module-side SQL" rule cover that case.

  ## Usage

      mix letflow.check_scope_node_paths_writers

  Wired into `@check_static_steps` (so `mix letflow.check` runs it), with the
  other fast, non-compiling textual scans. `Mix.raise/1` listing every violation
  when any is found.
  """

  use Mix.Task

  @default_roots ["lib/letflow/modules", "priv/modules"]
  @table_name ~r/scope_node_paths/i
  @internal_module ~r/ScopeNodePaths\.[A-Z{]/

  @type violation :: %{
          path: String.t(),
          line: pos_integer(),
          rule: :table_name | :internal_module,
          text: String.t()
        }

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_argv) do
    case scan(@default_roots) do
      [] ->
        Mix.shell().info("scope_node_paths writer scan: no violations")
        :ok

      violations ->
        listing =
          Enum.map_join(violations, "\n", fn v ->
            "  #{v.path}:#{v.line} [#{v.rule}] #{v.text}"
          end)

        Mix.raise(
          "scope_node_paths writer scan: #{length(violations)} violation(s); module code " <>
            "must use only Letflow.ScopeNodePaths' public functions:\n" <> listing
        )
    end
  end

  @doc "Scans every regular file under `roots` (missing roots are skipped)."
  @spec scan(roots :: [Path.t()]) :: [violation()]
  def scan(roots) when is_list(roots) do
    roots
    |> Enum.flat_map(&files_under/1)
    |> Enum.sort()
    |> Enum.flat_map(fn path -> audit(File.read!(path), path) end)
  end

  @doc "The violations in one file's `content`, reported against `path`."
  @spec audit(content :: String.t(), path :: String.t()) :: [violation()]
  def audit(content, path) when is_binary(content) and is_binary(path) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      [table_name: @table_name, internal_module: @internal_module]
      |> Enum.filter(fn {_rule, regex} -> Regex.match?(regex, text) end)
      |> Enum.map(fn {rule, _regex} ->
        %{path: path, line: line, rule: rule, text: String.trim(text)}
      end)
    end)
  end

  defp files_under(root) do
    if File.dir?(root) do
      root
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
    else
      []
    end
  end
end
