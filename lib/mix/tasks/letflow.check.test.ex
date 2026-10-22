defmodule Mix.Tasks.Letflow.Check.Test do
  @shortdoc "Runs the test suite (parallel; optional --shard K/M or --tails-only), gated only on ISS-0069's own warning class"

  @moduledoc """
  ISS-0069 Part 2 (revised): the `test` step used by `mix letflow.check`.

  ISS-0428: shells out to `scripts/test_parallel.sh` (via `bash`) instead of plain
  `mix test` -- the parallel runner N-way partitions the suite (N derived from
  `TEST_PARALLEL_N`/`nproc`/`getconf`, never hardcoded here; see the script's own
  header and `docs/migration/decisions/0009-test-parallel-pool-sizing.md`), which
  measured 1.89x on CI's actual 2-vCPU parallelism and up to ~5x on a 16-core dev
  host (see `lib/letflow/design/iss0428-parallel-runner-in-check-test.md` section 0).
  No `mix.exs`/`ci.yml` edit is needed for CI to pick this up: CI's only backend gate
  is `mix letflow.check`, which already calls this task (REQ-136).

  The runner's own stdout only ever carries per-partition summary lines and an
  aggregated total -- never the constituent partitions' raw test output. So the
  ISS-0069 substring check below does **not** read that aggregate stream. It parses
  the runner's `test_parallel: partition logs in <dir>` line (printed unconditionally
  once the runner reaches its partition-launch step), discovers every
  `partition-*.log` file under that directory (no hardcoded partition count), and
  applies the substring check to their concatenated content -- see design doc
  section 1 for the full rationale, including why pointing this check at the
  aggregate stdout instead would make it an unreliable gate (sometimes catching a
  warning, sometimes not, depending on Mix's compile-manifest re-emission behavior)
  rather than a reliably vacuous one.

  If the log-dir line is absent/unparseable, or zero partition logs are found, this
  task hard-fails (`Mix.raise`) rather than silently passing -- a future edit to
  `scripts/test_parallel.sh` that removes or reworks that output contract must break
  this gate loudly, never silently stop gating.

  **Ordering rule** (design doc section 1.2 step 1): when the runner exits nonzero
  AND the log-dir line is absent, this task reports the runner's nonzero exit first,
  not "log line missing" -- the common real case is a `mix compile` failure inside
  `test_parallel.sh`'s own pre-compile step, which exits before the log-dir line is
  ever printed, and leading with "log line missing" would send a reader hunting a
  nonexistent parsing bug instead of the real compile error.

  **Full failure detail, either failure mode** (design doc section 4): on a failing run, this task prints
  the full content of every partition log that shows real test failures (a `Failed:`
  line) or a crash (no `Result:` line) before raising, so an agent reading the
  terminal/CI job log sees the actual failing test's detail without needing the
  runner's own `mktemp -d` directory to still exist.

  GH #2615: the reverse holds for the script-runtime budget measurement. On a passing run,
  this task echoes every `GH2534 budget measurement` line from the partition logs, so the
  median and p95 reach the CI job log without a workflow change.

  ISS-0352: after the main suite passes, this task runs the `:wasm_hang`-tagged tests
  in `test/letflow/engine/wasm/` -- tests that deliberately, genuinely hang a real
  `wasmex` NIF call to prove REQ-170's own live-verified finding that no BEAM-side
  mechanism can reclaim that thread -- it permanently occupies one slot of `wasmex`'s
  shared, node-global native worker pool for the rest of the OS process. Run in the
  same process as every other WASM NIF test, this starved unrelated tests once the
  pool was exhausted (PR #691, then worse on PR #692 -- 18 cascading
  `ExUnit.TimeoutError`s).

  ISS-0418: a single shared subprocess for every `:wasm_hang` test (this task's
  original ISS-0352 shape) does not actually solve the hazard above -- it only moves
  it: every `:wasm_hang` test permanently wedges one native worker thread in whatever
  subprocess it runs in, so a single shared subprocess still accumulates one leaked
  thread per test and exhausts a small-CPU-count runner's pool by the last test or
  two (post-fix CI still showed the same ~50% flake rate as before,
  `docs/issues/ISS-0418.yaml`). The fix (see
  `lib/letflow/design/iss0418-wasm-hang-test-isolation-fix.md`, ELIXIR-DEV-owned) is
  per-test process isolation: `discover_wasm_hang_tests/0` runs `mix test --only
  wasm_hang --dry-run` to ask ExUnit itself which `{file, line}` pairs are currently
  tagged (never hardcoded -- adding/removing a `:wasm_hang` test anywhere is picked
  up automatically), then `run_wasm_hang_tests/0` spawns one real, fresh subprocess
  per discovered location via `mix test <file>:<line>` -- deliberately **without**
  `--only wasm_hang` (design doc §4.1: verified live that `--only` is silently
  discarded when combined with `<file>:<line>`, and `<file>:<line>` alone already
  bypasses `test/test_helper.exs`'s default `:wasm_hang` exclusion, so the suffix
  would be a no-op). A fresh OS subprocess means a fresh BEAM node and therefore a
  fresh, unleaked native thread pool, by construction -- no test ever shares a
  process (and therefore an accumulating pool) with another `:wasm_hang` test.
  Running under N-way parallelism would still multiply the per-process hazard, so
  every per-test subprocess stays serial, same as before.

  ISS-0426: this task then runs a THIRD subprocess, `mix test --only
  lua_wallclock_race`, also unchanged and serial -- these tests need to run without
  racing 30+ concurrently-scheduled siblings for wall-clock-sensitive timing (see
  `lib/letflow/design/iss426-wallclock-test-contention.md` section 2.3). ISS-0423
  already recorded that parallel running is exactly what surfaces this flake, so
  putting these inside a parallel partition would reintroduce the contention they
  were isolated to remove.

  Unlike a blanket `test --warnings-as-errors`, this task does **not** fail
  on every warning. `docs/issues/ISS-0044.yaml` (`status: resolved`)
  already diagnosed two warning classes that only ever surface under
  `mix test` (never under `mix compile --warnings-as-errors`) as
  permanently deferred, not fixed:

    * `ExUnit.Case.register_test/4 is deprecated` (ISS-0044 Group 1) --
      blocked on a `stream_data` 0.6.0 -> up to 1.4.0 version bump.
    * `redefining module ... CreateEventTypeRegistry` (ISS-0044 Group 3) --
      a deliberate, documented `Code.require_file/1` test workaround.

  Blanket `--warnings-as-errors` fails on both regardless of this issue's
  fix, so this task instead gates narrowly on ISS-0069's own class: an
  unused default value on an optional `defp` argument in a test helper,
  whose compiler warning always starts with the fixed, stable substring
  `"default values for the optional arguments"` (see
  `lib/letflow/design/iss0069-unused-default-warnings-fix.md`).

  ## Exit-code contract

    * Exits `0` only if the parallel runner's own aggregated result is a real pass
      (every partition has a `Result:` line, zero parsed failures) **and** the
      target substring is absent from every partition log **and** the
      `:lua_wallclock_race` isolated subprocess exits `0` clean **and** the
      `:wasm_hang` discovery subprocess succeeds and every one of the N per-test
      `:wasm_hang` subprocesses it discovers exits `0` clean.
    * Exits `1` if the runner, the `:lua_wallclock_race` subprocess, the `:wasm_hang`
      discovery subprocess, or any of the N per-test `:wasm_hang` subprocesses
      reports a real failure, regardless of the substring check.
    * Exits `1` if the runner or the `:lua_wallclock_race` subprocess exits `0` but
      the target substring is present anywhere in the relevant captured/log output
      (with partition attribution for the main suite), or if the target substring is
      present in the concatenation of the N `:wasm_hang` per-test subprocess
      outputs -- printing the offending line(s) so the failure is immediately
      actionable.

  Every other warning class (including the two ISS-0044 classes above, and
  the separately out-of-scope unused `tenant` variable) remains visible in
  the streamed output but never affects this task's exit code.

  ## Usage

      mix letflow.check.test                  # everything (the default; what `letflow.check` runs)
      mix letflow.check.test --shard K/M      # only the K-th of M slices of the main suite
      mix letflow.check.test --tails-only     # only the :wasm_hang and :lua_wallclock_race tails

  Q-1037 / GH #2364 (backend-gate sharding): `--shard K/M` exports
  `TEST_PARALLEL_SHARD=K/M` to `scripts/test_parallel.sh` (see its header; N must be
  the same on every shard) and skips the two isolated tails, which `--tails-only`
  runs on their own, so a CI matrix can run the slices and the tails as separate
  jobs. The two flags are mutually exclusive; any other argument is an error. The
  ISS-0069 warnings scan and log-dir cleanup apply per invocation. With no
  arguments the behaviour is exactly the single-process run described above.
  """

  use Mix.Task

  @target_substring "default values for the optional arguments"
  # GH #2615: the script-runtime budget measurement prints one line into its partition's
  # log. A passing run never prints partition logs, so the passing path echoes these lines.
  @budget_measurement_marker "GH2534 budget measurement"
  @log_dir_line_regex ~r/^test_parallel: partition logs in (.+)$/m

  # ISS-0697 (design doc iss0697-check-test-executable-resolver-fix.md): the injectable
  # override seam for this module's subprocess-executable resolution. Reads
  # Application.get_env(:letflow, :check_test_executable_resolver, ...), falling back to
  # real System.find_executable/1 whenever the key is unset -- i.e. every non-test
  # invocation of `mix letflow.check.test` is byte-for-byte unaffected by this seam's
  # existence. See resolve_executable/1 below, the sole caller of
  # System.find_executable/1 in this module.
  @type executable_resolver :: (String.t() -> Path.t() | nil)

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [shard: :string, tails_only: :boolean])

    if invalid != [] or rest != [] do
      Mix.raise(
        "mix letflow.check.test: unrecognised arguments #{inspect(invalid ++ rest)} -- " <>
          "usage: mix letflow.check.test [--shard K/M | --tails-only]"
      )
    end

    shard = Keyword.get(opts, :shard)
    tails_only? = Keyword.get(opts, :tails_only, false)

    cond do
      shard != nil and tails_only? ->
        Mix.raise(
          "mix letflow.check.test: --shard and --tails-only are mutually exclusive " <>
            "(--shard runs only a main-suite slice, --tails-only runs only the isolated tails)"
        )

      shard != nil ->
        validate_shard!(shard)
        # Q-1037 / GH #2364: a sharded CI job runs only its slice of the main suite; the
        # :wasm_hang and :lua_wallclock_race tails run once, in a separate --tails-only job.
        run_main_suite([{"TEST_PARALLEL_SHARD", shard}])

      tails_only? ->
        run_wasm_hang_tests()
        run_lua_wallclock_race_tests()

      true ->
        run_main_suite([])
        run_wasm_hang_tests()
        run_lua_wallclock_race_tests()
    end
  end

  # K/M with 1 <= K <= M, positive integers (same contract as scripts/test_parallel.sh).
  defp validate_shard!(shard) do
    case Regex.run(~r/^([1-9][0-9]*)\/([1-9][0-9]*)$/, shard) do
      [_, k, m] ->
        if String.to_integer(k) > String.to_integer(m) do
          Mix.raise(
            "mix letflow.check.test: --shard #{shard} has K greater than M (need 1 <= K <= M)"
          )
        end

      nil ->
        Mix.raise(
          "mix letflow.check.test: --shard #{inspect(shard)} is not of the form K/M (positive integers)"
        )
    end
  end

  # ISS-0428: shells out to scripts/test_parallel.sh (an N-way parallel `mix test
  # --partitions N` runner) instead of plain `mix test`, then re-points the ISS-0069
  # substring check at the N per-partition log files the runner writes -- see
  # moduledoc and design doc section 1 for the full rationale.
  defp run_main_suite(extra_env) do
    bash = resolve_executable("bash")

    if is_nil(bash) do
      Mix.raise(
        "mix letflow.check.test: no bash found on PATH -- scripts/test_parallel.sh " <>
          "requires bash; see docs/guides/backend_developer_guide.md for setup."
      )
    end

    # ISS-0699 (design doc iss0699-test-parallel-tmpdir-cleanup-fix.md §3a.2): pass
    # TEST_PARALLEL_KEEP_LOGS=1 on this specific invocation so the script's own EXIT
    # trap does not delete its partition-log tmp_dir out from under this caller --
    # this task now owns removing that directory itself (see §3a.3 below).
    {output, exit_code} =
      stream_and_capture(bash, ["scripts/test_parallel.sh"], [
        {"TEST_PARALLEL_KEEP_LOGS", "1"} | extra_env
      ])

    # ORDERING RULE (design doc section 1.2 step 1): if the runner exited nonzero,
    # report that first -- even if the log-dir line also happens to be missing. The
    # common real case is a `mix compile` failure inside test_parallel.sh's own
    # pre-compile step, which exits before the log-dir line is ever printed;
    # leading with "log line missing" would send a reader hunting a nonexistent
    # parsing bug instead of the real compile error.
    case find_partition_log_dir(output) do
      :not_found when exit_code != 0 ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- scripts/test_parallel.sh exited " <>
            "#{exit_code} before ever printing its partition-log-directory line " <>
            "(the most common cause is a `mix compile` failure in the runner's own " <>
            "pre-compile step -- check the streamed output above for the real error)."
        )

      :not_found ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- scripts/test_parallel.sh exited 0 but " <>
            "never printed a \"test_parallel: partition logs in <dir>\" line. This " <>
            "task cannot locate the per-partition logs it needs for the ISS-0069 " <>
            "warning check, so it is treating this as a hard failure of the check " <>
            "itself rather than silently passing."
        )

      {:ok, log_dir} ->
        # ISS-0699 (design doc §3a.3): this task, not the script, now owns bounding
        # this tmp_dir's lifetime end-to-end -- the script's own trap no longer
        # deletes it (TEST_PARALLEL_KEEP_LOGS=1 above), so it must be removed here
        # once check_main_suite_logs/2 is done reading it, on every outcome (zero
        # logs, real failures, ISS-0069 substring match, or a clean pass). The
        # `try` body runs check_main_suite_logs/2 to completion -- including the
        # substring check inside it -- before this `after` block can possibly fire,
        # so read-before-delete ordering holds by construction, not timing luck.
        native_log_dir = resolve_native_path(log_dir)

        try do
          check_main_suite_logs(native_log_dir, exit_code)
        after
          File.rm_rf!(native_log_dir)
        end
    end
  end

  # The directory in the log-dir line is printed by a bash/MSYS subprocess and may
  # be a POSIX-style path (e.g. "/tmp/...") that only bash/MSYS itself can resolve --
  # on this project's Windows/Git Bash host, "/tmp" is an MSYS mount onto a real
  # Windows directory (confirmed: `mount` shows "... on /tmp type ntfs"), invisible
  # to a native-Windows BEAM's own file driver (`File.exists?("/tmp/...")` is false
  # even though the directory genuinely exists). Try the path as-is first (already
  # correct on Linux/CI); if it doesn't resolve and `cygpath` is on PATH (Git Bash
  # always provides it), translate via `cygpath -w` to the native Windows form.
  # This does not change what directory is being read, only how Elixir addresses it.
  defp resolve_native_path(dir) do
    if File.exists?(dir) do
      dir
    else
      case resolve_executable("cygpath") do
        nil ->
          dir

        cygpath ->
          case System.cmd(cygpath, ["-w", dir]) do
            {native, 0} -> native |> String.trim() |> String.replace("\\", "/")
            _ -> dir
          end
      end
    end
  end

  defp check_main_suite_logs(log_dir, exit_code) do
    case partition_logs(log_dir) do
      [] ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- partition log directory #{log_dir} " <>
            "contains zero partition-*.log files. The runner never actually ran " <>
            "any partitions, so this is a hard failure rather than a silent pass."
        )

      logs ->
        indexed_logs = index_partition_logs(logs)

        if exit_code != 0 do
          report_partition_failures(indexed_logs)

          Mix.raise(
            "mix letflow.check.test: FAILED -- scripts/test_parallel.sh exited " <>
              "#{exit_code} (real test failure/error). Partition logs: #{log_dir}"
          )
        end

        case check_substring_across_logs(indexed_logs) do
          {:offending, offending} ->
            offending_lines =
              offending
              |> Enum.map(fn {i, line} -> "  [partition #{i}] #{line}" end)
              |> Enum.join("\n")

            Mix.raise(
              "mix letflow.check.test: FAILED -- \"#{@target_substring}\" warning found " <>
                "(ISS-0069's own class recurring):\n#{offending_lines}\nPartition logs: #{log_dir}"
            )

          :ok ->
            echo_budget_measurements(indexed_logs)

            Mix.shell().info(
              "mix letflow.check.test: OK -- no test failures, no ISS-0069 warnings " <>
                "(#{length(logs)} partitions, logs: #{log_dir})."
            )
        end
    end
  end

  # Parses the runner's own captured stdout for its unconditional
  # "test_parallel: partition logs in <dir>" line. Never raises -- run_main_suite/0
  # is the one that turns :not_found into a Mix.raise, per this module's existing
  # separation between pure helpers and raising call sites.
  @spec find_partition_log_dir(String.t()) :: {:ok, Path.t()} | :not_found
  defp find_partition_log_dir(output) do
    case Regex.run(@log_dir_line_regex, output) do
      [_, dir] -> {:ok, String.trim(dir)}
      nil -> :not_found
    end
  end

  # Sorted list of partition-*.log paths directly under dir. Empty list is a legal
  # return -- the caller decides whether that's an error.
  @spec partition_logs(Path.t()) :: [Path.t()]
  defp partition_logs(dir) do
    dir
    |> Path.join("partition-*.log")
    |> Path.wildcard()
    |> Enum.sort()
  end

  # Attaches each log's 1-based partition index (parsed from its own filename, not
  # list position, so a gap or non-contiguous naming can't silently mislabel a log).
  @spec index_partition_logs([Path.t()]) :: [{pos_integer(), Path.t()}]
  defp index_partition_logs(logs) do
    Enum.map(logs, fn path ->
      index =
        case Regex.run(~r/partition-(\d+)\.log$/, path) do
          [_, n] -> String.to_integer(n)
          nil -> 0
        end

      {index, path}
    end)
  end

  # Concatenates every partition log's content and applies the ISS-0069 substring
  # check, tracking {partition_index, matching_line} pairs so failures can be
  # attributed to the partition they came from.
  @spec check_substring_across_logs([{pos_integer(), Path.t()}]) ::
          :ok | {:offending, [{pos_integer(), String.t()}]}
  defp check_substring_across_logs(indexed_logs) do
    offending =
      for {index, path} <- indexed_logs,
          line <- read_lines(path),
          String.contains?(line, @target_substring) do
        {index, line}
      end

    case offending do
      [] -> :ok
      lines -> {:offending, lines}
    end
  end

  # GH #2615: prints the budget-measurement line(s) from every partition log on a passing
  # run, so the CI job log carries the numbers (the partition logs are otherwise never shown).
  @spec echo_budget_measurements([{pos_integer(), Path.t()}]) :: :ok
  defp echo_budget_measurements(indexed_logs) do
    for {index, path} <- indexed_logs,
        line <- read_lines(path),
        String.contains?(line, @budget_measurement_marker) do
      Mix.shell().info("mix letflow.check.test: partition #{index} #{line}")
    end

    :ok
  end

  # Prints full content of every partition log showing a real `Failed:` line or a
  # missing `Result:` line (crashed before completing) -- design doc section 4.2.
  @spec report_partition_failures([{pos_integer(), Path.t()}]) :: :ok
  defp report_partition_failures(indexed_logs) do
    Enum.each(indexed_logs, fn {index, path} ->
      content = File.read!(path)

      cond do
        String.contains?(content, "Failed: ") ->
          Mix.shell().info("\n=== partition #{index} log (#{path}) -- FAILED ===\n#{content}")

        not String.contains?(content, "Result: ") ->
          Mix.shell().info(
            "\n=== partition #{index} log (#{path}) -- NO Result: LINE (crashed) ===\n#{content}"
          )

        true ->
          :ok
      end
    end)

    :ok
  end

  defp read_lines(path) do
    path
    |> File.read!()
    |> String.split("\n")
  end

  # ISS-0418 (design iss0418-wasm-hang-test-isolation-fix.md §4.2): a wasm_hang_hint
  # is one {file, line} pair as ExUnit's own --dry-run resolves it -- never
  # hand-derived or hardcoded (see discover_wasm_hang_tests/0 below).
  @type wasm_hang_location :: {file :: Path.t(), line :: pos_integer()}

  @type wasm_hang_test_result :: %{
          location: wasm_hang_location(),
          output: String.t(),
          exit_code: non_neg_integer()
        }

  @wasm_hang_test_list_regex ~r/^(test\/\S+\.exs):(\d+)$/

  # ISS-0524 (design doc §3.3): the header-anchored window's line bound, chosen with
  # margin above the 232-line header-to-terminator span empirically measured live
  # against this repository while designing the fix (see the design doc §3.2/§3.3 for
  # the full measurement and the caveat that this bound could in principle be
  # invalidated by future growth in compile-warning noise -- if the "bound reached,
  # terminator not confirmed" caveat below starts showing up routinely, that is the
  # signal to raise this number, not a silent truncation to quietly work around).
  @wasm_hang_discovery_window_lines 300

  # ISS-0524: the fallback tail length used only when the discovery output contains no
  # "Tests that would be executed:" header at all (see find_discovery_window/2).
  @wasm_hang_discovery_fallback_tail_lines 40

  # ISS-0418: run every currently-tagged :wasm_hang test in its own dedicated,
  # freshly-booted `mix test <file>:<line>` subprocess -- see moduledoc's ISS-0418
  # section and design doc §4.3. Replaces the prior single-shared-subprocess shape
  # (ISS-0352), which left every :wasm_hang test's permanently-leaked native worker
  # thread in one process, accumulating across tests until the pool was exhausted.
  # Unchanged by ISS-0428: stays serial (both the discovery subprocess and every
  # per-test subprocess), no test_parallel.sh involvement.
  @spec run_wasm_hang_tests() :: :ok | no_return()
  defp run_wasm_hang_tests do
    locations = discover_wasm_hang_tests()

    results = Enum.map(locations, &run_single_wasm_hang_test/1)

    {failing, passing} = Enum.split_with(results, fn %{exit_code: code} -> code != 0 end)
    offending = check_substring_across_wasm_hang_results(results)

    cond do
      failing != [] ->
        report_wasm_hang_failures(failing)

        failing_names =
          failing
          |> Enum.map(fn %{location: {file, line}} -> "#{file}:#{line}" end)
          |> Enum.join(", ")

        Mix.raise(
          "mix letflow.check.test: FAILED -- #{length(failing)}/#{length(results)} isolated " <>
            "wasm_hang tests failed: #{failing_names}"
        )

      offending != [] ->
        offending_lines = Enum.join(offending, "\n")

        Mix.raise(
          "mix letflow.check.test: FAILED -- \"#{@target_substring}\" warning found across the " <>
            "isolated :wasm_hang runs (ISS-0069's own class recurring):\n#{offending_lines}"
        )

      true ->
        Mix.shell().info(
          "mix letflow.check.test: OK -- #{length(passing)}/#{length(results)} isolated " <>
            "wasm_hang tests passed, each in its own subprocess."
        )
    end

    :ok
  end

  # ISS-0418 (design doc §4.2): asks ExUnit itself, via a --dry-run discovery
  # subprocess, which tests :wasm_hang currently resolves to -- deliberately not a
  # static grep of `@tag :wasm_hang` sites, which would re-implement (fragilely)
  # tag-resolution logic ExUnit already gets right (describe-level tags, multiple
  # @tag lines, etc). This makes the harness self-updating: adding, removing, or
  # renaming a :wasm_hang test anywhere is picked up automatically, no edit to this
  # file required. Hard-fails (rather than silently proceeding with zero tests and
  # reporting a false "OK") if the discovery subprocess itself is broken in any way.
  #
  # DEVIATION FROM DESIGN DOC (documented, not silent -- see handoff): §4.2 step 5
  # says to hard-fail if "the discovery subprocess exits nonzero." Live-verified
  # this session that `mix test --only wasm_hang --dry-run` exits **1 always**,
  # on every run, regardless of whether real :wasm_hang tests exist or the parse
  # would succeed -- `--dry-run` never executes anything, and Mix's own `mix test`
  # CLI treats "--only was given but 0 tests were executed" as an error condition
  # unconditionally ("The --only option was given to \"mix test\" but no test was
  # executed", exit 1), independent of dry-run's own success. Gating on this exit
  # code as the design specifies would make discovery hard-fail on every single
  # invocation, defeating the whole mechanism. This implementation does not check
  # the discovery subprocess's exit code at all; the parse result below (empty vs.
  # non-empty test-list block) is the only signal used to distinguish "discovery
  # broken" from "discovery succeeded," which is the actual reliable signal
  # available from this specific Mix/dry-run combination.
  # ISS-0524 (design doc §3.1): a single bounded retry when the first attempt's parsed
  # block comes back empty, to rule out a one-shot compile/manifest race (the same
  # class of run-to-run variance the DEVIATION comment above extract_test_list_block/1
  # already documents) without weakening the "never silently proceed with zero"
  # policy -- a persistently-empty block after the retry still hard-fails via
  # run_discovery_dry_run_or_raise/1 below. Exactly one retry, never a loop.
  @spec discover_wasm_hang_tests() :: [wasm_hang_location()]
  defp discover_wasm_hang_tests do
    first_output = run_discovery_dry_run()

    case extract_test_list_block(first_output) do
      [] ->
        Mix.shell().info(
          "mix letflow.check.test: NOTE -- first `mix test --only wasm_hang --dry-run` " <>
            "attempt found an empty \"Tests that would be executed:\" block; retrying once " <>
            "before treating this as a hard failure."
        )

        retry_output = run_discovery_dry_run()

        case extract_test_list_block(retry_output) do
          [] ->
            raise_discovery_hard_failure(retry_output)

          lines ->
            Mix.shell().info(
              "mix letflow.check.test: NOTE -- first `mix test --only wasm_hang --dry-run` " <>
                "attempt was empty, but the retry attempt succeeded."
            )

            lines |> Enum.map(&parse_wasm_hang_location!/1) |> Enum.sort()
        end

      lines ->
        lines
        |> Enum.map(&parse_wasm_hang_location!/1)
        |> Enum.sort()
    end
  end

  @spec run_discovery_dry_run() :: String.t()
  defp run_discovery_dry_run do
    {output, _exit_code} = stream_and_capture("mix", ["test", "--only", "wasm_hang", "--dry-run"])
    output
  end

  # ISS-0524 (design doc §3.2): both the first attempt and the retry came back empty --
  # this is the only hard-failure path for discovery. Builds the Mix.raise message
  # using the RETRY attempt's raw output only (the first attempt's raw output is
  # deliberately not embedded here -- it was already surfaced live via the
  # Mix.shell().info/1 line above, see the design doc's rationale for not duplicating
  # it), searching for the discovery header via find_discovery_window/2 so the
  # message's claims about what it captured are always true rather than assumed.
  @spec raise_discovery_hard_failure(String.t()) :: no_return()
  defp raise_discovery_hard_failure(retry_output) do
    framing =
      "mix letflow.check.test: FAILED -- `mix test --only wasm_hang --dry-run` exited 0 " <>
        "but its \"Tests that would be executed:\" block was empty or absent on BOTH the " <>
        "first attempt and a retry attempt. This task cannot tell whether that means zero " <>
        ":wasm_hang tests currently exist or the discovery parse itself is broken, so it is " <>
        "treating this as a hard failure rather than silently passing."

    detail =
      cond do
        String.trim(retry_output) == "" ->
          "The retry attempt's raw output was completely empty (zero bytes/lines captured) " <>
            "-- the dry-run subprocess produced no output whatsoever."

        true ->
          case find_discovery_window(retry_output, @wasm_hang_discovery_window_lines) do
            :header_not_found ->
              "The retry attempt's raw output contains no \"Tests that would be executed:\" " <>
                "header at all; this is a more severe signal than an empty block, since the " <>
                "dry-run subprocess's own discovery output format itself may be broken " <>
                "(crashed early, produced no output, or its output shape has changed), not " <>
                "merely resolving to zero tests.\n\n" <>
                "Generic tail (no header to anchor a targeted excerpt to), last " <>
                "#{@wasm_hang_discovery_fallback_tail_lines} lines of the retry attempt's " <>
                "raw output:\n" <>
                last_output_lines(retry_output, @wasm_hang_discovery_fallback_tail_lines)

            {:header_found, window, true} ->
              "Header found; showing the retry attempt's captured window from the header " <>
                "through the terminator line:\n" <> window

            {:header_found, window, false} ->
              "Header found; showing the retry attempt's captured window from the header, " <>
                "but the #{@wasm_hang_discovery_window_lines}-line capture bound was reached " <>
                "before a terminator line was found -- this excerpt may not include the full " <>
                "block, so it should not be read as complete:\n" <> window
          end
      end

    Mix.raise(framing <> "\n\n" <> detail)
  end

  # Locates the "Tests that would be executed:" line in --dry-run's captured
  # output and returns the file:line entries in the block of lines between it and
  # the next terminator line ("All tests have been excluded." or "Finished in ...",
  # both always printed by --dry-run once the list ends) -- scoping the parse to
  # exactly the test-list block rather than trusting the whole stream (design doc
  # §4.2 step 2, same discipline as find_partition_log_dir/1's own narrowly-scoped
  # regex above).
  #
  # DEVIATION FROM DESIGN DOC (documented, not silent -- see handoff): §4.2 step 2
  # specifies taking the block "up to the next blank line or a line that does not
  # match the file:line shape," implying the test-list lines are contiguous
  # immediately after the header. Live-verified this session (5 consecutive real
  # `mix test --only wasm_hang --dry-run` runs against the full, uncached test
  # suite) that this assumption does not hold in practice: ExUnit's own
  # non-deterministic compiler-warning emission for OTHER, unrelated test files
  # (re-diagnosed every run, seemingly regardless of compile-manifest cache state)
  # interleaves directly between the header and the actual file:line entries, and
  # sometimes between individual entries. A strict `take_while` that stops at the
  # first non-matching line would therefore intermittently discover 0 tests and
  # hard-fail (per this task's own "never silently proceed with zero" discipline)
  # even though 5 real :wasm_hang tests exist -- a false negative, not a true
  # "discovery broken" case. This implementation instead FILTERS every line in the
  # bounded window between the header and the terminator for the file:line shape,
  # which is robust to warning interleaving inside that window while still bounding
  # the scan to the correct section of output (never scanning the whole stream).
  @spec extract_test_list_block(String.t()) :: [String.t()]
  defp extract_test_list_block(output) do
    output
    |> split_output_lines()
    |> Enum.drop_while(&(&1 != "Tests that would be executed:"))
    |> case do
      [] ->
        []

      [_header | rest] ->
        rest
        |> Enum.take_while(fn line ->
          not String.starts_with?(line, "All tests have been excluded.") and
            not String.starts_with?(line, "Finished in")
        end)
        |> Enum.filter(&Regex.match?(@wasm_hang_test_list_regex, String.trim(&1)))
    end
  end

  # Shared with extract_test_list_block/1's own bounding logic above -- a line is a
  # "terminator" once discovery's test-list block has ended, either form always
  # printed by --dry-run once the list ends.
  @spec wasm_hang_discovery_terminator_line?(String.t()) :: boolean()
  defp wasm_hang_discovery_terminator_line?(line) do
    String.starts_with?(line, "All tests have been excluded.") or
      String.starts_with?(line, "Finished in")
  end

  # ISS-0524 (design doc §3.3): line-oriented boundary-finding only -- find the
  # discovery header, then find either a terminator line or the bound, whichever
  # comes first, and slice between. Does NOT interpret/filter individual entry lines
  # the way extract_test_list_block/1 does; this helper's job is to show the raw
  # window for a human to read in a Mix.raise message, not to extract structured
  # entries for the program to consume. Mirrors extract_test_list_block/1's own
  # header/terminator recognition exactly, so this helper's notion of "the header"
  # and "the terminator" never diverges from the parsing logic's.
  @spec find_discovery_window(String.t(), pos_integer()) ::
          {:header_found, window :: String.t(), terminator_reached? :: boolean()}
          | :header_not_found
  defp find_discovery_window(output, bound) do
    lines = split_output_lines(output)

    case Enum.drop_while(lines, &(&1 != "Tests that would be executed:")) do
      [] ->
        :header_not_found

      [header | rest] ->
        {collected, terminator_reached?} = collect_discovery_window(rest, bound)
        {:header_found, Enum.join([header | collected], "\n"), terminator_reached?}
    end
  end

  @spec collect_discovery_window([String.t()], non_neg_integer()) :: {[String.t()], boolean()}
  defp collect_discovery_window(_lines, 0), do: {[], false}

  defp collect_discovery_window([], _remaining), do: {[], false}

  defp collect_discovery_window([line | rest], remaining) do
    if wasm_hang_discovery_terminator_line?(line) do
      {[line], true}
    else
      {tail, terminator_reached?} = collect_discovery_window(rest, remaining - 1)
      {[line | tail], terminator_reached?}
    end
  end

  # ISS-0524 (design doc §3.3): retained fallback for the :header_not_found branch --
  # a generic tail is the only available context when there is no header to anchor a
  # targeted window to. Prefixes an explicit truncation marker only when truncation
  # actually occurred.
  @spec last_output_lines(String.t(), pos_integer()) :: String.t()
  defp last_output_lines(output, n) do
    lines = split_output_lines(output)
    total = length(lines)

    tail = Enum.take(lines, -n)

    if total > n do
      Enum.join(["...(truncated, showing last #{n} of #{total} lines)..." | tail], "\n")
    else
      Enum.join(tail, "\n")
    end
  end

  # Splits output on \n and strips trailing \r from each line so CRLF output
  # from Windows .bat fixtures matches the same header literals as Unix output.
  @spec split_output_lines(String.t()) :: [String.t()]
  defp split_output_lines(output) do
    output |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r"))
  end

  @spec parse_wasm_hang_location!(String.t()) :: wasm_hang_location()
  defp parse_wasm_hang_location!(line) do
    case Regex.run(@wasm_hang_test_list_regex, String.trim(line)) do
      [_, file, line_str] ->
        {file, String.to_integer(line_str)}

      nil ->
        Mix.raise(
          "mix letflow.check.test: FAILED -- could not parse a `file:line` pair from " <>
            "`mix test --only wasm_hang --dry-run`'s test-list line: #{inspect(line)}"
        )
    end
  end

  # ISS-0418 (design doc §4.1): the command is `mix test <file>:<line>` ALONE --
  # deliberately WITHOUT `--only wasm_hang`. Verified live (design doc §4.1) that
  # `--only <tag>` and `<file>:<line>` do NOT compose: `<file>:<line>` is sugar for
  # `--exclude test --include line:N`, which entirely replaces any --only/--include
  # also given on the same command line, so a trailing `--only wasm_hang` would be
  # silently discarded -- harmless (changes nothing) but misleading to a future
  # reader into thinking it does something. Do not add it back. `<file>:<line>`
  # alone already bypasses test/test_helper.exs's default :wasm_hang exclusion, so
  # no --only/--include is needed at all for the addressed test to actually run.
  @spec run_single_wasm_hang_test(wasm_hang_location()) :: wasm_hang_test_result()
  defp run_single_wasm_hang_test({file, line} = location) do
    {output, exit_code} = stream_and_capture("mix", ["test", "#{file}:#{line}"])
    %{location: location, output: output, exit_code: exit_code}
  end

  # Prints the full captured output of every failing per-test subprocess result --
  # same "show the real failure text, don't make the reader dig for it" principle
  # as report_partition_failures/1 above, applied to this new per-test data shape.
  @spec report_wasm_hang_failures([wasm_hang_test_result()]) :: :ok
  defp report_wasm_hang_failures(failing) do
    Enum.each(failing, fn %{location: {file, line}, output: output} ->
      Mix.shell().info(
        "\n=== isolated wasm_hang subprocess #{file}:#{line} -- FAILED ===\n#{output}"
      )
    end)

    :ok
  end

  # Same ISS-0069 substring check as the main suite, applied across the
  # concatenation of all N per-test wasm_hang subprocess outputs instead of one.
  @spec check_substring_across_wasm_hang_results([wasm_hang_test_result()]) :: [String.t()]
  defp check_substring_across_wasm_hang_results(results) do
    for %{output: output} <- results,
        line <- String.split(output, "\n"),
        String.contains?(line, @target_substring) do
      line
    end
  end

  # ISS-0426: run the tag-isolated :lua_wallclock_race tests (REQ-155/156/162,
  # test/letflow/engine/lua/executor_test.exs) in their own subprocess, isolated
  # from the main run above -- same shape as run_wasm_hang_tests/0, see
  # lib/letflow/design/iss426-wallclock-test-contention.md §2.3 and this module's
  # moduledoc's ISS-0352 section. Unlike :wasm_hang, these tests don't leak
  # anything -- they just need to run without racing 30+ concurrently-scheduled
  # siblings for wall-clock-sensitive timing. Unchanged by ISS-0428: stays serial.
  defp run_lua_wallclock_race_tests do
    {race_output, race_exit_code} =
      stream_and_capture("mix", ["test", "--only", "lua_wallclock_race"])

    if race_exit_code != 0 do
      Mix.raise(
        "mix letflow.check.test: FAILED -- isolated `mix test --only lua_wallclock_race` " <>
          "run exited #{race_exit_code} (real test failure/error)."
      )
    end

    if String.contains?(race_output, @target_substring) do
      offending_lines =
        race_output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, @target_substring))
        |> Enum.join("\n")

      Mix.raise(
        "mix letflow.check.test: FAILED -- \"#{@target_substring}\" warning found in the " <>
          "isolated :lua_wallclock_race run (ISS-0069's own class recurring):\n#{offending_lines}"
      )
    end

    Mix.shell().info(
      "mix letflow.check.test: OK -- isolated :lua_wallclock_race run also passed clean."
    )
  end

  # Runs `cmd` as a subprocess via an OS-level Port so its combined
  # stdout+stderr is streamed live (visible immediately, same as running
  # the command directly) while also being captured in full for the
  # substring check above. `System.cmd/3`'s own `:into` option can do one
  # or the other but not both at once (an `IO.stream` target prints live
  # but discards the text; a plain list/binary target captures but only
  # after the subprocess exits), so a raw port is used instead.
  # ISS-0697: the single seam through which this module resolves an executable name to
  # a path. Consults the {:letflow, :check_test_executable_resolver} Application env key
  # -- unset in every real (non-test) invocation, so the default here (real
  # System.find_executable/1) is what actually runs -- falling back to whatever
  # resolver value a test has installed there (see
  # test/mix/tasks/letflow_check_test_test.exs's install_executable_resolver/2). This is
  # the ONLY place in this module that may call System.find_executable/1 directly; every
  # other call site above goes through this function instead (design doc §2).
  @spec resolve_executable(String.t()) :: Path.t() | nil
  defp resolve_executable(name) do
    resolver =
      Application.get_env(
        :letflow,
        :check_test_executable_resolver,
        &System.find_executable/1
      )

    resolver.(name)
  end

  # ISS-0699 (design doc §3a.2): `env` is an optional third argument, an :env-style
  # list of {name, value} tuples forwarded to Port.open/2's own :env option, which
  # only adds/overrides the named vars on top of this BEAM process's already-
  # inherited environment -- it does not replace the environment wholesale, so the
  # `[]` default changes nothing for the three call sites that don't pass it.
  defp stream_and_capture(cmd, args, env \\ []) do
    executable = resolve_executable(cmd) || raise "executable not found: #{cmd}"

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args
    ]

    # Erlang's `:env` port option requires each name/value to be a charlist (or
    # atom), not a binary -- passing binaries raises `ArgumentError: invalid option
    # in list` from `:erlang.open_port/2` (confirmed live against this OTP/host).
    # Only add the :env key at all when non-empty, so the three call sites that
    # don't pass env stay byte-for-byte identical to the pre-ISS-0699 opts list.
    port_opts =
      case env do
        [] -> port_opts
        _ -> port_opts ++ [env: Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)]
      end

    port = Port.open({:spawn_executable, executable}, port_opts)

    collect(port, [])
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, chunk}} ->
        IO.write(chunk)
        collect(port, [acc, chunk])

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(acc), status}
    end
  end
end
