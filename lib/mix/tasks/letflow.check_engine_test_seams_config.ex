defmodule Mix.Tasks.Letflow.CheckEngineTestSeamsConfig do
  @shortdoc "Fails when config/*.exs other than config/test.exs names the engine_test_seams flag"

  @moduledoc """
  Static scan for the compile-time test-seam flag (GH #2787, hardening from the #2704 PR-1 review).

  `config :letflow, :engine_test_seams` compiles test seams into `Letflow.Engine` and friends,
  and zeroes the retry backoff. It is set only in `config/test.exs`. A release built with it set
  in `config/config.exs`, `config/dev.exs`, `config/prod.exs` or `config/runtime.exs` would ship
  those seams. `Application.compile_env/3` reads the value at compile time, so a boot check cannot
  tell the difference once the code is built; the guard has to be a source check.

  ## Rule

  Scans `config/*.exs` (a missing directory or an empty match is a hard error, never a silent
  pass). Every file except `config/test.exs` must not contain the whole word `engine_test_seams`,
  in code or in a comment: a line that only mentions the flag is reworded, not allowlisted.

  ## Usage

      mix letflow.check_engine_test_seams_config
      mix letflow.check_engine_test_seams_config --dir <path>

  `--dir <path>` overrides the `config` root (the regression tests point it at a scratch directory).
  Exits with `Mix.raise/1` listing `path:line` for each violation. Wired into `@check_static_steps`
  in `mix.exs`, so `mix letflow.check.static` and CI's backend gate run it.
  """

  use Mix.Task

  @default_dir "config"
  @allowed_name "test.exs"
  @allowed "config/test.exs"
  @flag_regex ~r/\bengine_test_seams\b/

  @type violation :: %{path: String.t(), line: pos_integer(), text: String.t()}

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [dir: :string])
    dir = Keyword.get(opts, :dir, @default_dir)

    case scan(dir) do
      [] ->
        Mix.shell().info("engine_test_seams config scan: no violations")
        :ok

      violations ->
        listing =
          Enum.map_join(violations, "\n", fn v ->
            "  #{v.path}:#{v.line} #{v.text}"
          end)

        Mix.raise(
          "engine_test_seams config scan: #{length(violations)} violation(s); " <>
            "config :letflow, :engine_test_seams may only be set in #{@allowed}:\n" <> listing
        )
    end
  end

  @doc "Scans `dir/*.exs` and returns every line naming the flag outside `config/test.exs`."
  @spec scan(dir :: Path.t()) :: [violation()]
  def scan(dir) when is_binary(dir) do
    # Path.wildcard does not match a backslash path on Windows: glob over a forward-slash form.
    files = dir |> normalize() |> Path.join("*.exs") |> Path.wildcard()

    if files == [] do
      Mix.raise(
        "engine_test_seams config scan: no #{dir}/*.exs files found; refusing to pass silently"
      )
    end

    files
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(Path.basename(&1) == @allowed_name))
    |> Enum.sort()
    |> Enum.flat_map(fn path -> audit(File.read!(path), path) end)
  end

  @doc "The violations in one file's `content`, reported against `path`."
  @spec audit(content :: String.t(), path :: String.t()) :: [violation()]
  def audit(content, path) when is_binary(content) and is_binary(path) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {text, _line} -> Regex.match?(@flag_regex, text) end)
    |> Enum.map(fn {text, line} -> %{path: path, line: line, text: String.trim(text)} end)
  end

  defp normalize(path), do: String.replace(path, "\\", "/")
end
