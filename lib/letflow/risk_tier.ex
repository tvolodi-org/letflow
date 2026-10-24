defmodule Letflow.RiskTier do
  @moduledoc """
  Decides whether a diff is SHORT-eligible (`:short`) or not (`{:not_short, reason}`).

  Advisory only (auditor ruling R11 of GH #2875): it answers "may this diff take the SHORT
  chain, yes or no" from a path allow-list and nothing else. HIGH stays the manual
  ORCHESTRATOR.md section 13 checklist and DIRECT stays section 10; this module never
  computes either. Every doubt, error and unreadable output resolves to `{:not_short, _}`,
  that is, to the existing FULL chain.

  `classify/1` is pure and takes the parsed `git diff --raw` entries. `tier/3` reads them
  from git, with every option that a git config key could flip passed as a flag and a
  hardened environment, so the verdict does not depend on git config.

  ## Allow-list

  SHORT needs every entry to be status `A` or `M`, mode `100644` (no mode change, symlink
  or submodule), and a path of one of these classes:

    * `test/**/*_test.exs`, `test/specs/**/*.md`, `test/reports/**/*.yaml`, but not under
      `test/fixtures/`, `test/support/`, `test/uat-reports/`. Under `test/` only a new file
      (`A`) is short: an `M` of an existing test file may remove an assertion or add a skip
      tag, which section 13 treats as FULL, and the helper does not parse content.
    * `docs/**/*.md`, except the section 13 exclusions (`docs/agents/`, `docs/migration/`,
      `docs/runbooks/`, `docs/guides/`, `docs/roles.md`, `docs/merge-queue.md`,
      `docs/anti-patterns.md`, `docs/frontend/x-ui-widget-vocabulary.md`). Every `.yaml`
      under `docs/` (including `requirements.yaml`) is never short.

  Never allow-listed, whatever the class: any path containing `risk_tier` (this helper and
  its tests), `CLAUDE.md`, anything under `.claude/`, `ORCHESTRATOR.md`, `GIT_MERGE.md`,
  `mix.exs`, and guard tests (the widened regex of section 13). Paths outside
  `[A-Za-z0-9_./-]` are not allowed.

  The Extensions-only SHORT cases, DIRECT, HIGH and the 300-line count are deliberately
  not implemented. `Letflow.RiskTierTest` pins the `docs/` part of the list against
  `BACKEND_PATHS_RE` in `scripts/ci_changed_paths.sh`.
  """

  # Git for Windows maps this to NUL in its own path handling.
  @null_device "/dev/null"

  @env_unset_prefixes ~w(MIX_ ERL_ ELIXIR_ HEX_ GIT_CONFIG_KEY_ GIT_CONFIG_VALUE_)
  @env_unset_names ~w(GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS)

  @git_flags [
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.quotepath=false",
    "-c",
    "core.attributesFile=" <> @null_device
  ]

  @diff_flags ~w(diff --raw -z --no-renames --no-ext-diff --no-textconv --no-color
                 --ignore-submodules=none --no-relative --abbrev=40 -O/dev/null)

  @docs_excluded_prefixes ~w(docs/agents/ docs/migration/ docs/runbooks/ docs/guides/)
  @docs_excluded_files ~w(docs/roles.md docs/merge-queue.md docs/anti-patterns.md
                          docs/frontend/x-ui-widget-vocabulary.md)
  @tests_excluded_prefixes ~w(test/fixtures/ test/support/ test/uat-reports/)
  @denied_basenames ~w(claude.md orchestrator.md git_merge.md mix.exs)

  @guard_regex ~r/(guard|invariant|inventory|drift|golden|permission_matrix|path_filter|boundaries|authoriz|enforce|route_scope|scope|authorize|leak|secret|escalat|cross_tenant|isolation|cd_qa|tip_rule|ci_changed|check_pr_gates)[^\/]*_test\.exs$/
  @path_chars ~r/\A[A-Za-z0-9_.\/-]+\z/
  @raw_meta ~r/\A:(\d{6}) (\d{6}) [0-9a-f]{40,64} [0-9a-f]{40,64} ([A-Z])\z/

  @type entry :: %{
          path: String.t(),
          status: String.t(),
          old_mode: String.t(),
          new_mode: String.t()
        }
  @type verdict :: :short | {:not_short, String.t()}

  @doc "Environment handed to git: the pairs to set, and `nil` to unset, by name and by prefix."
  @spec git_env(Enumerable.t()) :: [{String.t(), String.t() | nil}]
  def git_env(current_env \\ System.get_env()) do
    by_prefix =
      for {name, _} <- current_env,
          Enum.any?(@env_unset_prefixes, &String.starts_with?(name, &1)),
          do: {name, nil}

    by_name = for name <- @env_unset_names, do: {name, nil}

    [
      {"GIT_NO_REPLACE_OBJECTS", "1"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", @null_device}
      | by_name ++ by_prefix
    ]
  end

  @doc "Classifies parsed `git diff --raw` entries. `[]` is NOT-SHORT."
  @spec classify([entry()]) :: verdict()
  def classify([]), do: {:not_short, "empty diff"}

  def classify(entries) when is_list(entries) do
    case Enum.find(entries, &(not entry_ok?(&1))) do
      nil -> :short
      %{path: path} -> {:not_short, "not SHORT-eligible: #{inspect(path)}"}
      _ -> {:not_short, "malformed entry"}
    end
  end

  def classify(_), do: {:not_short, "malformed entries"}

  defp entry_ok?(%{path: path, status: status, old_mode: old, new_mode: new})
       when is_binary(path) do
    status_mode_ok?(status, old, new) and path_allowed?(path) and
      status_ok_for_path?(status, path)
  end

  defp entry_ok?(_), do: false

  defp status_mode_ok?("A", "000000", "100644"), do: true
  defp status_mode_ok?("M", "100644", "100644"), do: true
  defp status_mode_ok?(_, _, _), do: false

  defp status_ok_for_path?("A", _path), do: true
  defp status_ok_for_path?("M", path), do: not String.starts_with?(path, "test/")
  defp status_ok_for_path?(_, _), do: false

  @doc "True when `path` is on the SHORT allow-list."
  @spec path_allowed?(term()) :: boolean()
  def path_allowed?(path) when is_binary(path) do
    String.match?(path, @path_chars) and clean_segments?(path) and
      not denied?(String.downcase(path)) and allowed_class?(path)
  end

  def path_allowed?(_), do: false

  defp clean_segments?(path) do
    not String.starts_with?(path, ["/", "-"]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp denied?(lc) do
    String.contains?(lc, "risk_tier") or
      String.starts_with?(lc, ".claude/") or
      Path.basename(lc) in @denied_basenames or
      Regex.match?(@guard_regex, lc)
  end

  defp allowed_class?("test/" <> _ = path) do
    not String.starts_with?(path, @tests_excluded_prefixes) and
      (String.ends_with?(path, "_test.exs") or
         (String.starts_with?(path, "test/specs/") and String.ends_with?(path, ".md")) or
         (String.starts_with?(path, "test/reports/") and String.ends_with?(path, ".yaml")))
  end

  defp allowed_class?("docs/" <> _ = path) do
    String.ends_with?(path, ".md") and
      not String.starts_with?(path, @docs_excluded_prefixes) and
      path not in @docs_excluded_files
  end

  defp allowed_class?(_), do: false

  @doc """
  Parses `git diff --raw -z` output into entries, or `:error` on anything malformed
  (odd record count, bad metadata, non-UTF-8 bytes).
  """
  @spec parse_raw(binary()) :: {:ok, [entry()]} | :error
  def parse_raw(output) when is_binary(output) do
    if String.valid?(output), do: output |> String.split("\0") |> parse_records([]), else: :error
  end

  def parse_raw(_), do: :error

  defp parse_records([""], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_records([meta, path | rest], acc) when path != "" do
    case Regex.run(@raw_meta, meta) do
      [_, old, new, status] ->
        parse_records(rest, [%{path: path, status: status, old_mode: old, new_mode: new} | acc])

      nil ->
        :error
    end
  end

  defp parse_records(_, _), do: :error

  @doc """
  Reads the diff of `base...head` from git and classifies it. Never raises.

  Options: `:cd` (repository directory, default the current one), `:runner`
  (`fun.(args, env, cd) -> {output, exit_status}`, for tests).
  """
  @spec tier(String.t(), String.t(), keyword()) :: verdict()
  def tier(base, head, opts \\ []) do
    runner = Keyword.get(opts, :runner, &run_git/3)
    cd = Keyword.get(opts, :cd, File.cwd!())

    with :ok <- check_ref(base),
         :ok <- check_ref(head),
         {:ok, base_sha} <- resolve(runner, base, cd),
         {:ok, head_sha} <- resolve(runner, head, cd),
         {:ok, output} <- run(runner, @diff_flags ++ ["#{base_sha}...#{head_sha}"], cd),
         {:ok, entries} <- parse_or_unreadable(output) do
      classify(entries)
    else
      {:not_short, _} = verdict -> verdict
    end
  rescue
    e -> {:not_short, "helper error: " <> Exception.message(e)}
  catch
    kind, value -> {:not_short, "helper error: #{inspect({kind, value})}"}
  end

  defp parse_or_unreadable(output) do
    case parse_raw(output) do
      {:ok, entries} -> {:ok, entries}
      :error -> {:not_short, "unreadable output"}
    end
  end

  defp check_ref(ref) when is_binary(ref) do
    if ref != "" and not String.starts_with?(ref, "-") and not String.match?(ref, ~r/[\s\0]/) do
      :ok
    else
      {:not_short, "bad ref"}
    end
  end

  defp check_ref(_), do: {:not_short, "bad ref"}

  defp resolve(runner, ref, cd) do
    args = ["rev-parse", "--verify", "--quiet", "--end-of-options", ref <> "^{commit}"]

    with {:ok, output} <- run(runner, args, cd),
         sha = String.trim(output),
         true <- String.match?(sha, ~r/\A[0-9a-f]{40,64}\z/) do
      {:ok, sha}
    else
      {:not_short, _} = verdict -> verdict
      false -> {:not_short, "unresolvable ref #{inspect(ref)}"}
    end
  end

  defp run(runner, args, cd) do
    case runner.(@git_flags ++ args, git_env(), cd) do
      {output, 0} when is_binary(output) -> {:ok, output}
      _ -> {:not_short, "git failed: #{Enum.join(Enum.take(args, -2), " ")}"}
    end
  end

  defp run_git(args, env, cd) do
    System.cmd("git", args, env: env, cd: cd, stderr_to_stdout: false)
  end
end
