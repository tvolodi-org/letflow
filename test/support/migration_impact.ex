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

  @type read :: %{
          file: String.t(),
          line: pos_integer(),
          index: integer() | nil,
          resolved: boolean(),
          judged: boolean()
        }

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
    scan(dir).pins
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

  @doc """
  Every positional read of the tenant manifest the runner saw, with the pin it was judged as.

  A read that no pin judges is a read the class did not cover: the manifest is read by position
  (so the migration it names moves when a migration is appended) but the runner cannot say which
  migration it names. Such a read is reported, never skipped -- the same rule the unresolved
  version follows.
  """
  @spec manifest_reads(String.t()) :: [read()]
  def manifest_reads(dir \\ @test_root) do
    scan(dir).reads
  end

  @doc "The positional manifest reads of the given files."
  @spec reads_in([String.t()]) :: [read()]
  def reads_in(files) do
    files
    |> Enum.flat_map(&file_reads(&1))
    |> Enum.sort_by(&{&1.file, &1.line, &1.index})
  end

  @doc "The positional manifest reads that no pin judges."
  @spec unjudged_reads(String.t()) :: [read()]
  def unjudged_reads(dir \\ @test_root) do
    dir
    |> manifest_reads()
    |> Enum.reject(& &1.judged)
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

  # One scan of the corpus: the manifest-position pins and the positional manifest reads, with
  # each read marked as judged or not. The tree is read once and the result is cached for the
  # life of the VM, so the probe's several questions about the same corpus cost one walk.
  defp scan(dir) do
    case :persistent_term.get({__MODULE__, :scan, dir}, nil) do
      nil ->
        result = build_scan(dir)
        :persistent_term.put({__MODULE__, :scan, dir}, result)
        result

      result ->
        result
    end
  end

  defp build_scan(dir) do
    manifest = manifest()
    files = test_files(dir)

    pins =
      files
      |> Enum.flat_map(&file_pins(&1, manifest))
      |> Enum.sort_by(&{&1.file, &1.line})

    judged = MapSet.new(pins, &{&1.file, &1.line, &1.index})

    reads =
      files
      |> Enum.flat_map(&file_reads(&1))
      |> Enum.sort_by(&{&1.file, &1.line, &1.index})
      |> Enum.map(fn read ->
        Map.put(read, :judged, MapSet.member?(judged, {read.file, read.line, read.index}))
      end)

    %{pins: pins, reads: reads}
  end

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
      manifest_attrs = manifest_attributes(ast)

      ast
      |> collect_pins(file, vars, attributes, manifest_attrs, manifest, [])
      |> Enum.reverse()
    else
      []
    end
  end

  # Every positional read of the manifest in a file. A read the runner cannot judge (a shape it
  # does not read, or a target it cannot resolve to the manifest) is reported with `judged: false`
  # rather than dropped: the count of reads is what proves the class is covered, so a read that
  # vanishes would hide it.
  defp file_reads(file) do
    source = File.read!(file)

    if String.contains?(source, "tenant_scoped_migrations") do
      ast = parse!(source)
      vars = manifest_vars(ast)
      manifest_attrs = manifest_attributes(ast)
      params = parameter_vars(ast)

      ast
      |> collect_reads(file, vars, manifest_attrs, params, [])
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

  # The module attributes a file binds the tenant manifest to (`@manifest TenantProvisioning.
  # tenant_scoped_migrations()`).
  defp manifest_attributes(ast) do
    {_, attrs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, [{name, _, [value]}]} = node, attrs ->
          if manifest_call?(value), do: {node, MapSet.put(attrs, name)}, else: {node, attrs}

        node, attrs ->
          {node, attrs}
      end)

    attrs
  end

  defp manifest_call?({{:., _, [{_alias, _, _}, name]}, _, []}),
    do: name == :tenant_scoped_migrations

  defp manifest_call?(_), do: false

  # The names a file binds as the parameters of its functions. A read whose target is one of
  # them may be a read of the manifest: the manifest arrives through the parameter.
  defp parameter_vars(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:def, _, [head | _]} = node, vars ->
          {node, MapSet.union(vars, head_parameters(head))}

        {:defp, _, [head | _]} = node, vars ->
          {node, MapSet.union(vars, head_parameters(head))}

        node, vars ->
          {node, vars}
      end)

    vars
  end

  # The parameter names of a function head: `defp read_at(manifest)` and its `when` form.
  defp head_parameters({:when, _, [call | _]}), do: head_parameters(call)

  defp head_parameters({_name, _, args}) when is_list(args) do
    args
    |> Enum.filter(&match?({name, _, context} when is_atom(name) and is_atom(context), &1))
    |> Enum.map(fn {name, _, _} -> name end)
    |> MapSet.new()
  end

  defp head_parameters(_), do: MapSet.new()

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

  defp collect_pins(ast, file, vars, attributes, manifest_attrs, manifest, acc) do
    {_, acc} =
      Macro.prewalk(ast, acc, fn
        {:assert, _meta, [{:=, _, [left, right]}]} = node, acc ->
          case pin_of(left, right, file, vars, attributes, manifest_attrs, manifest) do
            nil -> {node, acc}
            pin -> {node, [pin | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # Every positional read of the manifest, whatever shape it is written in: `Enum.at(manifest, -N)`,
  # `List.last(manifest)`, `manifest |> Enum.at(-N)`, `manifest |> List.last()`, and the same calls
  # on a local variable or a module attribute bound to the manifest.
  #
  # A read the runner cannot judge -- the target does not resolve to the manifest (the manifest
  # arrives through a function parameter), or the position is not a literal (the position arrives
  # through a parameter) -- is reported as a read with `resolved: false` rather than skipped: the
  # count of reads is what proves the coverage, so a read that vanished would hide the class.
  defp collect_reads(ast, file, vars, manifest_attrs, params, reads) do
    {_, reads} =
      Macro.prewalk(ast, reads, fn
        node, reads ->
          case read_of(node, file, vars, manifest_attrs, params) do
            nil -> {node, reads}
            read -> {node, [read | reads]}
          end
      end)

    reads
  end

  defp read_of(node, file, vars, manifest_attrs, params) do
    with {:ok, access} <- positional_access(node) do
      resolved = manifest_expression?(access.target, vars, manifest_attrs)

      cond do
        # The target is the manifest and the position is a literal: a positional read the runner
        # can judge.
        resolved and is_integer(access.index) ->
          %{file: file, line: access.line, index: access.index, resolved: true, judged: false}

        # The target is the manifest but the position is not a literal: the runner cannot say
        # which migration the read names.
        resolved ->
          %{file: file, line: access.line, index: access.index, resolved: false, judged: false}

        # The manifest may reach the read (the target is a parameter of the function the read
        # sits in, a module attribute, or a call the manifest is passed to) and the read names a
        # position by counting from the end of the manifest -- a negative index -- or names a
        # position the runner cannot read at all.
        ((is_integer(access.index) and access.index < 0) or access.index == nil) and
            manifest_reaches?(access.target, vars, manifest_attrs, params) ->
          %{file: file, line: access.line, index: access.index, resolved: false, judged: false}

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  # Whether the manifest can reach a read through its target: a parameter of the function the
  # read sits in (a helper receives the manifest as a parameter), a module attribute, or a call
  # the manifest is passed to.
  defp manifest_reaches?({name, _, nil}, _vars, _manifest_attrs, params) when is_atom(name),
    do: MapSet.member?(params, name)

  defp manifest_reaches?({:@, _, [{name, _, nil}]}, _vars, _manifest_attrs, _params)
       when is_atom(name),
       do: true

  defp manifest_reaches?({_, _, args}, vars, manifest_attrs, _params) when is_list(args) do
    Enum.any?(args, &manifest_expression?(&1, vars, manifest_attrs))
  end

  defp manifest_reaches?(_target, _vars, _manifest_attrs, _params), do: false

  defp pin_of(left, right, file, vars, attributes, manifest_attrs, manifest) do
    with {version_expr, module_expr} <- tuple_pattern(left),
         {:ok, access} <- positional_access(right),
         # A pin names the migration at a position the runner can read: a position it cannot
         # read is a read the runner reports (M8), never a pin it judges.
         true <- is_integer(access.index),
         true <- manifest_expression?(access.target, vars, manifest_attrs) do
      version = literal_version(version_expr, attributes)

      %{
        file: file,
        line: access.line,
        index: access.index,
        expected_version: version,
        module: alias_name(module_expr),
        status: status(version, access.index, manifest)
      }
    else
      _ -> nil
    end
  end

  # A two-element tuple literal is a two-element AST tuple; a three-element one is `{:{}, _, _}`.
  defp tuple_pattern({first, second}), do: {first, second}
  defp tuple_pattern({:{}, _, [first, second]}), do: {first, second}
  defp tuple_pattern(_), do: nil

  # A positional read of the manifest, in every shape the corpus writes it:
  # `Enum.at(manifest, -12)`, `List.last(manifest)`, `manifest |> Enum.at(-12)` and
  # `manifest |> List.last()`. The access carries the index it reads, the expression it reads
  # (the thing that must resolve to the manifest) and the line of the read. A position that is
  # not a literal is carried as `nil`: the read is a positional read, but the runner cannot say
  # which one it is.
  defp positional_access({{:., _, [{:__aliases__, _, [:Enum]}, :at]}, meta, [target, index]}) do
    {:ok, %{index: integer_value(index), target: target, line: Keyword.get(meta, :line, 0)}}
  end

  defp positional_access({{:., _, [{:__aliases__, _, [:List]}, :last]}, meta, [target]}) do
    {:ok, %{index: -1, target: target, line: Keyword.get(meta, :line, 0)}}
  end

  defp positional_access({:|, meta, [left, right]}) do
    # `manifest |> Enum.at(-12)` and `manifest |> List.last()`: the piped call carries only the
    # index, the manifest is the left side of the pipe.
    case piped_index(right) do
      {:ok, index} -> {:ok, %{index: index, target: left, line: Keyword.get(meta, :line, 0)}}
      :error -> :error
    end
  end

  defp positional_access(_), do: :error

  # The index a piped positional call reads: `Enum.at(-12)` or `List.last()`. A piped
  # `Enum.at(index)` whose index is not a literal reads a position the runner cannot say.
  defp piped_index({{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [index]}) do
    {:ok, integer_value(index)}
  end

  defp piped_index({{:., _, [{:__aliases__, _, [:List]}, :last]}, _, []}), do: {:ok, -1}
  defp piped_index(_), do: :error

  defp manifest_expression?({{:., _, _}, _, []} = call, _vars, _attributes) do
    manifest_call?(call)
  end

  defp manifest_expression?({name, _, nil}, vars, _attributes) when is_atom(name) do
    MapSet.member?(vars, name)
  end

  # `@manifest TenantProvisioning.tenant_scoped_migrations()`: the attribute holds the manifest.
  defp manifest_expression?({:@, _, [{name, _, nil}]}, _vars, attributes) when is_atom(name) do
    MapSet.member?(attributes, name)
  end

  defp manifest_expression?(_, _vars, _attributes), do: false

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

  # The manifest replay: the files that replay the tenant manifest into a tenant. The family is
  # derived from the tree -- every file that CALLS `TenantProvisioning.replay_migrations/2` -- so a
  # new replay test outside any directory is in the family the moment it is written. A hand-written
  # directory list would silently exclude it, and the required set would not know about a family
  # the class covers.
  defp manifest_replay_files do
    @test_root
    |> test_files()
    |> Enum.filter(fn file ->
      source = File.read!(file)

      String.contains?(source, "replay_migrations") and
        replay_call?(parse!(source))
    end)
  end

  defp replay_call?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:TenantProvisioning]}, :replay_migrations]}, _, _args} = node,
        _found ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Letflow, :TenantProvisioning]}, :replay_migrations]}, _,
         _args} =
            node,
        _found ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found
  end
end
