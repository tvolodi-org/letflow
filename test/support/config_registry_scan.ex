defmodule Letflow.Support.ConfigRegistryScan do
  @moduledoc """
  G-10: the derivation behind the config/env/flag registry probe.

  The registry (`test/support/security_probe/g10_config_registry.txt`) is the reviewed answer to
  "which configuration does this product have, who owns it, why does it exist, how is it read and
  must its absence fail closed". This module derives the other half **from the tree**: every
  environment variable and every application environment key the sources name, with the form of
  each read (a default or not, compile-time or runtime, a config directive or a read).

  It reads files and parses them with `Code.string_to_quoted!/2`. It starts nothing, opens no
  socket, reads no clock and touches no database, so it is deterministic and costs a couple of
  seconds. A file it cannot parse is a finding, never a silent skip.

  The two shapes it derives:

    * `env` -- an operating system variable. The tree names one in six ways and the derivation
      sees all of them:

      1. a literal: `System.get_env("LETFLOW_SIGNUP_ENABLED")`;
      2. a name a module attribute holds: `@token_env "LETFLOW_SIGNUP_PROVISIONER_TOKEN"` read
         with `System.get_env(@token_env)`;
      3. a name a local variable holds: `name = "LETFLOW_SMTP_HOST"` read with
         `System.get_env(name)`;
      4. a list of names the boot reads: `~w(LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST)` piped
         into `Map.new(fn name -> {name, System.get_env(name)} end)`;
      5. a list of names a module attribute holds: `@env_unset_names ~w(GIT_EXTERNAL_DIFF)`
         read by a function that reads the environment. A list of anything else (the roles, the
         statuses, the formats) is not a list of variables;
      6. a module that parses the operating system environment: it takes a map of variable names
         to raw values (`env`) and reads it with `Map.get/2`, so every upper-case literal of
         that module names a variable of the operating system.

    The **call** that reads a setting is seen in every form the language allows, because a name
    that hides in one of them is a name nobody registered: fully qualified
    (`System.get_env("X")`), `Elixir.`-prefixed (`Elixir.System.get_env("X")`), imported
    (`import System` and then `get_env("X")`) and aliased (`alias System, as: Sys` and then
    `Sys.get_env("X")`). The application environment has the same four forms. An alias and an
    import belong to the scope that writes them (a file, or the body of a module inside it), so
    a definition of one module does not reach the import of another.

    * `app_env` -- an application environment key: `Application.get_env/2,3`,
      `Application.fetch_env/2`, `Application.compile_env/2,3` and the `config :app, :key, value`
      and `config :app, key: value` directives of `config/*.exs`.

  A read whose key is computed at run time cannot be resolved statically; it is reported as
  `dynamic` and needs no registry entry. A read in the default argument of a function head is a
  read like any other: `def f(x \\ System.get_env("X"))` names `X`.
  """

  @registry_path "test/support/security_probe/g10_config_registry.txt"

  @kinds ~w(plain flag guard secret url)
  @reads ~w(compile_time runtime)
  @scopes ~w(platform tenant module test)

  # A documentation attribute is text, never configuration.
  @doc_attributes [:moduledoc, :doc, :typedoc]

  # An attribute that holds the name of an environment variable says so in its own name.
  @env_attribute_suffixes ~w(env var)

  # The parameter of a function that takes the operating system environment as a map.
  @env_param_names [:env, :envs, :env_map, :os_env, :environ, :environment]

  # The map functions that read a map by a key.
  @map_functions [:get, :fetch, :get!, :fetch!]

  # The functions an import of `System` or of `Application` brings into a scope, with the
  # arities each of them answers. A local call is one of them only when the scope imports the
  # module and the arity of the call is one the module answers.
  @imported_functions %{
    "System" => %{get_env: [0, 1, 2], fetch_env: [0, 1, 2], fetch_env!: [0, 1, 2]},
    "Application" => %{get_env: [2, 3], fetch_env: [2], compile_env: [2, 3]}
  }

  @type read_form ::
          :get_env
          | :get_env_default
          | :fetch_env
          | :fetch_env_default
          | :compile_env
          | :compile_env_default
          | :directive
          | :attribute
          | :literal
          | :fallback

  @type site :: %{
          source: :env | :app_env | :dynamic,
          name: String.t() | nil,
          file: String.t(),
          line: pos_integer(),
          form: read_form(),
          default: :none | nil | false | true | :literal | :expression | :absent,
          value: term(),
          test?: boolean()
        }

  @doc """
  The files the inventory is derived from, relative to `root`.

  `lib/**/*.ex` (the design notes under `lib/letflow/design/` are Markdown and are not read),
  `config/*.exs`, the tenant migrations and `mix.exs`.
  """
  @spec source_files(Path.t()) :: [String.t()]
  def source_files(root) when is_binary(root) do
    lib = Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))
    config = Path.wildcard(Path.join([root, "config", "*.exs"]))
    migrations = Path.wildcard(Path.join([root, "priv", "repo", "migrations", "*.exs"]))
    mix = Path.join(root, "mix.exs")

    lib ++ config ++ migrations ++ if(File.exists?(mix), do: [mix], else: [])
  end

  @doc """
  The configuration inventory of the tree at `root`.

  The map has the keys `files` (how many sources were read), `env` and `app_env` (the reads, each
  with its sites), `dynamic` (the reads whose key is computed) and `unparsable` (the sources the
  parser refused).
  """
  @spec inventory(Path.t()) :: %{
          files: non_neg_integer(),
          env: [site()],
          app_env: [site()],
          dynamic: [site()],
          unparsable: [map()]
        }
  def inventory(root) when is_binary(root) do
    files = source_files(root)

    {reads, unparsable} =
      Enum.reduce(files, {[], []}, fn file, {acc, bad} ->
        rel = Path.relative_to(file, root)

        case parse(file) do
          {:ok, ast} ->
            {acc ++ reads_in(ast, rel) ++ config_literal_env_sites(file, rel), bad}

          {:error, reason} ->
            {acc, bad ++ [%{file: rel, reason: reason}]}
        end
      end)

    {env, app_env, dynamic} = split(reads)

    %{
      files: length(files),
      env: env,
      app_env: app_env,
      dynamic: dynamic,
      unparsable: unparsable
    }
  end

  @doc """
  The registry of `root`, as a list of entries, or `{:error, reason}` when it cannot be read.

  The registry is a text file: a header of `#` lines and one line per setting, ten
  pipe-separated columns (see `test/support/security_probe/g10_config_registry.txt`).
  """
  @spec registry(Path.t()) :: {:ok, [map()]} | {:error, String.t()}
  def registry(root) when is_binary(root) do
    path = Path.join(root, @registry_path)

    case File.read(path) do
      {:ok, content} ->
        entries =
          content
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Enum.map(&parse_entry/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, "#{@registry_path} unreadable (#{inspect(reason)})"}
    end
  end

  @doc """
  One registry line, as an entry map. A line that does not have the ten columns is an entry
  without any field, so the shape check reports it instead of the probe reading past it.
  """
  @spec parse_entry(String.t()) :: map()
  def parse_entry(line) do
    case String.split(line, "|", parts: 10) do
      [source, name, owner, scope, read, kind, default, fail_closed, validator, reason] ->
        %{
          "name" => name,
          "source" => source,
          "owner" => owner,
          "scope" => scope,
          "read" => read,
          "kind" => kind,
          "default" => parse_default(default),
          "fail_closed" => fail_closed == "yes",
          "validator" => parse_validator(validator),
          "reason" => reason
        }

      _other ->
        %{"name" => line, "source" => "?", "columns" => false}
    end
  end

  defp parse_default("none"), do: nil
  defp parse_default("false"), do: false
  defp parse_default("true"), do: true

  defp parse_default(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp parse_validator(value), do: value

  @doc """
  Every finding of the probe: a map with `code`, `name` and `detail`.

  An empty list means the tree and the registry agree.
  """
  @spec findings(Path.t()) :: [map()]
  def findings(root) when is_binary(root) do
    findings(inventory(root), root)
  end

  @doc """
  The findings of an inventory that was derived already, without reading the tree again.

  The tree is the expensive half of the probe: a caller that derives the inventory once can ask
  for the findings of that inventory without a second derivation.
  """
  @spec findings(map(), Path.t()) :: [map()]
  def findings(inv, root) when is_map(inv) and is_binary(root) do
    case registry(root) do
      {:ok, entries} -> findings(inv, entries, root)
      {:error, reason} -> [%{code: :registry_unreadable, name: @registry_path, detail: reason}]
    end
  end

  @doc """
  The findings of `inv` against `entries`, without touching the tree again.
  """
  @spec findings(map(), [map()], Path.t()) :: [map()]
  def findings(inv, entries, root) do
    by_name = index(entries)

    registered_env =
      entries |> Enum.filter(&(&1["source"] == "env")) |> MapSet.new(&{"env", &1["name"]})

    registered_app =
      entries |> Enum.filter(&(&1["source"] == "app_env")) |> MapSet.new(&{"app_env", &1["name"]})

    derived_env = MapSet.new(inv.env, &{"env", &1.name})
    derived_app = MapSet.new(inv.app_env, &{"app_env", &1.name})

    env_places = places(inv.env)
    app_places = places(inv.app_env)

    []
    |> add(
      :inventory_is_empty,
      inv.files == 0 or (inv.env == [] and inv.app_env == []),
      "the inventory",
      "the scan read #{inv.files} source(s) and found #{length(inv.env)} environment read(s) " <>
        "and #{length(inv.app_env)} application read(s): the derivation reads nothing"
    )
    |> add(
      :source_not_parsable,
      inv.unparsable != [],
      "the tree",
      Enum.map_join(inv.unparsable, ", ", &"#{&1.file} (#{&1.reason})")
    )
    |> add_many(
      :unregistered_env,
      MapSet.difference(derived_env, registered_env),
      "environment variable",
      env_places
    )
    |> add_many(
      :unregistered_app_env,
      MapSet.difference(derived_app, registered_app),
      "application key",
      app_places
    )
    |> add_many(
      :stale_entry,
      MapSet.difference(registered_env, derived_env),
      "environment variable",
      %{}
    )
    |> add_many(
      :stale_entry,
      MapSet.difference(registered_app, derived_app),
      "application key",
      %{}
    )
    |> check_shape(entries, by_name)
    |> check_read_mode(inv, by_name)
    |> check_flags(inv, by_name, root)
    |> check_guards(inv, by_name)
    |> check_fail_closed(inv, by_name)
    |> check_secrets(inv, by_name, root)
    |> check_urls(inv, by_name, root)
  end

  @doc """
  The findings as a readable block, one line per finding.
  """
  @spec summarize([map()]) :: String.t()
  def summarize(findings) do
    Enum.map_join(findings, "\n", fn f ->
      "#{f.code}: #{f.name}: #{f.detail}"
    end)
  end

  # -- derivation ------------------------------------------------------------

  defp parse(file) do
    {:ok, Code.string_to_quoted!(File.read!(file), columns: true)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  # A configuration file names its environment variables in three ways: `System.get_env("X")`,
  # a helper called with the name (`signup_bool.("LETFLOW_SIGNUP_ENABLED")`) and a list of names
  # (`~w(X Y)`). The second and the third are not calls the parser can follow, so the names of a
  # configuration file are also read from its text: an upper-case word with an underscore in it.
  # A comment line is skipped; the shape leaves no other word in a configuration file.
  defp config_literal_env_sites(file, rel) do
    if String.starts_with?(rel, "config/") or rel == "mix.exs" do
      case File.read(file) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reject(fn {line, _no} -> String.trim(line) |> String.starts_with?("#") end)
          |> Enum.flat_map(fn {line, no} ->
            Regex.scan(~r/"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)"/, line)
            |> Enum.map(fn [_full, name] ->
              %{
                source: :env,
                name: name,
                file: rel,
                line: no,
                form: :literal,
                default: :none,
                value: nil,
                test?: test_file?(rel)
              }
            end)
          end)

        {:error, _reason} ->
          []
      end
    else
      []
    end
  end

  # A test configuration may carry a literal where a release configuration must not.
  defp test_file?(rel) do
    Path.basename(rel) == "test.exs" or String.starts_with?(rel, "test/")
  end

  defp reads_in(ast, rel) do
    test? = test_file?(rel)
    ctx = context(ast)

    walk(ast, rel, ctx, test?) ++ env_map_sites(ast, rel, ctx, test?)
  end

  # What a file binds to names: the module attributes that hold a string, the module attributes
  # that hold a list of environment variables, the local variables that are assigned a string,
  # whether the file parses the operating system environment, the aliases and the imports the
  # file scope holds and the functions it defines itself.
  defp context(ast) do
    scope = scope_of(ast)

    ctx = %{
      attrs: module_attributes(ast),
      locals: local_bindings(ast),
      env_map?: env_map_file?(ast),
      aliases: scope.aliases,
      imports: scope.imports,
      defined: scope.defined
    }

    Map.put(ctx, :env_lists, env_list_attributes(ast, ctx))
  end

  defp module_attributes(ast) do
    {_ast, attrs} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) and is_binary(value) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attrs
  end

  # The module attributes that hold a list of names: `@env_unset_names ~w(GIT_EXTERNAL_DIFF)`.
  defp list_attributes(ast) do
    {_ast, lists} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          case sigil_words(value) do
            nil -> {node, acc}
            words -> {node, Map.put(acc, name, words)}
          end

        node, acc ->
          {node, acc}
      end)

    lists
  end

  defp sigil_words({:sigil_w, _meta, [{:<<>>, _, [words]}, _modifiers]}) when is_binary(words),
    do: words

  defp sigil_words(_value), do: nil

  # A list of names a module attribute holds is a list of environment variables when the code
  # that consumes the attribute reads the environment. A list of anything else (the roles, the
  # statuses, the formats) names something else, and a list of prefixes is not a list of names.
  defp env_list_attributes(ast, ctx) do
    lists = list_attributes(ast)

    if lists == %{} do
      %{}
    else
      funs = functions(ast, ctx)

      for {name, words} <- lists,
          Enum.any?(funs, fn fun -> fun.reads_env? and MapSet.member?(fun.references, name) end),
          into: %{} do
        {name, words}
      end
    end
  end

  # The functions of a file: the module attributes their body names and whether the function
  # reads the operating system environment (in its body or in a default argument of its head).
  defp functions(ast, ctx) do
    {_ast, funs} =
      Macro.prewalk(ast, [], fn
        {kind, _, _args} = node, acc when kind in [:def, :defp, :defmacro, :defmacrop] ->
          {node, [function(node, ctx) | acc]}

        node, acc ->
          {node, acc}
      end)

    funs
  end

  defp function(node, ctx) do
    %{references: attribute_references(node), reads_env?: env_read?(node, ctx)}
  end

  # The module attributes a piece of code names.
  defp attribute_references(node) do
    {_node, names} =
      Macro.prewalk(node, MapSet.new(), fn
        {:@, _, [{name, _, _value}]} = node, acc when is_atom(name) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp local_bindings(ast) do
    {_ast, locals} =
      Macro.prewalk(ast, [], fn
        {:=, meta, [{name, _, nil}, value]} = node, acc when is_atom(name) and is_binary(value) ->
          {node, [{name, line(meta), value} | acc]}

        node, acc ->
          {node, acc}
      end)

    locals
  end

  # A file that parses the operating system environment: a function takes a map of variable
  # names to raw values (`env`) and reads it with `Map.get/2` or `env |> Map.get(key)`.
  defp env_map_file?(ast) do
    params = function_params(ast)
    maps = env_map_reads(ast)

    Enum.any?(params, fn param -> param in @env_param_names and MapSet.member?(maps, param) end)
  end

  defp function_params(ast) do
    {_ast, params} =
      Macro.prewalk(ast, [], fn
        {:def, _, [head | _body]} = node, acc ->
          {node, head_params(head) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(params)
  end

  defp head_params({:when, _, [args | _]}), do: head_params(args)
  defp head_params({_name, _, args}) when is_list(args), do: Enum.flat_map(args, &param_names/1)
  defp head_params(args) when is_list(args), do: Enum.flat_map(args, &param_names/1)
  defp head_params(_other), do: []

  # The arguments of a function head, with the default arguments among them: a read in a
  # default argument is a read like any other.
  defp head_args({:when, _, [call | _guard]}), do: head_args(call)
  defp head_args({_name, _, args}) when is_list(args), do: args
  defp head_args(_other), do: []

  defp param_names({:\\, _, [left | _]}), do: param_names(left)
  defp param_names({name, _, nil}) when is_atom(name), do: [name]
  defp param_names(_other), do: []

  # The variables that are read as a map: the map of a `Map.get/2` call and the source of a
  # `Map.get/1` pipe.
  defp env_map_reads(ast) do
    {_ast, vars} =
      Macro.prewalk(ast, MapSet.new(), fn node, acc ->
        case env_map_read(node) do
          {:ok, var} -> {node, MapSet.put(acc, var)}
          :error -> {node, acc}
        end
      end)

    vars
  end

  defp env_map_read({{:., _, [mod, fun]}, _, [var, _key]}) do
    map_variable(mod, fun, var)
  end

  defp env_map_read({:|>, _, [left, {{:., _, [mod, fun]}, _, [_key]}]}) do
    map_variable(mod, fun, left)
  end

  defp env_map_read(_node), do: :error

  defp map_variable(mod, fun, node) do
    if alias_name(mod) == "Map" and fun in @map_functions do
      case variable_name(node) do
        nil -> :error
        name -> {:ok, name}
      end
    else
      :error
    end
  end

  defp variable_name({name, _, nil}) when is_atom(name), do: name
  defp variable_name(_node), do: nil

  # The reads of a tree. The walker keeps a piped call together with its source, so
  # `x |> Application.get_env(:key, default)` is read as the call it is.
  defp walk(node, rel, ctx, test?) do
    case node do
      {:@, _, [{name, _, [_value]}]} when name in @doc_attributes ->
        []

      {:@, meta, [{name, _, [value]}]} when is_atom(name) and is_binary(value) ->
        if env_attribute?(name, value) do
          [env_site(value, rel, line(meta), :attribute, :none, nil, test?)]
        else
          []
        end

      {:@, meta, [{name, _, [value]}]} when is_atom(name) ->
        attribute_list_sites(ctx, name, rel, line(meta), test?) ++
          walk_all([value], rel, ctx, test?)

      {:def, _, [head | body]} ->
        walk_all(head_args(head), rel, ctx, test?) ++ walk_all(body, rel, ctx, test?)

      {:defmodule, _meta, [_name, body]} ->
        walk_all(children(body), rel, module_ctx(body, ctx), test?)

      {:|>, _, [left, right]} ->
        env_list_sites(left, right, rel, ctx, test?) ++
          walk(left, rel, ctx, test?) ++
          piped(right, left, rel, ctx, test?)

      {{:., _, [mod, fun]}, meta, args} when is_list(args) ->
        call_sites(resolve_module(alias_name(mod), ctx.aliases), fun, args, meta, rel, ctx, test?) ++
          list_arguments(args, meta, rel, ctx, test?) ++
          walk_all(args, rel, ctx, test?)

      {:config, meta, args} when is_list(args) and args != [] ->
        config_sites(args, meta, rel, test?) ++ walk_all(args, rel, ctx, test?)

      {:||, meta, [left, right]} ->
        inner = walk(left, rel, ctx, test?)

        fallbacks =
          for site <- inner, site.form in [:get_env, :fetch_env], site.default == :none do
            %{
              site
              | line: line(meta),
                form: :fallback,
                default: default_kind_of(right),
                value: right
            }
          end

        inner ++ fallbacks ++ walk(right, rel, ctx, test?)

      {fun, meta, args} when is_atom(fun) and is_list(args) ->
        imported_call(fun, args, meta, rel, ctx, test?)

      _ ->
        walk_all(children(node), rel, ctx, test?)
    end
  end

  defp walk_all(nodes, rel, ctx, test?) when is_list(nodes) do
    Enum.flat_map(nodes, &walk(&1, rel, ctx, test?))
  end

  defp walk_all(_nodes, _rel, _ctx, _test?), do: []

  # A piped call: the source of the pipe is the first argument of the call.
  defp piped({{:., _, [mod, fun]}, meta, args}, left, rel, ctx, test?) when is_list(args) do
    call_sites(
      resolve_module(alias_name(mod), ctx.aliases),
      fun,
      [left | args],
      meta,
      rel,
      ctx,
      test?
    ) ++
      walk_all(args, rel, ctx, test?)
  end

  defp piped(right, _left, rel, ctx, test?), do: walk(right, rel, ctx, test?)

  # A call whose module the scope imports: `import System` and then `get_env("X")` is a read of
  # the operating system environment. A call the scope does not import is not one, and a call
  # two modules import is ambiguous, so the reader of it cannot be resolved statically.
  defp imported_call(fun, args, meta, rel, ctx, test?) do
    case imported_module(fun, length(args), ctx) do
      {:ok, module} ->
        call_sites(module, fun, args, meta, rel, ctx, test?) ++ walk_all(args, rel, ctx, test?)

      :ambiguous ->
        [dynamic_site(rel, line(meta), :get_env, test?)] ++ walk_all(args, rel, ctx, test?)

      :none ->
        walk_all(args, rel, ctx, test?)
    end
  end

  defp call_sites("System", fun, args, meta, rel, ctx, test?)
       when fun in [:get_env, :fetch_env, :fetch_env!] do
    case args do
      [name | rest] ->
        case resolve_name(name, ctx, line(meta)) do
          {:ok, resolved} ->
            [
              env_site(
                resolved,
                rel,
                line(meta),
                env_form(fun, rest),
                default_kind(rest),
                default_value(rest),
                test?
              )
            ]

          :error ->
            [dynamic_site(rel, line(meta), :get_env, test?)]
        end

      [] ->
        [dynamic_site(rel, line(meta), :get_env, test?)]
    end
  end

  defp call_sites("Application", fun, args, meta, rel, _ctx, test?)
       when fun in [:get_env, :fetch_env, :compile_env] and length(args) >= 2 do
    [app, key | rest] = args

    case app_env_name(app, key) do
      nil ->
        [dynamic_site(rel, line(meta), app_form(fun, rest), test?)]

      name ->
        [
          app_env_site(
            name,
            rel,
            line(meta),
            app_form(fun, rest),
            default_kind(rest),
            default_value(rest),
            test?
          )
        ]
    end
  end

  defp call_sites(_module, _fun, _args, _meta, _rel, _ctx, _test?), do: []

  # A configuration directive names its key in two forms: `config :app, :key, value` and
  # `config :app, key: value`. The keyword form names every key of the list.
  defp config_sites([_app], _meta, _rel, _test?), do: []

  defp config_sites([app, key], meta, rel, test?) when is_list(key) do
    if keyword?(key) do
      Enum.map(key, fn {name, value} ->
        app_env_site(
          "#{atom_name(app)}:#{name}",
          rel,
          line(meta),
          :directive,
          default_kind_of(value),
          value,
          test?
        )
      end)
    else
      []
    end
  end

  defp config_sites([app, key | rest], meta, rel, test?) do
    case app_env_name(app, key) do
      nil ->
        []

      name ->
        [
          app_env_site(
            name,
            rel,
            line(meta),
            :directive,
            default_kind(rest),
            default_value(rest),
            test?
          )
        ]
    end
  end

  defp keyword?([{name, _value} | rest]) when is_atom(name), do: keyword?(rest)
  defp keyword?([]), do: true
  defp keyword?(_other), do: false

  # A list of names is a list of environment variables when the code that consumes it reads the
  # environment: `~w(LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST) |> Map.new(fn name -> {name,
  # System.get_env(name)} end)`. A list of words that names something else (the roles, the
  # statuses, the formats) is not a list of environment variables.
  defp env_list_sites(
         {:sigil_w, meta, [{:<<>>, _, [words]}, _modifiers]},
         consumer,
         rel,
         ctx,
         test?
       )
       when is_binary(words) do
    if env_read?(consumer, ctx) do
      list_sites(words, meta, rel, test?)
    else
      []
    end
  end

  defp env_list_sites(_node, _consumer, _rel, _ctx, _test?), do: []

  # A list that is an argument of a call that reads the environment.
  defp list_arguments(args, meta, rel, ctx, test?) do
    Enum.flat_map(args, fn
      {:sigil_w, _, [{:<<>>, _, [words]}, _modifiers]} = list when is_binary(words) ->
        if env_read?(list, ctx) or env_read?(args, ctx) do
          list_sites(words, meta, rel, test?)
        else
          []
        end

      _other ->
        []
    end)
  end

  # Does this piece of code read the operating system environment? The scope's own definitions
  # do not hide the answer here: the question is what the code does, not what it calls.
  defp env_read?(node, ctx) do
    ctx = %{ctx | defined: MapSet.new()}

    {_node, found} =
      Macro.prewalk(node, false, fn
        {{:., _, [mod, fun]}, _, args} = node, acc when is_list(args) ->
          {node,
           acc or
             (resolve_module(alias_name(mod), ctx.aliases) == "System" and
                fun in [:get_env, :fetch_env, :fetch_env!])}

        {fun, _meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, acc or imported_read?(fun, length(args), ctx)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # Does this call read the operating system environment through an import?
  defp imported_read?(fun, arity, ctx) do
    match?({:ok, "System"}, imported_module(fun, arity, ctx))
  end

  # A list of names: `~w(LETFLOW_MAIL_ADAPTER LETFLOW_SMTP_HOST)`.
  defp list_sites(words, meta, rel, test?) do
    list_sites_at(words, line(meta), rel, test?)
  end

  defp list_sites_at(words, line_no, rel, test?) do
    words
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&env_name?/1)
    |> Enum.map(fn name -> env_site(name, rel, line_no, :literal, :none, nil, test?) end)
  end

  # The names a module attribute holds, when the code that consumes the attribute reads the
  # environment: they are variables of the operating system.
  defp attribute_list_sites(ctx, name, rel, line_no, test?) do
    case Map.get(ctx.env_lists, name) do
      nil -> []
      words -> list_sites_at(words, line_no, rel, test?)
    end
  end

  # A module that parses the operating system environment names its variables in upper case:
  # every such literal of that file names a variable of the operating system.
  defp env_map_sites(ast, rel, _ctx, test?) do
    if env_map_file?(ast) do
      ast
      |> literals(0)
      |> Enum.filter(fn {value, _line} -> env_name?(value) end)
      |> Enum.map(fn {value, line} -> env_site(value, rel, line, :literal, :none, nil, test?) end)
    else
      []
    end
  end

  # The string literals of a tree, with the line they are on. A documentation attribute is
  # text, never configuration, so it is left out.
  defp literals(node, line) do
    case node do
      {:@, _, [{name, _, [_value]}]} when name in @doc_attributes ->
        []

      {_form, meta, args} when is_list(args) ->
        args
        |> Enum.flat_map(&literals(&1, line(meta)))

      {left, right} ->
        literals(left, line) ++ literals(right, line)

      list when is_list(list) ->
        Enum.flat_map(list, &literals(&1, line))

      value when is_binary(value) ->
        [{value, line}]

      _other ->
        []
    end
  end

  defp children({_form, _meta, args}) when is_list(args), do: args
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_other), do: []

  # The name a read names: a literal, a module attribute that holds it or a local variable that
  # holds it.
  defp resolve_name(value, _ctx, _line) when is_binary(value), do: {:ok, value}

  defp resolve_name({:@, _, [{name, _, nil}]}, ctx, _line) do
    case Map.fetch(ctx.attrs, name) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp resolve_name({name, _, nil}, ctx, use_line) when is_atom(name) do
    resolve_local(name, ctx.locals, use_line)
  end

  defp resolve_name(_expr, _ctx, _line), do: :error

  # The local variable that holds the name: the assignment nearest above the use.
  defp resolve_local(name, locals, use_line) do
    locals
    |> Enum.filter(fn {var, line, _value} -> var == name and line <= use_line end)
    |> Enum.max_by(fn {_var, line, _value} -> line end, &>=/2, fn -> nil end)
    |> case do
      nil -> :error
      {_var, _line, value} -> {:ok, value}
    end
  end

  # An attribute that holds the name of an environment variable says so in its own name.
  defp env_attribute?(name, value) do
    text = Atom.to_string(name)

    Enum.any?(@env_attribute_suffixes, fn suffix ->
      (String.ends_with?(text, "_" <> suffix) or text == suffix) and env_name?(value)
    end)
  end

  @doc false
  # The shape of an environment variable name: an upper-case word with an underscore in it.
  def env_name?(name) when is_binary(name) do
    String.match?(name, ~r/^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$/)
  end

  def env_name?(_name), do: false

  defp env_site(name, file, line, form, default, value, test?) do
    %{
      source: :env,
      name: name,
      file: file,
      line: line,
      form: form,
      default: default,
      value: value,
      test?: test?
    }
  end

  defp app_env_site(name, file, line, form, default, value, test?) do
    %{
      source: :app_env,
      name: name,
      file: file,
      line: line,
      form: form,
      default: default,
      value: value,
      test?: test?
    }
  end

  defp dynamic_site(file, line, form, test?) do
    %{
      source: :dynamic,
      name: nil,
      file: file,
      line: line,
      form: form,
      default: :none,
      value: nil,
      test?: test?
    }
  end

  defp env_form(:get_env, []), do: :get_env
  defp env_form(:get_env, _rest), do: :get_env_default
  defp env_form(:fetch_env, []), do: :fetch_env
  defp env_form(:fetch_env, _rest), do: :fetch_env_default
  defp env_form(:fetch_env!, []), do: :fetch_env
  defp env_form(:fetch_env!, _rest), do: :fetch_env_default

  defp app_form(:get_env, []), do: :get_env
  defp app_form(:get_env, _rest), do: :get_env_default
  defp app_form(:fetch_env, _rest), do: :fetch_env
  defp app_form(:compile_env, []), do: :compile_env
  defp app_form(:compile_env, _rest), do: :compile_env_default

  # The registry name of an application key: an atom keeps its colon, a module keeps its
  # name, a `[module, key]` pair is written `Module:key`.
  defp app_env_name(app, key) do
    app_name = atom_name(app)

    cond do
      is_atom(key) and not is_nil(key) and not is_boolean(key) -> "#{app_name}:#{key}"
      is_atom(key) -> nil
      match?({:__aliases__, _, _}, key) -> "#{app_name}:#{alias_name(key)}"
      match?({:__MODULE__, _, _}, key) -> nil
      is_list(key) and length(key) == 2 -> keyword_name(app_name, key)
      true -> nil
    end
  end

  defp keyword_name(app_name, [module, key]) when is_atom(key) do
    case alias_name(module) do
      nil -> nil
      name -> "#{app_name}:#{name}:#{key}"
    end
  end

  defp keyword_name(_app_name, _key), do: nil

  defp atom_name(app) when is_atom(app), do: inspect(app)
  defp atom_name(app) when is_binary(app), do: app
  defp atom_name(_app), do: nil

  # `Elixir.System` and `System` name the same module, so the prefix carries no information.
  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      parts
      |> Enum.map(&Atom.to_string/1)
      |> case do
        ["Elixir" | rest] -> Enum.join(rest, ".")
        names -> Enum.join(names, ".")
      end
    else
      nil
    end
  end

  defp alias_name(_other), do: nil

  # -- scopes ----------------------------------------------------------------

  # The aliases, the imports and the local definitions of a scope: a file, or the body of a
  # module inside it. A module body is a scope of its own, so the walk does not descend into
  # one: a definition of one module does not reach the import of another.
  defp scope_of(node) do
    {aliases, imports, defined} = scope_walk(node, {%{}, %{}, MapSet.new()})
    %{aliases: aliases, imports: imports, defined: defined}
  end

  defp scope_walk({:defmodule, _meta, _args}, acc), do: acc

  defp scope_walk({form, _meta, args}, acc) when is_list(args) do
    case form do
      :alias -> add_alias(args, acc)
      :import -> add_import(args, acc)
      kind when kind in [:def, :defp, :defmacro, :defmacrop] -> add_definition(args, acc)
      _ -> Enum.reduce(args, acc, &scope_walk/2)
    end
  end

  defp scope_walk({left, right}, acc), do: scope_walk(right, scope_walk(left, acc))
  defp scope_walk(list, acc) when is_list(list), do: Enum.reduce(list, acc, &scope_walk/2)
  defp scope_walk(_other, acc), do: acc

  # An alias names a module under a shorter name: `alias System, as: Sys` makes `Sys` name
  # `System`. Only the two modules the probe reads are kept, so an alias of anything else
  # cannot change what the derivation sees.
  defp add_alias(args, acc) do
    {aliases, imports, defined} = acc

    pairs =
      args
      |> alias_pairs()
      |> Enum.filter(fn {_local, full} -> full in ["System", "Application"] end)

    {
      Enum.reduce(pairs, aliases, fn {local, full}, map -> Map.put(map, local, full) end),
      imports,
      defined
    }
  end

  # `alias System`, `alias System, as: Sys` and `alias Foo.{Bar, Baz}`.
  defp alias_pairs([{{:., _, [base, :{}]}, _meta, parts}]) do
    base_name = alias_name(base)

    Enum.map(parts, fn part ->
      {alias_name(part), "#{base_name}.#{alias_name(part)}"}
    end)
  end

  defp alias_pairs([target]) do
    [{local_alias_name(target), alias_name(target)}]
  end

  defp alias_pairs([target, opts]) when is_list(opts) do
    local =
      case Keyword.get(opts, :as) do
        nil -> local_alias_name(target)
        as -> alias_name(as)
      end

    [{local, alias_name(target)}]
  end

  defp alias_pairs(_args), do: []

  # The name an alias is known by inside its scope: the last segment of the module it names.
  defp local_alias_name({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    parts |> List.last() |> Atom.to_string()
  end

  defp local_alias_name(_other), do: nil

  # An import brings the functions of a module into a scope: `import System` and then
  # `get_env("X")` is a call of `System.get_env/1`.
  defp add_import(args, acc) do
    {aliases, imports, defined} = acc

    case import_spec(args, aliases) do
      nil -> acc
      {module, spec} -> {aliases, Map.put(imports, module, spec), defined}
    end
  end

  # `import System`, `import System, only: [...]` and `import System, except: [...]`.
  defp import_spec([target], aliases) do
    imported_module_spec(alias_name(target), aliases, %{only: nil, except: MapSet.new()})
  end

  defp import_spec([target, opts], aliases) when is_list(opts) do
    imported_module_spec(alias_name(target), aliases, import_options(opts))
  end

  defp import_spec(_args, _aliases), do: nil

  defp imported_module_spec(name, aliases, options) do
    case resolve_module(name, aliases) do
      module when module in ["System", "Application"] -> {module, options}
      _other -> nil
    end
  end

  defp import_options(opts) do
    %{
      only: import_pairs(Keyword.get(opts, :only)),
      except: import_pairs(Keyword.get(opts, :except)) || MapSet.new()
    }
  end

  defp import_pairs(nil), do: nil
  defp import_pairs(list), do: MapSet.new(list, fn {name, arity} -> {name, arity} end)

  # The functions a scope defines itself: a definition of the scope shadows an import of the
  # same name, so the derivation has to know it.
  defp add_definition([head | body], acc) do
    {aliases, imports, defined} = acc
    name = definition_name(head)

    defined =
      if is_nil(name) do
        defined
      else
        Enum.reduce(head_arities(head), defined, fn arity, set ->
          MapSet.put(set, {name, arity})
        end)
      end

    # A directive in the body of a function belongs to that function.
    Enum.reduce(body, {aliases, imports, defined}, &scope_walk/2)
  end

  defp add_definition(_args, acc), do: acc

  defp definition_name({:when, _, [call | _guard]}), do: definition_name(call)
  defp definition_name({name, _, _args}) when is_atom(name), do: name
  defp definition_name(_other), do: nil

  # The arities a function head answers: a default argument counts for the arity without it
  # and for the arity with it.
  defp head_arities({:when, _, [call | _guard]}), do: head_arities(call)

  defp head_arities({_name, _, args}) when is_list(args) do
    required = Enum.count(args, &match?({:"\\", _, _}, &1))
    total = length(args)
    Enum.uniq([total - required, total])
  end

  defp head_arities(_other), do: []

  # The scope of a module body: the scope of the file it is in, with the aliases and the
  # imports of the module itself over it. An import of the module replaces the import of the
  # file for that module: the language narrows an import the same way (`import System` in the
  # file and `import System, only: [get_env: 1]` in the module leaves the module with
  # `get_env/1` alone).
  defp module_ctx(body, ctx) do
    scope = scope_of(body)

    %{
      ctx
      | aliases: Map.merge(ctx.aliases, scope.aliases),
        imports: Map.merge(ctx.imports, scope.imports),
        defined: scope.defined
    }
  end

  # The module a name stands for, with the aliases of the scope applied.
  defp resolve_module(nil, _aliases), do: nil

  defp resolve_module(name, aliases) do
    case Map.fetch(aliases, name) do
      {:ok, target} -> target
      :error -> name
    end
  end

  # The module a local call names, when the scope imports it: `import System` and then
  # `get_env("X")` is a call of `System.get_env/1`. A definition of the scope shadows the
  # import, and a call two modules import is ambiguous, so its reader cannot be resolved.
  defp imported_module(fun, arity, ctx) do
    if MapSet.member?(ctx.defined, {fun, arity}) do
      :none
    else
      candidates =
        ctx.imports
        |> Enum.filter(fn {module, spec} -> import_allows?(spec, module, fun, arity) end)
        |> Enum.map(fn {module, _spec} -> module end)
        |> Enum.uniq()

      case candidates do
        [module] -> {:ok, module}
        [] -> :none
        _many -> :ambiguous
      end
    end
  end

  defp import_allows?(spec, module, fun, arity) do
    arities = Map.get(Map.get(@imported_functions, module, %{}), fun, [])

    arity in arities and
      (is_nil(spec.only) or MapSet.member?(spec.only, {fun, arity})) and
      not MapSet.member?(spec.except, {fun, arity})
  end

  defp split(reads) do
    {env, app_env, dynamic} =
      Enum.reduce(reads, {[], [], []}, fn read, {e, a, d} ->
        case read.source do
          :env -> {e ++ [read], a, d}
          :app_env -> {e, a ++ [read], d}
          :dynamic -> {e, a, d ++ [read]}
        end
      end)

    {env, app_env, dynamic}
  end

  defp default_kind([]), do: :none
  defp default_kind([value | _]), do: default_kind_of(value)

  defp default_kind_of(nil), do: :absent
  defp default_kind_of(false), do: false
  defp default_kind_of(true), do: true

  defp default_kind_of(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: :literal

  defp default_kind_of(value) when is_list(value) do
    if Enum.all?(value, &literal_scalar?/1), do: :literal, else: :expression
  end

  defp default_kind_of(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &literal_scalar?/1) and
         Enum.all?(Map.values(value), &literal_scalar?/1) do
      :literal
    else
      :expression
    end
  end

  defp default_kind_of(_value), do: :expression

  defp literal_scalar?(value), do: is_binary(value) or is_number(value) or is_atom(value)

  defp default_value([]), do: nil
  defp default_value([value | _]), do: value

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_meta), do: 0

  # -- checks ----------------------------------------------------------------

  defp index(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      name = entry["name"]
      source = entry["source"]
      key = "#{source}:#{name}"
      Map.put(acc, key, entry)
    end)
  end

  # Where the tree reads a setting: the places of every read of that name.
  defp places(sites) do
    Enum.group_by(sites, & &1.name)
  end

  defp place_text(sites), do: Enum.map_join(sites, ", ", &"#{&1.file}:#{&1.line}")

  defp add(findings, code, true, name, detail),
    do: findings ++ [%{code: code, name: name, detail: detail}]

  defp add(findings, _code, false, _name, _detail), do: findings

  defp add_many(findings, code, names, label, places) do
    Enum.reduce(Enum.sort(names), findings, fn {source, name}, acc ->
      detail =
        case Map.get(places, name, []) do
          [] -> label
          sites -> label <> ", read at " <> place_text(sites)
        end

      add(acc, code, true, "#{source}:#{name}", detail)
    end)
  end

  defp check_shape(findings, entries, _by_name) do
    duplicates =
      entries
      |> Enum.map(&"#{&1["source"]}:#{&1["name"]}")
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    Enum.reduce(entries, findings, fn entry, acc ->
      name = entry["name"]

      acc
      |> add(
        :malformed_entry,
        entry["columns"] == false,
        entry_name(entry),
        "the entry does not have the ten columns of the registry"
      )
      |> check_field(entry, "name", name, &(is_binary(&1) and String.trim(&1) != ""))
      |> check_field(entry, "source", entry["source"], &(&1 in ["env", "app_env"]))
      |> check_field(entry, "owner", entry["owner"], &(is_binary(&1) and String.trim(&1) != ""))
      |> check_field(entry, "scope", entry["scope"], &(&1 in @scopes))
      |> check_field(entry, "read", entry["read"], &(&1 in @reads))
      |> check_field(entry, "kind", entry["kind"], &(&1 in @kinds))
      |> check_field(entry, "reason", entry["reason"], &reason_ok?/1)
      |> check_field(entry, "default", entry["default"], fn _ -> true end)
      |> check_field(entry, "fail_closed", entry["fail_closed"], &is_boolean/1)
      |> check_field(entry, "validator", entry["validator"], &(&1 == nil or is_binary(&1)))
      |> add(
        :duplicate_entry,
        entry_name(entry) in duplicates,
        entry_name(entry),
        "the registry carries this name twice"
      )
    end)
  end

  defp reason_ok?(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    trimmed != "" and
      not String.starts_with?(trimmed, "TODO") and
      not String.starts_with?(trimmed, "FIXME") and
      not String.ends_with?(trimmed, "?")
  end

  defp reason_ok?(_reason), do: false

  defp check_field(findings, entry, field, value, valid?) do
    if valid?.(value) do
      findings
    else
      add(
        findings,
        :malformed_entry,
        true,
        entry_name(entry),
        "the field \"#{field}\" is not usable"
      )
    end
  end

  defp entry_name(entry), do: "#{entry["source"]}:#{entry["name"]}"

  defp check_read_mode(findings, inv, by_name) do
    compile_time =
      inv.app_env
      |> Enum.filter(&(&1.form in [:compile_env, :compile_env_default]))
      |> MapSet.new(& &1.name)

    runtime =
      inv.app_env
      |> Enum.filter(&(&1.form not in [:compile_env, :compile_env_default, :directive]))
      |> MapSet.new(& &1.name)

    read_as_runtime =
      compile_time
      |> Enum.filter(fn name ->
        entry = Map.get(by_name, "app_env:#{name}")

        entry != nil and entry["read"] != "compile_time"
      end)
      |> Enum.sort()

    read_as_compile_time =
      runtime
      |> Enum.filter(fn name ->
        entry = Map.get(by_name, "app_env:#{name}")

        entry != nil and entry["read"] == "compile_time"
      end)
      |> Enum.sort()

    acc =
      Enum.reduce(read_as_runtime, findings, fn name, acc ->
        add(
          acc,
          :read_mode_mismatch,
          true,
          "app_env:#{name}",
          "the key #{name} is read with Application.compile_env/2 but registered as a runtime read"
        )
      end)

    Enum.reduce(read_as_compile_time, acc, fn name, acc ->
      add(
        acc,
        :read_mode_mismatch,
        true,
        "app_env:#{name}",
        "the key #{name} is registered as a compile_time read but not read with " <>
          "Application.compile_env/2"
      )
    end)
  end

  defp check_flags(findings, inv, by_name, root) do
    flags = by_name |> Map.values() |> Enum.filter(&(&1["kind"] == "flag"))

    Enum.reduce(flags, findings, fn entry, acc ->
      name = entry["name"]

      acc
      |> add(
        :flag_not_off,
        entry["default"] != false,
        "#{entry["source"]}:#{name}",
        "a feature flag must default off, the registry says #{inspect(entry["default"])}"
      )
      |> add(
        :flag_not_off,
        Enum.any?(reads_of_name(inv, entry["source"], name), &enabling_default?/1),
        "#{entry["source"]}:#{name}",
        "a feature flag must not be read with a default that enables it"
      )
      |> add(
        :flag_not_off,
        enabled_in_release_config?(root, name),
        "#{entry["source"]}:#{name}",
        "a feature flag must not be switched on by a release configuration"
      )
    end)
  end

  # A read site that enables the setting when it is absent. A directive is the configuration
  # file setting the value, not a fallback, and a test build may turn a switch on.
  defp enabling_default?(site) do
    site.form != :directive and not site.test? and site.default == true
  end

  # A default that takes effect when the setting is absent. Only what the probe can see counts:
  # a literal that is not empty. An expression default is not judged here; the reason names it.
  defp permissive_default?(site) do
    case site.default do
      true -> true
      :literal -> takes_effect?(site.value)
      _ -> false
    end
  end

  defp takes_effect?(nil), do: false
  defp takes_effect?(""), do: false
  defp takes_effect?([]), do: false
  defp takes_effect?(%{}), do: false
  defp takes_effect?(false), do: false
  defp takes_effect?(_value), do: true

  # A release configuration is one of the three files the application boots with. The whole
  # file is walked, not its root expression: a release configuration is a block of directives.
  defp enabled_in_release_config?(root, name) do
    release_config =
      Path.wildcard(Path.join([root, "config", "*.exs"]))
      |> Enum.filter(&(Path.basename(&1) in ["config.exs", "prod.exs", "runtime.exs"]))

    Enum.any?(release_config, fn file ->
      rel = Path.relative_to(file, root)

      case parse(file) do
        {:ok, ast} ->
          Enum.any?(reads_in(ast, rel), fn read ->
            read.source == :app_env and read.name == name and read.form == :directive and
              read.value == true
          end)

        {:error, _reason} ->
          false
      end
    end)
  end

  # A guard is a safety switch: it must be on when it is absent, so its default is true and no
  # read site may hand it a default that turns it off.
  defp check_guards(findings, inv, by_name) do
    by_name
    |> Map.values()
    |> Enum.filter(&(&1["kind"] == "guard"))
    |> Enum.reduce(findings, fn entry, acc ->
      name = entry["name"]

      acc
      |> add(
        :guard_not_on,
        entry["default"] != true,
        "#{entry["source"]}:#{name}",
        "a guard must default on, the registry says #{inspect(entry["default"])}"
      )
      |> add(
        :guard_not_on,
        Enum.any?(
          reads_of_name(inv, entry["source"], name),
          &(&1.form != :directive and not &1.test? and &1.default in [:none, :absent, false])
        ),
        "#{entry["source"]}:#{name}",
        "a guard must not be read with a default that turns it off"
      )
    end)
  end

  defp check_fail_closed(findings, inv, by_name) do
    by_name
    |> Map.values()
    |> Enum.filter(&(&1["fail_closed"] == true))
    |> Enum.reduce(findings, fn entry, acc ->
      name = entry["name"]

      permissive =
        reads_of_name(inv, entry["source"], name)
        |> Enum.filter(&(not &1.test? and &1.form != :directive and permissive_default?(&1)))

      add(
        acc,
        :fail_closed_permissive,
        permissive != [],
        "#{entry["source"]}:#{name}",
        "a fail-closed setting must not be read with a default that takes effect when it is absent"
      )
    end)
  end

  defp check_secrets(findings, inv, by_name, root) do
    by_name
    |> Map.values()
    |> Enum.filter(&(&1["kind"] == "secret"))
    |> Enum.reduce(findings, fn entry, acc ->
      name = entry["name"]

      acc
      |> add(
        :secret_literal_default,
        entry["default"] != nil,
        "#{entry["source"]}:#{name}",
        "a secret comes by reference: the registry must not carry a default for it"
      )
      |> add(
        :secret_literal_default,
        Enum.any?(
          reads_of_name(inv, entry["source"], name),
          &(&1.default == :literal and not &1.test?)
        ),
        "#{entry["source"]}:#{name}",
        "a secret must not be read with a literal default"
      )
      |> add(
        :secret_literal_default,
        literal_secret_value?(root, name),
        "#{entry["source"]}:#{name}",
        "a secret must not have a literal value in the tree"
      )
    end)
  end

  # A literal value for a secret environment variable: the name appears in a non-test file with
  # a string after it (`LETFLOW_SECRETS_MASTER_KEY: "..."`, `LETFLOW_X = "..."`).
  defp literal_secret_value?(root, name) do
    pattern = ~r/#{Regex.escape(name)}\s*[:=]\s*"[^"]+"/

    files =
      Path.wildcard(Path.join([root, "config", "*.exs"])) ++
        Path.wildcard(Path.join([root, "lib", "**", "*.ex"]))

    files
    |> Enum.reject(&(Path.basename(&1) == "test.exs"))
    |> Enum.any?(fn file ->
      case File.read(file) do
        {:ok, content} -> Regex.match?(pattern, content)
        {:error, _reason} -> false
      end
    end)
  end

  defp check_urls(findings, inv, by_name, root) do
    by_name
    |> Map.values()
    |> Enum.filter(&(&1["kind"] == "url"))
    |> Enum.reduce(findings, fn entry, acc ->
      name = entry["name"]
      validator = entry["validator"]

      acc
      |> add(
        :url_without_validator,
        is_nil(validator) or String.trim(validator) == "",
        "#{entry["source"]}:#{name}",
        "a URL setting must say how it is validated"
      )
      |> check_url_validator(root, entry, inv)
    end)
  end

  # The validator of a URL is a module of the tree, or `none` for an address no tenant can
  # point elsewhere: the operator sets it, so no tenant-controlled outbound fetch happens.
  # A sentinel that names no module is not a validation: it is an unbacked claim.
  defp check_url_validator(findings, root, entry, _inv) do
    validator = entry["validator"]
    name = "#{entry["source"]}:#{entry["name"]}"

    cond do
      is_nil(validator) or validator == "none" ->
        findings

      validator == "startup" ->
        add(
          findings,
          :url_without_validator,
          true,
          name,
          "the validator startup names no validation: name the module that validates the " <>
            "address, or none for an address no tenant can point elsewhere"
        )

      true ->
        path = Path.join([root, "lib", module_path(validator) <> ".ex"])

        add(
          findings,
          :url_without_validator,
          not File.exists?(path),
          name,
          "the validator #{validator} is not a module of the tree"
        )
    end
  end

  # The file of a module: `Letflow.Webhooks.UrlValidator` lives in
  # `lib/letflow/webhooks/url_validator.ex`.
  defp module_path(validator) do
    validator
    |> String.split(".")
    |> Enum.map_join("/", &underscore/1)
  end

  defp underscore(name) do
    name
    |> String.replace(~r"([A-Z]+)([A-Z][a-z])", "\\1_\\2")
    |> String.replace(~r"([a-z\d])([A-Z])", "\\1_\\2")
    |> String.downcase()
  end

  defp reads_of_name(inv, source, name) do
    reads = if source == "env", do: inv.env, else: inv.app_env
    Enum.filter(reads, &(&1.name == name))
  end
end
