defmodule Letflow.Support.MigrationImpact do
  @moduledoc """
  G-09: the migration impact runner (team coverage map, `docs/security-coverage.md` §4, gap G-09).

  A tenant-scoped migration is appended to `Letflow.TenantProvisioning`'s manifest, and every test
  that pins a *position* of that manifest (`Enum.at(manifest, -12)`, `List.last(manifest)`) then
  pins the wrong migration. T-2588's deep gate found two such files that the changed-path test
  mapping never selected, so the breakage stayed invisible until the heavy pin tests ran in CI --
  and the two files it did run were only two of the family.

  This module derives, from the tree alone and without a database:

    * the tenant-scoped migration manifest and the position every migration holds in it;
    * every manifest-position pin of the test corpus (file, line, index, expected version);
    * the test files a migration change must run: the position pins, the tenant table oracle
      comparisons and the manifest replay / existing-row cases.

  The derivation is mechanical on purpose: a pin that the scanner cannot read is reported as
  `:unresolved` instead of being skipped, so the probe fails closed rather than passing on an
  inventory it did not really read.
  """

  @test_root "test"
  @fixture_root "test/fixtures"

  @type entry :: %{version: pos_integer(), module: module(), filename: String.t() | nil}

  @type pin :: %{
          file: String.t(),
          line: pos_integer(),
          index: integer(),
          expected_version: pos_integer() | nil,
          module: String.t(),
          status: :current | :stale | :unresolved
        }

  @type family :: :position_pins | :table_oracle | :manifest_replay

  # ---------------------------------------------------------------- the manifest

  @doc """
  The tenant-scoped migration manifest in manifest order: the version, the module and the
  migration file. The versions come from the public API
  (`Letflow.TenantProvisioning.tenant_scoped_migrations/0`); the file name comes from the
  migration directory, matched by module name.
  """
  @spec manifest() :: [entry()]
  def manifest do
    case :persistent_term.get({__MODULE__, :manifest}, nil) do
      nil ->
        entries = build_manifest()
        :persistent_term.put({__MODULE__, :manifest}, entries)
        entries

      entries ->
        entries
    end
  end

  @doc """
  The entry the manifest holds at `index`, the way `Enum.at(manifest, index)` reads it: a negative
  index counts from the end (`-1` is the last entry).
  """
  @spec entry_at([entry()], integer()) :: entry() | nil
  def entry_at(manifest, index) do
    Enum.at(manifest, index)
  end

  # ------------------------------------------------------------- the position pins

  @doc """
  Every manifest-position pin of the test corpus under `dir`: an assertion that takes one entry
  of the tenant migration manifest *by position*. Such a pin names a migration that stops being
  the one at that position as soon as a migration is appended to the manifest.
  """
  @spec position_pins(String.t()) :: [pin()]
  def position_pins(dir \\ @test_root) do
    dir |> test_files() |> position_pins_in()
  end

  @doc """
  The manifest-position pins of the given files. The files are read as they are: a fixture that
  is not named `*_test.exs` can be judged with it.
  """
  @spec position_pins_in([String.t()]) :: [pin()]
  def position_pins_in(files) do
    manifest = manifest()

    files
    |> Enum.flat_map(&file_pins(&1, manifest))
    |> Enum.sort_by(&{&1.file, &1.line})
  end

  @doc "The position pins that no longer name the migration the manifest holds at their index."
  @spec stale_position_pins(String.t()) :: [pin()]
  def stale_position_pins(dir \\ @test_root) do
    dir
    |> position_pins()
    |> Enum.filter(&(&1.status == :stale))
  end

  @doc "The position pins whose expected version the scanner could not read."
  @spec unresolved_position_pins(String.t()) :: [pin()]
  def unresolved_position_pins(dir \\ @test_root) do
    dir
    |> position_pins()
    |> Enum.filter(&(&1.status == :unresolved))
  end

  @doc """
  The impact of a manifest change: for every position pin, the entry it named before and the
  entry it names after. A pin whose two entries differ is broken by the change.
  """
  @spec impact([pin()], [entry()], [entry()]) :: [
          %{pin: pin(), before: entry() | nil, after: entry() | nil}
        ]
  def impact(pins, old_manifest, new_manifest) do
    Enum.map(pins, fn pin ->
      %{
        pin: pin,
        before: entry_at(old_manifest, pin.index),
        after: entry_at(new_manifest, pin.index)
      }
    end)
  end

  @doc "The position pins the manifest change breaks (the entry they name moved)."
  @spec broken_pins([pin()], [entry()], [entry()]) :: [
          %{pin: pin(), before: entry() | nil, after: entry() | nil}
        ]
  def broken_pins(pins, old_manifest, new_manifest) do
    pins
    |> impact(old_manifest, new_manifest)
    |> Enum.filter(fn change ->
      before_version = change.before && change.before.version
      after_version = change.after && change.after.version
      before_version != after_version
    end)
  end

  # ------------------------------------------------------- the required test files

  @doc """
  The test files a migration change must run, by family:

    * `:position_pins` -- the files that pin a position of the manifest;
    * `:table_oracle` -- the files that compare a tenant's table set with the tenant table
      oracle (`TenantFixture.expected_tenant_tables/0`), the oracle a new tenant table changes;
    * `:manifest_replay` -- the files that replay the tenant manifest into a tenant, the case
      that proves the existing rows survive a migration.
  """
  @spec required_test_files() :: %{family() => [String.t()]}
  def required_test_files do
    %{
      position_pins:
        @test_root
        |> position_pins()
        |> Enum.map(& &1.file)
        |> Enum.uniq()
        |> Enum.sort(),
      table_oracle: table_oracle_files(),
      manifest_replay: manifest_replay_files()
    }
  end

  @doc "Every required test file, sorted and without duplicates."
  @spec required_test_file_list() :: [String.t()]
  def required_test_file_list do
    required_test_files()
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The required test files that `selected` does not run."
  @spec missing_test_files([String.t()], [String.t()]) :: [String.t()]
  def missing_test_files(required, selected) do
    selected = MapSet.new(selected)

    Enum.reject(required, &MapSet.member?(selected, &1))
  end

  # ------------------------------------------------------------- the tree scanning

  @doc "The test files of `dir` (the fixtures are not tests)."
  @spec test_files(String.t()) :: [String.t()]
  def test_files(dir) do
    dir
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, @fixture_root))
    |> Enum.sort()
  end

  defp build_manifest do
    files = migration_files() |> Map.new()

    Enum.map(Letflow.TenantProvisioning.tenant_scoped_migrations(), fn {version, module} ->
      %{version: version, module: module, filename: Map.get(files, module_name(module))}
    end)
  end

  # The module name without the `Elixir.` prefix, the way the migration files spell it.
  defp module_name(module) when is_atom(module) do
    module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp migration_files do
    for path <- Path.wildcard("priv/repo/migrations/*.exs"),
        {:ok, source} <- [File.read(path)],
        match = Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)\s+do/, source),
        is_list(match) do
      [_, name] = match
      {name, path}
    end
  end

  defp file_pins(file, manifest) do
    source = File.read!(file)

    if String.contains?(source, "tenant_scoped_migrations") do
      ast = parse!(source)
      vars = manifest_vars(ast)
      attributes = module_attributes(ast)

      ast
      |> collect_pins(file, vars, attributes, manifest, [])
      |> Enum.reverse()
    else
      []
    end
  end

  defp parse!(source) do
    Code.string_to_quoted!(source,
      columns: true,
      token_metadata: true,
      emit_warnings: false
    )
  end

  # The local variables a file binds the tenant manifest to.
  defp manifest_vars(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:=, _, [{name, _, nil}, value]} = node, vars ->
          if manifest_call?(value), do: {node, MapSet.put(vars, name)}, else: {node, vars}

        node, vars ->
          {node, vars}
      end)

    vars
  end

  defp manifest_call?({{:., _, [{_alias, _, _}, name]}, _, []}),
    do: name == :tenant_scoped_migrations

  defp manifest_call?(_), do: false

  # The module attributes a file defines (`@version 20_261_121_100_001`). A name that is defined
  # twice with different values is left out: the pin that uses it cannot be read.
  defp module_attributes(ast) do
    {_, attributes} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, attributes when is_integer(value) ->
          case Map.get(attributes, name) do
            nil -> {node, Map.put(attributes, name, value)}
            ^value -> {node, attributes}
            _other -> {node, Map.delete(attributes, name)}
          end

        node, attributes ->
          {node, attributes}
      end)

    attributes
  end

  defp collect_pins(ast, file, vars, attributes, manifest, acc) do
    {_, acc} =
      Macro.prewalk(ast, acc, fn
        {:assert, meta, [{:=, _, [left, right]}]} = node, acc ->
          case pin_of(left, right, meta, file, vars, attributes, manifest) do
            nil -> {node, acc}
            pin -> {node, [pin | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp pin_of(left, right, meta, file, vars, attributes, manifest) do
    with {version_expr, module_expr} <- tuple_pattern(left),
         {:ok, index, expr} <- position_call(right),
         true <- manifest_expression?(expr, vars) do
      version = literal_version(version_expr, attributes)

      %{
        file: file,
        line: Keyword.get(meta, :line, 0),
        index: index,
        expected_version: version,
        module: alias_name(module_expr),
        status: status(version, index, manifest)
      }
    else
      _ -> nil
    end
  end

  # A two-element tuple literal is a two-element AST tuple; a three-element one is `{:{}, _, _}`.
  defp tuple_pattern({first, second}), do: {first, second}
  defp tuple_pattern({:{}, _, [first, second]}), do: {first, second}
  defp tuple_pattern(_), do: nil

  # `Enum.at(manifest, -12)` and `List.last(manifest)`.
  defp position_call({{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [expr, index]}) do
    case integer_value(index) do
      nil -> :error
      value -> {:ok, value, expr}
    end
  end

  defp position_call({{:., _, [{:__aliases__, _, [:List]}, :last]}, _, [expr]}) do
    {:ok, -1, expr}
  end

  defp position_call(_), do: :error

  defp manifest_expression?({{:., _, _}, _, []} = call, _vars) do
    manifest_call?(call)
  end

  defp manifest_expression?({name, _, nil}, vars) when is_atom(name) do
    MapSet.member?(vars, name)
  end

  defp manifest_expression?(_, _), do: false

  # The version a pin expects: a literal, or the value of a module attribute.
  defp literal_version(value, _attributes) when is_integer(value), do: value

  defp literal_version({:@, _, [{name, _, nil}]}, attributes) when is_atom(name) do
    Map.get(attributes, name)
  end

  defp literal_version({:@, _, [{name, _, [value]}]}, _attributes) when is_integer(value) do
    _ = name
    value
  end

  defp literal_version({:__block__, _, [value]}, _attributes) when is_integer(value), do: value

  defp literal_version(_value, _attributes), do: nil

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value({:-, _, [value]}) when is_integer(value), do: -value
  defp integer_value({:__block__, _, [value]}) when is_integer(value), do: value
  defp integer_value(_), do: nil

  defp status(nil, _index, _manifest), do: :unresolved

  defp status(version, index, manifest) do
    case entry_at(manifest, index) do
      %{version: ^version} -> :current
      _ -> :stale
    end
  end

  defp alias_name({:__aliases__, _, parts}) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end

  defp alias_name(_), do: ""

  # The tenant table oracle: the files that use it in a way other than a membership check.
  defp table_oracle_files do
    @test_root
    |> test_files()
    |> Enum.filter(fn file ->
      source = File.read!(file)

      if String.contains?(source, "expected_tenant_tables") do
        ast = parse!(source)
        uses = oracle_uses(ast)
        membership = oracle_membership_uses(ast)

        uses > membership
      else
        false
      end
    end)
  end

  defp oracle_uses(ast) do
    {_, count} =
      Macro.prewalk(ast, 0, fn
        {{:., _, [{:__aliases__, _, [:TenantFixture]}, :expected_tenant_tables]}, _, []} = node,
        count ->
          {node, count + 1}

        node, count ->
          {node, count}
      end)

    count
  end

  # `x in TenantFixture.expected_tenant_tables()` is a membership check, not a table-set
  # comparison: it does not break when the oracle grows.
  defp oracle_membership_uses(ast) do
    {_, count} =
      Macro.prewalk(ast, 0, fn
        {:in, _,
         [_left, {{:., _, [{:__aliases__, _, [:TenantFixture]}, :expected_tenant_tables]}, _, []}]} =
            node,
        count ->
          {node, count + 1}

        node, count ->
          {node, count}
      end)

    count
  end

  # The manifest replay: the files that replay the tenant manifest into a tenant.
  defp manifest_replay_files do
    @test_root
    |> test_files()
    |> Enum.filter(fn file ->
      tenant_manifest_family?(file) and
        String.contains?(File.read!(file), "replay_migrations") and
        replay_call?(parse!(File.read!(file)))
    end)
  end

  @replay_families [
    "test/letflow/migrations/",
    "test/letflow/tenant_provisioning"
  ]

  @replay_files [
    "test/letflow/tenant_provisioning_test.exs",
    "test/letflow/support/tenant_fixture_test.exs",
    "test/support/tenant_template_test.exs"
  ]

  defp tenant_manifest_family?(file) do
    Enum.any?(@replay_families, &String.starts_with?(file, &1)) or file in @replay_files
  end

  defp replay_call?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:TenantProvisioning]}, :replay_migrations]}, _, _args} = node,
        _found ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found
  end
end
