defmodule Mix.Tasks.Letflow.CheckScopeNodePathsWritersTest do
  @moduledoc """
  REQ-496 / GH #2530 AC6, design `lib/letflow/design/req496-managed-by-and-scope-node-paths.md`
  §7, D12 and §9 T-27, T-26's scan clause (spec `test/specs/REQ-496.md`):
  `mix letflow.check_scope_node_paths_writers`, the static scan `mix letflow.check` runs, fails
  when module code under `lib/letflow/modules` or `priv/modules` names the `scope_node_paths` table
  or reaches past `Letflow.ScopeNodePaths`' public functions, and passes otherwise.

    * PASS: the real default roots scan clean; a seeded file using only the public functions
      (`write(`, `lock!(`, `ancestors(`, `descendants_of(`, `like_prefix_pattern(`, the alias)
      scans clean.
    * FAIL: seeded raw SQL in a `.ex`, an `alias Letflow.ScopeNodePaths.Node`, a `.json` naming the
      table and a `.lua` comment naming it each give a violation with the right rule; `run/1`
      raises `Mix.Error` when the real tree carries one (a probe file placed under `priv/modules`
      for the duration of one test and removed in `on_exit`).

  `async: false`: one test writes a probe file into the real `priv/modules` tree.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Letflow.CheckScopeNodePathsWriters, as: Scan

  @default_roots ["lib/letflow/modules", "priv/modules"]

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    dir =
      Path.join(System.tmp_dir!(), "req496_writer_scan_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp put_file!(dir, relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  test "the real default roots scan clean, and run/1 returns :ok" do
    assert Scan.scan(@default_roots) == []
    assert Scan.run([]) == :ok
    assert_received {:mix_shell, :info, ["scope_node_paths writer scan: no violations"]}
  end

  test "a module using only the public API scans clean", %{dir: dir} do
    put_file!(dir, "lib/letflow/modules/org/tree.ex", """
    defmodule Letflow.Modules.Org.Tree do
      alias Letflow.ScopeNodePaths

      def insert(id, parent, prefix) do
        :ok = Letflow.ScopeNodePaths.lock!(prefix)
        Letflow.ScopeNodePaths.write({:insert, id, parent}, prefix)
      end

      def up(id, prefix), do: ScopeNodePaths.ancestors(id, prefix)
      def down(ids, prefix), do: ScopeNodePaths.descendants_of(ids, prefix)
      def pattern(path), do: ScopeNodePaths.like_prefix_pattern(path)
    end
    """)

    assert Scan.scan([dir]) == []
  end

  test "seeded violations: raw SQL, the Node schema, a JSON and a Lua comment naming the table",
       %{dir: dir} do
    sql =
      put_file!(dir, "lib/letflow/modules/org/raw.ex", """
      defmodule Letflow.Modules.Org.Raw do
        def bump(prefix), do: Letflow.Repo.query!("UPDATE \\"\#{prefix}\\".scope_node_paths SET depth = 1")
      end
      """)

    schema =
      put_file!(dir, "lib/letflow/modules/org/schema_use.ex", """
      defmodule Letflow.Modules.Org.SchemaUse do
        alias Letflow.ScopeNodePaths.Node
        def touch(node, prefix), do: Letflow.Repo.update(Ecto.Changeset.change(node), prefix: prefix)
      end
      """)

    multi =
      put_file!(dir, "lib/letflow/modules/org/multi.ex", """
      defmodule Letflow.Modules.Org.Multi do
        alias Letflow.ScopeNodePaths.{Consistency, Node}
      end
      """)

    json = put_file!(dir, "priv/modules/org/pack.json", ~s|{"table": "SCOPE_NODE_PATHS"}\n|)
    lua = put_file!(dir, "priv/modules/org/hook.lua", "-- writes scope_node_paths directly\n")

    violations = Scan.scan([dir])

    by_path = Enum.group_by(violations, & &1.path, & &1.rule)

    assert by_path[sql] == [:table_name]
    assert by_path[schema] == [:internal_module]
    assert by_path[multi] == [:internal_module]
    assert by_path[json] == [:table_name]
    assert by_path[lua] == [:table_name]
    assert length(violations) == 5

    [sql_violation] = Enum.filter(violations, &(&1.path == sql))
    assert sql_violation.line == 2
    assert sql_violation.text =~ "scope_node_paths"
  end

  test "audit/2 reports every matching line with its number" do
    content = "ok line\nscope_node_paths here\nLetflow.ScopeNodePaths.Node.x()\n"

    assert [
             %{line: 2, rule: :table_name, path: "x.ex"},
             %{line: 3, rule: :internal_module, path: "x.ex"}
           ] = Scan.audit(content, "x.ex")
  end

  test "run/1 raises Mix.Error when the real tree carries a violation" do
    probe_dir =
      Path.join("priv/modules", "req496_writer_scan_probe_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(probe_dir) end)
    File.mkdir_p!(probe_dir)
    File.write!(Path.join(probe_dir, "probe.json"), ~s|{"t": "scope_node_paths"}\n|)

    assert_raise Mix.Error, ~r/scope_node_paths writer scan: 1 violation/, fn -> Scan.run([]) end

    File.rm_rf!(probe_dir)
    assert Scan.scan(@default_roots) == []
  end
end
