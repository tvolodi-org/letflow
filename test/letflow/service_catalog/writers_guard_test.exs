defmodule Letflow.ServiceCatalog.WritersGuardTest do
  @moduledoc """
  GH #2638 T6 (defence in depth, not an acceptance criterion): enumerates the application code
  that WRITES `service_catalog` / `service_catalog_versions`, and fails when a new writer
  appears. The DB CHECK is the real guard; this test makes a new repo-code writer a conscious,
  reviewed addition (it must go through a changeset that refuses a reserved `endpoint_url` and
  maps the DB constraint, see `Letflow.ServiceCatalog.Entry`), instead of a silent one.

  Pure, no DB. Walks `lib/` and `priv/` (`.ex`/`.exs`) with `Code.string_to_quoted` (so comments,
  `@moduledoc` and `@doc` text never produce a hit) and restricts to files that alias
  `Letflow.ServiceCatalog.Entry`/`Version` (or the `ServiceCatalog.{Entry, ...}` form) or that
  name the tables in an executable string; `Dlq.Entry`, `Audit.Entry` and other `Entry` modules
  therefore cause no hits. Design: `lib/letflow/design/gh2638-catalog-endpoint-sys-db-guard.md`
  section 6, T6. Spec: `test/specs/GH-2638.md`.
  """

  use ExUnit.Case, async: true

  @roots ["lib", "priv"]
  @repo_writers ~w(insert insert! insert_all update update! update_all delete delete! delete_all)a
  @table_re ~r/\bservice_catalog(_versions)?\b/
  @sql_writer_re ~r/\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+service_catalog(_versions)?\b/i

  # The complete, reviewed writer set. A mismatch means a new writer: review it, then edit here.
  @expected %{
    "lib/letflow/service_catalog.ex" => %{
      # register/1 and archive_current_version/1 (inside publish/3)
      insert: 2,
      # apply_publish/3, retire/1, update_scope/2
      update: 3,
      # delete/1: versions first ...
      delete_all: 1,
      # ... then the entry
      delete: 1
    },
    # Historic one-shot backfill (`SET published_at = created_at`); never touches endpoint_url and
    # ran before the CHECKs existed.
    # REQ-580 tenant purge: removes the purged tenant's own service_catalog rows (delete_all by tenant_id,
    # no endpoint_url written) and the lifecycle/tenant markers.
    "lib/letflow/tenant_purge.ex" => %{delete_all: 1, update_all: 2},
    "priv/repo/migrations/20260921000004_add_service_catalog_versioning.exs" => %{raw_sql: 1}
  }

  defp source_files do
    root = File.cwd!()

    for dir <- @roots,
        path <- Path.wildcard(Path.join([root, dir, "**", "*.{ex,exs}"])),
        do: path
  end

  defp relative(path), do: path |> Path.relative_to(File.cwd!()) |> String.replace("\\", "/")

  # Drops @moduledoc/@doc/@typedoc so documentation never counts as code.
  defp executable_ast(ast) do
    Macro.prewalk(ast, fn
      {:@, meta, [{attr, _, _}]} when attr in [:moduledoc, :doc, :typedoc] -> {:@, meta, [nil]}
      other -> other
    end)
  end

  defp string_literals(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        bin, acc when is_binary(bin) ->
          {bin, [bin | acc]}

        {:<<>>, _, parts} = node, acc ->
          {node, [Enum.filter(parts, &is_binary/1) |> Enum.join(" ") | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp aliases_catalog_schema?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node,
           acc or
             parts in [[:Letflow, :ServiceCatalog, :Entry], [:Letflow, :ServiceCatalog, :Version]]}

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node, acc ->
          hit =
            Enum.any?(children, fn {:__aliases__, _, rest} ->
              full = base ++ rest
              full in [[:Letflow, :ServiceCatalog, :Entry], [:Letflow, :ServiceCatalog, :Version]]
            end)

          {node, acc or hit}

        {:__aliases__, _, [:Letflow, :ServiceCatalog, mod]} = node, _acc
        when mod in [:Entry, :Version] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # %{fun => count} of Repo/repo writer calls plus Ecto.Multi use in executable code.
  defp repo_writer_counts(ast) do
    {_, counts} =
      Macro.prewalk(ast, %{}, fn
        {{:., _, [{:__aliases__, _, mods}, fun]}, _, _} = node, acc
        when fun in @repo_writers and is_list(mods) ->
          if List.last(mods) == :Repo,
            do: {node, Map.update(acc, fun, 1, &(&1 + 1))},
            else: {node, acc}

        {{:., _, [{var, _, ctx}, fun]}, _, _} = node, acc
        when fun in @repo_writers and var in [:repo, :repo_mod] and is_atom(ctx) ->
          {node, Map.update(acc, fun, 1, &(&1 + 1))}

        {:__aliases__, _, [:Ecto, :Multi]} = node, acc ->
          {node, Map.update(acc, :multi, 1, &(&1 + 1))}

        node, acc ->
          {node, acc}
      end)

    counts
  end

  defp scan do
    for path <- source_files(), reduce: %{} do
      acc ->
        case Code.string_to_quoted(File.read!(path), columns: false) do
          {:ok, ast} ->
            code = executable_ast(ast)
            strings = string_literals(code)

            names_table? = Enum.any?(strings, &Regex.match?(@table_re, &1))
            sql_hits = Enum.count(strings, &Regex.match?(@sql_writer_re, &1))

            relevant? = aliases_catalog_schema?(code) or names_table?
            counts = if relevant?, do: repo_writer_counts(code), else: %{}
            counts = if sql_hits > 0, do: Map.put(counts, :raw_sql, sql_hits), else: counts

            if counts == %{}, do: acc, else: Map.put(acc, relative(path), counts)

          {:error, _} ->
            acc
        end
    end
  end

  test "the only repo-code writer of service_catalog / service_catalog_versions is ServiceCatalog" do
    found = scan()

    assert found == @expected,
           """
           The set of files writing service_catalog / service_catalog_versions changed.
           A new writer must (1) go through a changeset that refuses a reserved `_sys`
           endpoint_url (Entry.insert_changeset/publish_changeset) and maps the DB CHECKs
           (chk_service_catalog_endpoint_url_no_reserved_ref,
           chk_service_catalog_versions_endpoint_url_no_reserved_ref) via check_constraint,
           then be added to @expected here (GH #2638 design section 6, T6).
           expected: #{inspect(@expected)}
           found:    #{inspect(found)}
           """
  end

  test "the scan sees the real writer file (it would otherwise pass vacuously)" do
    assert Map.has_key?(scan(), "lib/letflow/service_catalog.ex")
  end

  test "detector self-check: a synthetic writer is counted, doc text and a foreign Entry are not" do
    writer = """
    defmodule Fake do
      alias Letflow.ServiceCatalog.Entry
      @moduledoc "Repo.insert is mentioned here only"
      def go(cs), do: Repo.insert(cs) && Repo.update_all(Entry, set: [a: 1])
    end
    """

    foreign = """
    defmodule Other do
      alias Letflow.Audit.Entry
      def go(cs), do: Repo.insert(cs)
    end
    """

    {:ok, w} = Code.string_to_quoted(writer)
    {:ok, f} = Code.string_to_quoted(foreign)

    assert aliases_catalog_schema?(executable_ast(w))
    assert repo_writer_counts(executable_ast(w)) == %{insert: 1, update_all: 1}
    refute aliases_catalog_schema?(executable_ast(f))
  end
end
