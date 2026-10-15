defmodule Mix.Tasks.Letflow.PermissionMatrix do
  @shortdoc "Writes or checks the effective role x permission golden file (production module list)"

  @moduledoc """
  The effective-permission golden file check (GH #2586 / REQ-498; decision
  0055 D7 / D12 step 2a; design
  `lib/letflow/design/gh2586-permission-matrix-golden.md` section 5). The pure
  logic is `Letflow.Api.PermissionMatrix`; this task does the IO (env, files,
  git, exit status).

  ## Usage

      MIX_ENV=dev mix letflow.permission_matrix --check
      MIX_ENV=dev mix letflow.permission_matrix --write
      MIX_ENV=dev mix letflow.permission_matrix --check --baseline-ref <git rev>

  PowerShell: `$env:MIX_ENV='dev'; mix letflow.permission_matrix --check`.
  Run `git fetch origin main` first: the default baseline is
  `git merge-base HEAD origin/main`. `--check` is the default.

  ## Why only `MIX_ENV=dev` / `prod`

  `config/test.exs` registers the `test/support/modules` fixtures, so a matrix
  computed under `MIX_ENV=test` is not the production matrix. The task refuses
  `test` (and any env other than `dev`/`prod`) with a distinct message, and is
  therefore NOT a step of `mix letflow.check.static` (pinned to `:test` in
  `mix.exs`); CI runs it as its own `backend_static` step.

  ## `--check`

  Collects every failure, then raises once:

    1. build the matrix (`PermissionMatrix.current/0`);
    2. `Letflow.Modules.Catalog.validate/1` on every production manifest;
    3. fixture atoms by static scan, then the production-list proof (env,
       Exam's six atoms present, no fixture atom present);
    4. the module-list proof: the `:prod` and `:dev` config lists (read with
       `Config.Reader`) equal the compiled list, and `:modules` is set only in
       `config/config.exs` / `config/test.exs`; the eight header lines are
       printed (the `# modules:` line is the human-readable proof);
    5. FRESHNESS: the working-tree golden equals the computed matrix;
    6. the baseline ref (default `git merge-base HEAD origin/main`) must not be
       HEAD and must be an ancestor of HEAD's first parent for a merge HEAD
       (else of HEAD);
    7. the baseline golden is read from git at that ref (never the working
       tree); absent is accepted only when the ref also lacks this task file
       (bootstrap);
    8. CLASSIFICATION of baseline -> computed; the report is printed and, when
       `GITHUB_STEP_SUMMARY` is set, appended there.

  Only when nothing failed does it print the final line
  `PERMISSION-MATRIX-REPORT v1 baseline=<sha> head=<sha> labels=<...> result=pass`;
  no other code path prints it, and the CI step requires it.

  ## `--write`

  Steps 1-4, then writes `priv/permission_matrix/effective.golden` (LF only).
  Classification is not evaluated; run `--check`.

  Git is called with `System.cmd/3` and an argument list (no shell); the task
  never fetches and never runs a git command that changes the repository.
  """

  use Mix.Task

  alias Letflow.Api.PermissionMatrix
  alias Letflow.Modules.Catalog

  @golden_path "priv/permission_matrix/effective.golden"
  @task_path "lib/mix/tasks/letflow.permission_matrix.ex"
  @fixture_glob "test/support/modules/**/*.{ex,exs}"
  @config_glob "config/*.exs"
  @write_command "MIX_ENV=dev mix letflow.permission_matrix --write"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    mode = parse_args!(argv)
    env = Mix.env()

    if env not in [:dev, :prod] do
      Mix.raise(PermissionMatrix.describe({:wrong_env, env}))
    end

    Mix.Task.run("compile")

    computed =
      case PermissionMatrix.current() do
        {:ok, matrix} ->
          matrix

        {:error, error} ->
          Mix.raise("letflow.permission_matrix: cannot build the matrix: #{inspect(error)}")
      end

    preflight = preflight_failures(computed, env)

    Enum.each(PermissionMatrix.header_lines(computed), fn line -> Mix.shell().info(line) end)

    case mode do
      :write -> write!(computed, preflight)
      {:check, ref_option} -> check!(computed, preflight, ref_option)
    end
  end

  defp parse_args!(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv, strict: [check: :boolean, write: :boolean, baseline_ref: :string])

    cond do
      invalid != [] or rest != [] ->
        Mix.raise("letflow.permission_matrix: unknown argument(s) #{inspect(invalid ++ rest)}")

      opts[:check] && opts[:write] ->
        Mix.raise("letflow.permission_matrix: pass --check or --write, not both")

      opts[:write] ->
        :write

      true ->
        {:check, opts[:baseline_ref]}
    end
  end

  # Steps 3, 4 and 4a (design section 5): manifests, production list, module list.
  defp preflight_failures(computed, env) do
    manifest_failures =
      for manifest <- Catalog.all_manifests(),
          result = Catalog.validate(manifest),
          result != :ok,
          do: {:invalid_manifest, manifest.id, elem(result, 1)}

    production_failures =
      case PermissionMatrix.fixture_permissions(read_sources(@fixture_glob)) do
        {:ok, fixture_atoms} ->
          case PermissionMatrix.check_production_list(computed, fixture_atoms, env) do
            :ok -> []
            {:error, errors} -> errors
          end

        {:error, error} ->
          [error]
      end

    module_list_failures =
      case configured_modules() do
        {:ok, configured} ->
          case PermissionMatrix.check_module_list(
                 Catalog.entry_modules(),
                 configured,
                 read_sources(@config_glob)
               ) do
            :ok -> []
            {:error, errors} -> errors
          end

        {:error, error} ->
          [error]
      end

    manifest_failures ++ production_failures ++ module_list_failures
  end

  defp read_sources(glob) do
    glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp configured_modules do
    Enum.reduce_while([:prod, :dev], {:ok, %{}}, fn env, {:ok, acc} ->
      try do
        config = Config.Reader.read!("config/config.exs", env: env)
        modules = get_in(config, [:letflow, :modules]) || []
        {:cont, {:ok, Map.put(acc, env, modules)}}
      rescue
        error -> {:halt, {:error, {:config_unreadable, env, Exception.message(error)}}}
      end
    end)
  end

  defp write!(computed, []) do
    File.mkdir_p!(Path.dirname(@golden_path))
    File.write!(@golden_path, PermissionMatrix.render(computed))
    Mix.shell().info("wrote #{@golden_path}")
    Mix.shell().info("classification not evaluated by --write; run --check")
    :ok
  end

  defp write!(_computed, failures), do: raise_failures(failures)

  # Steps 6-11 (design section 5).
  defp check!(computed, preflight, ref_option) do
    freshness_failures = freshness_failures(computed)

    {baseline_failures, classification} =
      case resolve_baseline(ref_option, File.cwd!()) do
        {:ok, resolved} -> classify_against(resolved, computed)
        {:error, failure} -> {[failure], nil}
      end

    report_failures =
      case classification do
        {_resolved, report} -> report.failures
        nil -> []
      end

    case preflight ++ freshness_failures ++ baseline_failures ++ report_failures do
      [] ->
        {resolved, report} = classification

        Mix.shell().info(
          PermissionMatrix.report_marker(resolved.ref_sha, resolved.head_sha, report)
        )

        :ok

      failures ->
        raise_failures(failures)
    end
  end

  defp freshness_failures(computed) do
    with {:ok, text} <- read_golden(),
         {:ok, golden} <- parse_golden(text),
         :ok <- PermissionMatrix.freshness(golden, computed) do
      []
    else
      {:error, failure} -> [failure]
    end
  end

  defp read_golden do
    case File.read(@golden_path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:golden_missing, @golden_path, reason}}
    end
  end

  defp parse_golden(text) do
    case PermissionMatrix.parse(text) do
      {:ok, golden} -> {:ok, golden}
      {:error, error} -> {:error, {:golden_unparsable, @golden_path, error}}
    end
  end

  # Steps 8-9: read B from git at the resolved ref, classify, print the report.
  defp classify_against(resolved, computed) do
    case baseline_at(resolved, File.cwd!()) do
      {:ok, baseline} ->
        report =
          PermissionMatrix.classify(
            baseline,
            computed,
            PermissionMatrix.current_context(module_dirs(baseline))
          )

        publish_report(report)
        {[], {resolved, report}}

      {:error, failure} ->
        {[failure], nil}
    end
  end

  defp module_dirs(:absent), do: MapSet.new()

  defp module_dirs(baseline) do
    for id <- Map.keys(baseline.modules),
        File.dir?(Path.join("lib/letflow/modules", id)),
        into: MapSet.new(),
        do: id
  end

  defp publish_report(report) do
    text = PermissionMatrix.format_report(report)
    Mix.shell().info(text)

    case System.get_env("GITHUB_STEP_SUMMARY") do
      summary when is_binary(summary) and summary != "" ->
        File.write!(summary, "### Effective permission matrix\n\n```\n" <> text <> "```\n", [
          :append
        ])

      _ ->
        :ok
    end
  end

  @doc """
  Steps 7 (design section 5): resolves the baseline ref in the git repository
  at `cwd` (`nil` -> `git merge-base HEAD origin/main`) to full shas and checks
  it is not HEAD and is an ancestor of the anchor (HEAD's first parent for a
  merge HEAD, else HEAD). Never a silent pass: every git failure is an error.
  """
  @spec resolve_baseline(ref :: String.t() | nil, cwd :: Path.t()) ::
          {:ok, %{ref: String.t(), ref_sha: String.t(), head_sha: String.t()}}
          | {:error, term()}
  def resolve_baseline(ref_option, cwd) do
    with {:ok, ref} <- baseline_ref(ref_option, cwd),
         {:ok, ref_sha} <- rev_parse(ref, cwd),
         {:ok, head_sha} <- rev_parse("HEAD", cwd),
         {:ok, parent_count} <- head_parent_count(cwd),
         {:ok, ancestor?} <-
           ancestor_of(ref, ref_sha, PermissionMatrix.baseline_anchor(parent_count), cwd) do
      case PermissionMatrix.check_baseline_ref(ref_sha, head_sha, parent_count, ancestor?) do
        :ok -> {:ok, %{ref: ref, ref_sha: ref_sha, head_sha: head_sha}}
        {:error, reason} -> {:error, {reason, ref}}
      end
    end
  end

  defp baseline_ref(ref, _cwd) when is_binary(ref), do: {:ok, ref}

  defp baseline_ref(nil, cwd) do
    case git(["merge-base", "HEAD", "origin/main"], cwd) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, line} -> {:error, {:baseline_unavailable, "merge-base HEAD origin/main", line}}
    end
  end

  defp rev_parse(rev, cwd) do
    case git(["rev-parse", "--verify", rev <> "^{commit}"], cwd) do
      {:ok, out} -> {:ok, String.trim(out)}
      {:error, line} -> {:error, {:baseline_unavailable, rev, line}}
    end
  end

  defp head_parent_count(cwd) do
    case git(["rev-list", "--parents", "-n", "1", "HEAD"], cwd) do
      {:ok, out} -> {:ok, length(String.split(out)) - 1}
      {:error, line} -> {:error, {:baseline_unavailable, "HEAD", line}}
    end
  end

  defp ancestor_of(ref, ref_sha, anchor, cwd) do
    case git_status(["merge-base", "--is-ancestor", ref_sha, anchor], cwd) do
      {0, _out} -> {:ok, true}
      {1, _out} -> {:ok, false}
      {_status, out} -> {:error, {:baseline_unavailable, ref, first_line(out)}}
    end
  end

  # Step 8: B = the golden committed at the ref; bootstrap only per D18.
  defp baseline_at(resolved, cwd) do
    if git_object?(resolved.ref_sha, @golden_path, cwd) do
      with {:ok, text} <- git_show(resolved.ref_sha, @golden_path, cwd),
           {:ok, baseline} <- PermissionMatrix.parse(text) do
        {:ok, baseline}
      else
        {:error, error} -> {:error, {:baseline_unparsable, resolved.ref, error}}
      end
    else
      task_present? = git_object?(resolved.ref_sha, @task_path, cwd)

      if PermissionMatrix.bootstrap_allowed?(false, task_present?),
        do: {:ok, :absent},
        else: {:error, {:baseline_missing, resolved.ref}}
    end
  end

  defp git_object?(sha, path, cwd),
    do: match?({0, _}, git_status(["cat-file", "-e", "#{sha}:#{path}"], cwd))

  defp git_show(sha, path, cwd) do
    {out, status} = System.cmd("git", ["show", "#{sha}:#{path}"], cd: cwd)
    if status == 0, do: {:ok, out}, else: {:error, {:git_show_failed, status}}
  rescue
    error -> {:error, {:git_unavailable, Exception.message(error)}}
  end

  defp git(args, cwd) do
    case git_status(args, cwd) do
      {0, out} -> {:ok, out}
      {_status, out} -> {:error, first_line(out)}
    end
  end

  defp git_status(args, cwd) do
    {out, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    {status, out}
  rescue
    error -> {127, "git unavailable: " <> Exception.message(error)}
  end

  defp first_line(out), do: out |> String.split("\n") |> hd() |> String.trim()

  defp raise_failures(failures) do
    classes =
      failures
      |> Enum.map(&failure_class/1)
      |> Enum.uniq()
      |> Enum.join(", ")

    lines = Enum.map(failures, &("  - " <> describe_failure(&1)))
    stale? = Enum.any?(failures, &match?({:golden_stale, _}, &1))
    tail = if stale?, do: ["regenerate: " <> @write_command], else: []

    Mix.raise(
      Enum.join(
        ["#{classes}: letflow.permission_matrix failed (#{length(failures)} failure(s))"] ++
          lines ++ tail,
        "\n"
      )
    )
  end

  defp failure_class(failure) when is_tuple(failure), do: Atom.to_string(elem(failure, 0))
  defp failure_class(failure) when is_atom(failure), do: Atom.to_string(failure)

  defp describe_failure({:baseline_unavailable, ref, line}),
    do: "baseline ref #{ref} unavailable (#{line}); hint: git fetch origin main"

  defp describe_failure({:baseline_is_head, ref}),
    do:
      "baseline ref #{ref} is HEAD: nothing to classify at origin/main; run on a branch, " <>
        "or pass --baseline-ref HEAD~1"

  defp describe_failure({:baseline_not_ancestor, ref}),
    do: "baseline ref #{ref} is not an ancestor of HEAD's first parent (or of HEAD)"

  defp describe_failure({:baseline_missing, ref}),
    do:
      "no #{@golden_path} at baseline #{ref}, but the task exists there: bootstrap is not " <>
        "allowed (a moved or renamed golden would skip classification)"

  defp describe_failure({:invalid_manifest, id, error}),
    do: "production manifest #{id} fails Catalog.validate/1: #{inspect(error)}"

  defp describe_failure(failure), do: PermissionMatrix.describe(failure)
end
