defmodule Letflow.Support.ConfigRegistryScan do
  @moduledoc """
  G-10: the derivation behind the config/env/flag registry probe.

  The registry (`priv/config_registry.json`) is the reviewed answer to "which configuration does
  this product have, who owns it, why does it exist, how is it read and must its absence fail
  closed". This module derives the other half **from the tree**: every environment variable and
  every application environment key the sources read, with the form of each read (a default or
  not, compile-time or runtime, a config directive or a read).

  It reads files and parses them with `Code.string_to_quoted!/2`. It starts nothing, opens no
  socket, reads no clock and touches no database, so it is deterministic and costs a couple of
  seconds. A file it cannot parse is a finding, never a silent skip.

  The two shapes it derives:

    * `env` -- `System.get_env/1,2`, `System.fetch_env/1`, `System.fetch_env!/1` and a module
      attribute whose name ends in `env` that holds the name of a variable read elsewhere
      (`@token_env "LETFLOW_SIGNUP_PROVISIONER_TOKEN"`).
    * `app_env` -- `Application.get_env/2,3`, `Application.fetch_env/2`,
      `Application.compile_env/2,3` and the `config :app, :key, value` directives of
      `config/*.exs`.

  A read whose key is computed at run time cannot be resolved statically; it is reported as
  `dynamic` and needs no registry entry.
  """

  @registry_path "priv/config_registry.txt"

  @kinds ~w(plain flag guard secret url)
  @reads ~w(compile_time runtime)
  @scopes ~w(platform tenant module test)

  @type read_form ::
          :get_env
          | :get_env_default
          | :fetch_env
          | :fetch_env_default
          | :compile_env
          | :compile_env_default
          | :directive

  @type site :: %{
          file: String.t(),
          line: pos_integer(),
          form: read_form(),
          default: :none | nil | false | true | :literal | :expression,
          value: term()
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
  pipe-separated columns (see `priv/config_registry.txt`).
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
    inv = inventory(root)

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
      "environment variable"
    )
    |> add_many(
      :unregistered_app_env,
      MapSet.difference(derived_app, registered_app),
      "application key"
    )
    |> add_many(
      :stale_entry,
      MapSet.difference(registered_env, derived_env),
      "environment variable"
    )
    |> add_many(:stale_entry, MapSet.difference(registered_app, derived_app), "application key")
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

  defp reads_in(ast, rel) do
    test? = test_file?(rel)

    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, acc ++ Enum.map(reads_of(node, rel), &Map.put(&1, :test?, test?))}
      end)

    acc
  end

  # A test configuration may carry a literal where a release configuration must not.
  defp test_file?(rel) do
    Path.basename(rel) == "test.exs" or String.starts_with?(rel, "test/")
  end

  defp reads_of({:@, meta, [{name, _, [value]}]}, rel) when is_atom(name) do
    if String.ends_with?(Atom.to_string(name), "env") and is_binary(value) do
      [
        %{
          source: :env,
          name: value,
          file: rel,
          line: line(meta),
          form: :attribute,
          default: :none,
          value: nil
        }
      ]
    else
      []
    end
  end

  defp reads_of({{:., _, [mod, fun]}, meta, args}, rel) when is_list(args) do
    module = alias_name(mod)

    cond do
      module == "System" and fun in [:get_env, :fetch_env, :fetch_env!] and args != [] ->
        case args do
          [name | rest] when is_binary(name) ->
            [
              %{
                source: :env,
                name: name,
                file: rel,
                line: line(meta),
                form: env_form(fun, rest),
                default: default_kind(rest),
                value: default_value(rest)
              }
            ]

          _ ->
            [
              %{
                source: :dynamic,
                name: nil,
                file: rel,
                line: line(meta),
                form: :get_env,
                default: :none,
                value: nil
              }
            ]
        end

      module == "Application" and fun in [:get_env, :fetch_env, :compile_env] and
          length(args) >= 2 ->
        app_env_read(mod, fun, args, rel, meta)

      true ->
        []
    end
  end

  defp reads_of({:config, meta, args}, rel) when is_list(args) and args != [] do
    case args do
      [app, key | rest] ->
        case app_env_name(app, key) do
          nil ->
            []

          name ->
            [
              %{
                source: :app_env,
                name: name,
                file: rel,
                line: line(meta),
                form: :directive,
                default: default_kind(rest),
                value: default_value(rest)
              }
            ]
        end

      _ ->
        []
    end
  end

  defp reads_of({:sigil_w, meta, [{:<<>>, _, [words]}]}, rel) when is_binary(words) do
    words
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&env_name?/1)
    |> Enum.map(fn name ->
      %{
        source: :env,
        name: name,
        file: rel,
        line: line(meta),
        form: :literal,
        default: :none,
        value: nil
      }
    end)
  end

  defp reads_of({:||, meta, [left, right]}, rel) do
    case reads_of(left, rel) do
      [%{form: form, default: :none} = site] when form in [:get_env, :fetch_env] ->
        [
          %{
            site
            | line: line(meta),
              form: :fallback,
              default: default_kind_of(right),
              value: right
          }
        ]

      _ ->
        []
    end
  end

  defp reads_of(_node, _rel), do: []

  @doc false
  # The shape of an environment variable name: an upper-case word with an underscore in it.
  def env_name?(name) when is_binary(name) do
    String.match?(name, ~r/^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$/)
  end

  def env_name?(_name), do: false

  defp app_env_read(_mod, fun, args, rel, meta) do
    [app, key | rest] = args

    case app_env_name(app, key) do
      nil ->
        [
          %{
            source: :dynamic,
            name: nil,
            file: rel,
            line: line(meta),
            form: app_form(fun, rest),
            default: :none,
            value: nil
          }
        ]

      name ->
        [
          %{
            source: :app_env,
            name: name,
            file: rel,
            line: line(meta),
            form: app_form(fun, rest),
            default: default_kind(rest),
            value: default_value(rest)
          }
        ]
    end
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

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Enum.map_join(parts, ".", &Atom.to_string/1)
    else
      nil
    end
  end

  defp alias_name(_other), do: nil

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

  defp add(findings, code, true, name, detail),
    do: findings ++ [%{code: code, name: name, detail: detail}]

  defp add(findings, _code, false, _name, _detail), do: findings

  defp add_many(findings, code, names, label) do
    Enum.reduce(Enum.sort(names), findings, fn {source, name}, acc ->
      add(acc, code, true, "#{source}:#{name}", label)
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

    findings
    |> add(
      :read_mode_mismatch,
      Enum.any?(compile_time, fn name ->
        entry = Map.get(by_name, "app_env:#{name}")

        entry != nil and entry["read"] != "compile_time"
      end),
      "the registry",
      "a key read with Application.compile_env/2 is not registered as compile_time"
    )
    |> add(
      :read_mode_mismatch,
      Enum.any?(runtime, fn name ->
        entry = Map.get(by_name, "app_env:#{name}")

        entry != nil and entry["read"] == "compile_time"
      end),
      "the registry",
      "a key registered as compile_time is not read with Application.compile_env/2"
    )
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

  defp enabled_in_release_config?(root, name) do
    release_config =
      Path.wildcard(Path.join([root, "config", "*.exs"]))
      |> Enum.filter(&(Path.basename(&1) in ["config.exs", "prod.exs", "runtime.exs"]))

    Enum.any?(release_config, fn file ->
      case parse(file) do
        {:ok, ast} ->
          Enum.any?(reads_of(ast, Path.basename(file)), fn read ->
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

  defp check_url_validator(findings, _root, entry, _inv) do
    validator = entry["validator"]

    cond do
      is_nil(validator) or validator == "none" or validator == "startup" ->
        findings

      true ->
        path = Path.join("lib", String.replace(validator, ".", "/") <> ".ex")

        add(
          findings,
          :url_without_validator,
          not File.exists?(path),
          "#{entry["source"]}:#{entry["name"]}",
          "the validator #{validator} is not a module of the tree"
        )
    end
  end

  defp reads_of_name(inv, source, name) do
    reads = if source == "env", do: inv.env, else: inv.app_env
    Enum.filter(reads, &(&1.name == name))
  end
end
