defmodule Mix.Tasks.Letflow.Check.TestTest do
  @moduledoc """
  Regression coverage for `mix letflow.check.test` (`lib/mix/tasks/letflow.check.test.ex`)
  after ISS-0428 rewrote it to shell out to `bash scripts/test_parallel.sh` (an N-way
  parallel `mix test --partitions N` runner) instead of plain `mix test`, and re-pointed
  the ISS-0069 warning gate at the N per-partition log files the runner writes instead
  of the wrapper's own aggregated stdout.

  ## Why this file exists at all (read before touching it)

  This suite is the ONLY automated coverage of the ISS-0069 warning gate --
  `check_substring_across_logs/1` catching a recurrence of "default values for the
  optional arguments" (`docs/anti-patterns.md`, 7 prior real occurrences:
  REQ-178/187/191/195/203 among others). ISS-0428's own design doc
  (`lib/letflow/design/iss0428-parallel-runner-in-check-test.md` §1.1) is explicit that
  pointing this check at the wrong stream makes the gate go green while checking
  nothing, permanently, with nobody able to tell from a passing CI run. A suite that
  merely re-green-lights the new architecture without proving the gate still catches a
  real occurrence would be exactly that hazard, just relocated into the test file
  instead of the implementation.

  ## Technique: fake `bash` (and `mix`) on PATH, not the log-parsing internals directly

  The old (pre-ISS-0428) version of this file faked `mix` on PATH so that
  `System.find_executable("mix")` -- called internally by `run/1`'s single subprocess
  call -- resolved to a controlled fake instead of a real, recursing `mix test`. That
  interception point is gone: `run_main_suite/0` now calls `System.find_executable("bash")`
  and invokes `bash scripts/test_parallel.sh`, so a faked `mix` no longer intercepts the
  main suite's subprocess at all.

  This file fakes `bash` the same way the old file faked `mix` -- same technique, same
  spirit, moved to the seam the rewritten code actually shells out through. Three real
  alternatives were weighed:

    1. **Fake `bash` on PATH (chosen).** `run_main_suite/0`'s only interaction with the
       outside world is `System.find_executable("bash")` followed by a Port-spawned
       `bash scripts/test_parallel.sh` invocation whose captured stdout is parsed. A
       fake `bash` that prints a controlled `test_parallel: partition logs in <dir>`
       line (pointing at a synthetic fixture directory containing real files named
       `partition-N.log`) and exits with a controlled code drives `run_main_suite/0`
       and every private helper it calls (`find_partition_log_dir/1`, `partition_logs/1`,
       `check_substring_across_logs/1`, `report_partition_failures/1`) for REAL, exactly
       as committed -- nothing in the module under test is mocked, stubbed, or
       temporarily un-privatized. This is the closest available analogue to the old
       file's own technique and needs zero changes to `letflow.check.test.ex`.
    2. **Test the log-reading logic directly against fixtures, bypassing the
       subprocess.** Rejected as the *sole* technique: `find_partition_log_dir/1`,
       `partition_logs/1`, and `check_substring_across_logs/1` are `defp` today, so
       this would require either un-privatizing them (which the design doc's own
       Verification 3/4 did only temporarily, as a one-off probe, explicitly reverted
       afterward -- see the ELIXIR-DEV handoff) or duplicating their logic in the test,
       which would test the duplicate, not the shipped code. The design doc's public
       interface section (§6) does not ask for these to become public, and inventing a
       permanent testability seam not asked for by the design is a bigger footprint
       than option 1 needs. **Flagging this as a considered-and-rejected testability
       question, not a silent decision**: if a future maintainer wants direct unit
       tests of the parsing/globbing logic in isolation from the `bash` fake, the
       minimal change would be promoting exactly those three functions from `defp` to
       `def` (or `@doc false def`) -- nothing more. Not done here because option 1
       already reaches every one of them through the real public entry point,
       including their composition (ordering rule, error precedence), which isolated
       unit tests of the pieces alone would not.
    3. **Combination (fixtures for parsing + one real integration run).** Rejected for
       the "one real integration run" half: `scripts/test_parallel.sh` derives N from
       `nproc` and launches N real `mix test --partitions N` subprocesses against a
       real Postgres -- multiple minutes per run, non-deterministic partition-to-N
       assignment across hosts, and exactly the kind of slow/flaky addition to a suite
       that runs on every commit `docs/agents/instructions/core-directives.md` warns
       against manufacturing. A real end-to-end run of `test_parallel.sh` already
       exists as evidence in the ELIXIR-DEV and CODE-DESIGN-VALIDATOR handoffs (both
       quote real measured output against the real script); this file does not need to
       re-pay that cost on every CI run to preserve that evidence -- TEST-RUNNER/
       RELEASE-VALIDATOR's own full-suite run of `mix letflow.check.test` (which
       necessarily invokes the real script) is what continues exercising the real
       integration path going forward.

  All fixture data (`partition-N.log` files) lives under a fresh `System.tmp_dir!/0`
  subdirectory per test, deleted in `on_exit/1` -- no fixture is checked into the repo,
  since the content needed (a controlled ISS-0069-shaped warning line, a controlled
  `Failed:`/`Result:` shape) is small enough to construct inline and keeping it inline
  keeps the "what exactly is being proven" visible in the test itself rather than in a
  separate file a reader has to cross-reference.

  ## Windows PATH resolution (ISS-0171, same hazard as before, same fix as before)

  Exactly the same two problems the old file's own `install_fake_mix/2` documented
  apply unchanged to faking `bash`: (1) `System.find_executable/1` on Windows resolves
  a bare name against PATHEXT-style extensions, so an extensionless POSIX-shaped fake
  is invisible and the REAL `bash.exe` gets picked off PATH instead; (2) `PATH` uses
  `;` as its entry separator on Windows, not `:`. `install_fake_executable/3` below
  follows the old file's exact `.bat`-with-companion-`type`-file pattern for the same
  reason (arbitrary content -- quotes, parens, colons, exactly what a real compiler
  warning line and a `Mix.raise` message contain -- must never have to survive batch's
  own escaping rules), generalized to install any named executable rather than just
  `mix`.

  ## Fail-then-pass, proven not asserted (per WF-03's own requirement for this file)

  Every test below was run against this file's own committed logic AND independently
  re-derived by TEST-DESIGNER directly against the real, unmodified, shipped
  `Mix.Tasks.Letflow.Check.Test.run/1` via ad-hoc `mix run --no-start` probes using this
  exact fake-`bash`-on-PATH technique before this file was written (see the
  TEST-DESIGNER handoff for the literal transcripts of all six probes: the two "detects
  a real occurrence" cases, both hard-failure paths, the ordering rule, and the
  wrapper-nonzero-with-logs-present failure-reporting path) -- so these tests are known,
  by direct prior measurement against the real code, to pass against the fix. The
  mutation-testing requirement below (this issue's underlying code already existed
  pre-ISS-0428, so the "pre-fix code did not exist" carve-out does not strictly apply --
  but see the handoff for why one mutant is reported anyway, as belt-and-suspenders
  evidence) additionally proves each test can fail for the right reason.
  """

  use ExUnit.Case, async: false

  @target_substring "default values for the optional arguments"

  setup do
    # Q-1037: a sharded CI job exports TEST_PARALLEL_* into this VM; run/1 must see none.
    Letflow.Test.TestParallelEnv.scrub_ambient!()

    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "letflow_check_test_fixture_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fixture_root)
    on_exit(fn -> File.rm_rf!(fixture_root) end)

    fake_bin_dir =
      Path.join(
        System.tmp_dir!(),
        "letflow_check_test_fakebin_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(fake_bin_dir)
    on_exit(fn -> File.rm_rf!(fake_bin_dir) end)

    %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir}
  end

  # Installs a fake executable named `name` (no extension) onto a shared fake-bin
  # directory, then prepends that directory onto PATH so
  # System.find_executable(name) resolves to it instead of the real one. `output` is
  # printed verbatim to stdout; `exit_code` is the process exit code.
  #
  # ISS-0171 (same hazard the old install_fake_mix/2 documented, generalized to any
  # executable name rather than hardcoded to "mix"): on Windows, System.find_executable/1
  # requires a PATHEXT-recognized extension (an extensionless file is invisible), and
  # PATH entries are ";"-separated, not ":"-separated. The Windows fake writes its
  # canned output to a companion file and has a .bat `type` it rather than `echo`-ing
  # inline, so arbitrary content (quotes, parens, colons) never has to survive batch's
  # own escaping rules -- verified directly: a `Mix.raise` message and a real compiler
  # warning line both contain characters batch's `echo` mangles.
  defp install_fake_executable(fake_bin_dir, name, output, exit_code) do
    case :os.type() do
      {:win32, _} ->
        output_path = Path.join(fake_bin_dir, "#{name}_output.txt")
        File.write!(output_path, output)

        fake_path = Path.join(fake_bin_dir, "#{name}.bat")
        windows_output_path = String.replace(output_path, "/", "\\")

        File.write!(fake_path, """
        @echo off
        type "#{windows_output_path}"
        exit /b #{exit_code}
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, name)

        File.write!(fake_path, """
        #!/bin/sh
        cat <<'FAKE_EXECUTABLE_OUTPUT'
        #{output}
        FAKE_EXECUTABLE_OUTPUT
        exit #{exit_code}
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  # ISS-0697: installs an Application-env resolver override
  # ({:letflow, :check_test_executable_resolver}) instead of mutating the real,
  # OS-process-global PATH -- see design doc iss0697-check-test-executable-resolver-fix.md
  # §3. For each `name` in `names`, computes the expected fake-file path exactly as
  # install_fake_executable/4 wrote it (mirrors, not duplicates divergently, that
  # function's own naming convention) and builds a name => fake_path override map. The
  # stored resolver looks up a given name in that map and returns nil for anything not
  # explicitly faked -- deliberately NOT falling back to real System.find_executable/1
  # for unmapped names, so an unfaked name fails loudly (via stream_and_capture/2's own
  # "executable not found" raise) instead of silently resolving to a real executable,
  # which is the whole point of this fix.
  #
  # Fail-fast guard (replaces the old PATH-search-based check): asserts
  # File.exists?/1 against each expected fake path BEFORE installing the resolver,
  # catching a wiring bug between this function's path construction and
  # install_fake_executable/4's naming convention deterministically and locally, rather
  # than via a multi-minute real-subprocess timeout.
  #
  # Cleanup: registers on_exit/1 to delete the Application env override after the test
  # -- this key has no legitimate non-test setter, so unconditional delete (not
  # "restore prior value") is correct.
  defp install_executable_resolver(fake_bin_dir, names) do
    overrides =
      Map.new(names, fn name ->
        fake_path =
          case :os.type() do
            {:win32, _} -> Path.join(fake_bin_dir, "#{name}.bat")
            _ -> Path.join(fake_bin_dir, name)
          end

        unless File.exists?(fake_path) do
          flunk("""
          install_executable_resolver/2 expected a fake executable file for #{inspect(name)} \
          at #{inspect(fake_path)}, but it does not exist. This would either resolve to nil \
          (unmapped-name failure) or indicate install_fake_executable/4's naming convention \
          has diverged from this function's own path construction.
          """)
        end

        {name, fake_path}
      end)

    # NOTE: the module under test resolves each executable TWICE per subprocess --
    # once by bare name at the call site (e.g. `resolve_executable("bash")` in
    # run_main_suite/0), then again by the already-resolved path inside
    # stream_and_capture/2 (`resolve_executable(cmd)`, where `cmd` is the value the
    # first call returned). Real System.find_executable/1 is idempotent on an
    # already-resolved absolute path (it recognizes an existing file given by full
    # path and returns it as-is), so this fake resolver must be too: fall back to
    # returning `name` unchanged when it is itself one of this map's own fake-path
    # values, still never falling through to a real PATH search for anything else.
    fake_paths = MapSet.new(Map.values(overrides))

    Application.put_env(:letflow, :check_test_executable_resolver, fn name ->
      cond do
        Map.has_key?(overrides, name) -> Map.get(overrides, name)
        MapSet.member?(fake_paths, name) -> name
        true -> nil
      end
    end)

    on_exit(fn -> Application.delete_env(:letflow, :check_test_executable_resolver) end)

    :ok
  end

  # Installs a passing fake `mix` (used by run_lua_wallclock_race_tests/0, unchanged
  # by ISS-0428/ISS-0418 and still shelling directly to a single `mix test --only
  # lua_wallclock_race`) so a test that only cares about run_main_suite/0's behavior
  # doesn't pay the cost -- or the nondeterminism -- of a real subprocess run on
  # every case below. Every test in this file except the one at "passes (no raise)
  # ..." below raises inside run_main_suite/0 itself, so `mix` (used only by the
  # two isolated-test-tag stages that run AFTER run_main_suite/0) is never actually
  # invoked in those cases -- this fake is installed there purely defensively.
  #
  # ISS-0418 NOTE: this static, args-blind fake is NOT sufficient for
  # run_wasm_hang_tests/0's own new shape (a `--dry-run` discovery call followed by
  # N per-test `mix test <file>:<line>` calls, see letflow.check.test.ex) -- a fixed
  # "Result: 0 passed" response never contains "Tests that would be executed:", so
  # discover_wasm_hang_tests/0 correctly treats it as a broken discovery run and
  # hard-fails. Use install_wasm_hang_aware_fake_mix/1 instead for any test whose
  # path reaches run_wasm_hang_tests/0.
  defp install_passing_fake_mix(fake_bin_dir) do
    install_fake_executable(
      fake_bin_dir,
      "mix",
      "Finished in 0.0 seconds\nResult: 0 passed\n",
      0
    )
  end

  # ISS-0418: an args-aware fake `mix`, for the one test below whose path actually
  # reaches run_wasm_hang_tests/0 (every other test raises inside run_main_suite/0
  # first, per install_passing_fake_mix/1's own note above). Dispatches on argv
  # shape rather than returning one static response, since run_wasm_hang_tests/0
  # now issues genuinely different commands in sequence: one `--dry-run` discovery
  # call, then one `mix test <file>:<line>` call per discovered fake location, then
  # (unchanged) one `--only lua_wallclock_race` call from the next stage.
  defp install_wasm_hang_aware_fake_mix(fake_bin_dir) do
    case :os.type() do
      {:win32, _} ->
        fake_path = Path.join(fake_bin_dir, "mix.bat")

        File.write!(fake_path, """
        @echo off
        setlocal
        set ARGS=%*
        echo %ARGS% | findstr /C:"--dry-run" >nul
        if %ERRORLEVEL%==0 (
          echo Tests that would be executed:
          echo test/fake_wasm_hang_test.exs:1
          echo All tests have been excluded.
          echo Finished in 0.0 seconds
          echo Result: 0 tests, 1 excluded
          exit /b 1
        )
        echo %ARGS% | findstr /C:"fake_wasm_hang_test" >nul
        if %ERRORLEVEL%==0 (
          echo Finished in 0.0 seconds
          echo Result: 1 passed
          exit /b 0
        )
        echo Finished in 0.0 seconds
        echo Result: 0 passed
        exit /b 0
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, "mix")

        File.write!(fake_path, """
        #!/bin/sh
        case "$*" in
          *"--dry-run"*)
            cat <<'FAKE_DISCOVERY_OUTPUT'
        Tests that would be executed:
        test/fake_wasm_hang_test.exs:1
        All tests have been excluded.
        Finished in 0.0 seconds
        Result: 0 tests, 1 excluded
        FAKE_DISCOVERY_OUTPUT
            exit 1
            ;;
          *"fake_wasm_hang_test"*)
            echo "Finished in 0.0 seconds"
            echo "Result: 1 passed"
            exit 0
            ;;
          *)
            echo "Finished in 0.0 seconds"
            echo "Result: 0 passed"
            exit 0
            ;;
        esac
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  # ISS-0524: fixtures for discover_wasm_hang_tests/0's bounded single retry and its
  # header-anchored hard-failure message (lib/letflow/design/iss0524-wasm-hang-hang-discovery-diagnosability.md
  # §5). Each `--dry-run` invocation is a fresh subprocess, so "was this the first or a
  # later call" state must live outside the fake script's own process -- a marker file
  # under `fake_bin_dir` (which persists for the whole test, cleaned up in on_exit/1).
  #
  # Windows fakes below use a companion `type`-file (same technique
  # install_fake_executable/3 uses generically) instead of inline `echo`, since some of
  # this fixture's content (noise lines) is large/arbitrary and batch's `echo` inside an
  # `if (...)` block breaks on stray parentheses -- a `goto`-based dispatch plus `type`
  # sidesteps that entirely rather than fighting batch's escaping rules per line.
  defp normalize_for_shell(path) do
    path |> Path.expand() |> String.replace("\\", "/")
  end

  # Fixture 1: first --dry-run call returns an empty/absent-header block, second (and
  # any later) call returns the same successful block install_wasm_hang_aware_fake_mix/1
  # already returns. Used for test (b): retry actually retries once and succeeds.
  defp install_wasm_hang_retry_succeeds_fake_mix(fake_bin_dir) do
    marker_path = Path.join(fake_bin_dir, "retry_succeeds_marker") |> normalize_for_shell()

    empty_block = """
    All tests have been excluded.
    Finished in 0.0 seconds
    Result: 0 tests, 1 excluded
    """

    success_block = """
    Tests that would be executed:
    test/fake_wasm_hang_test.exs:1
    All tests have been excluded.
    Finished in 0.0 seconds
    Result: 0 tests, 1 excluded
    """

    case :os.type() do
      {:win32, _} ->
        marker_win = String.replace(marker_path, "/", "\\")
        empty_file = Path.join(fake_bin_dir, "retry_succeeds_empty.txt")
        success_file = Path.join(fake_bin_dir, "retry_succeeds_success.txt")
        File.write!(empty_file, empty_block)
        File.write!(success_file, success_block)
        empty_file_win = String.replace(empty_file, "/", "\\")
        success_file_win = String.replace(success_file, "/", "\\")

        fake_path = Path.join(fake_bin_dir, "mix.bat")

        File.write!(fake_path, """
        @echo off
        setlocal
        set ARGS=%*
        echo %ARGS% | findstr /C:"--dry-run" >nul
        if %ERRORLEVEL%==0 goto dryrun
        echo %ARGS% | findstr /C:"fake_wasm_hang_test" >nul
        if %ERRORLEVEL%==0 (
          echo Finished in 0.0 seconds
          echo Result: 1 passed
          exit /b 0
        )
        echo Finished in 0.0 seconds
        echo Result: 0 passed
        exit /b 0

        :dryrun
        if exist "#{marker_win}" (
          type "#{success_file_win}"
          exit /b 1
        )
        echo. > "#{marker_win}"
        type "#{empty_file_win}"
        exit /b 1
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, "mix")

        File.write!(fake_path, """
        #!/bin/sh
        case "$*" in
          *"--dry-run"*)
            if [ -f "#{marker_path}" ]; then
        cat <<'FAKE_RETRY_SUCCESS_OUTPUT'
        #{success_block}
        FAKE_RETRY_SUCCESS_OUTPUT
              exit 1
            else
              touch "#{marker_path}"
        cat <<'FAKE_RETRY_EMPTY_OUTPUT'
        #{empty_block}
        FAKE_RETRY_EMPTY_OUTPUT
              exit 1
            fi
            ;;
          *"fake_wasm_hang_test"*)
            echo "Finished in 0.0 seconds"
            echo "Result: 1 passed"
            exit 0
            ;;
          *)
            echo "Finished in 0.0 seconds"
            echo "Result: 0 passed"
            exit 0
            ;;
        esac
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  # Fixture 2: every --dry-run call returns the header immediately followed by a
  # terminator (an empty block, not an absent header), but each call's output embeds a
  # distinguishing "attempt=N" marker so a test can prove the raised message embeds the
  # RETRY attempt's output specifically. Also appends one line per --dry-run call to a
  # counter file so a test can assert --dry-run was invoked exactly twice.
  defp install_wasm_hang_retry_still_fails_fake_mix(fake_bin_dir) do
    marker_path = Path.join(fake_bin_dir, "still_fails_marker") |> normalize_for_shell()
    count_path = Path.join(fake_bin_dir, "still_fails_count") |> normalize_for_shell()

    block = fn attempt ->
      """
      Tests that would be executed:
      attempt=#{attempt}
      All tests have been excluded.
      Finished in 0.0 seconds
      Result: 0 tests, 1 excluded
      """
    end

    case :os.type() do
      {:win32, _} ->
        marker_win = String.replace(marker_path, "/", "\\")
        count_win = String.replace(count_path, "/", "\\")
        attempt1_file = Path.join(fake_bin_dir, "still_fails_attempt1.txt")
        attempt2_file = Path.join(fake_bin_dir, "still_fails_attempt2.txt")
        File.write!(attempt1_file, block.(1))
        File.write!(attempt2_file, block.(2))
        attempt1_win = String.replace(attempt1_file, "/", "\\")
        attempt2_win = String.replace(attempt2_file, "/", "\\")

        fake_path = Path.join(fake_bin_dir, "mix.bat")

        File.write!(fake_path, """
        @echo off
        setlocal
        set ARGS=%*
        echo %ARGS% | findstr /C:"--dry-run" >nul
        if %ERRORLEVEL%==0 goto dryrun
        echo Finished in 0.0 seconds
        echo Result: 0 passed
        exit /b 0

        :dryrun
        echo x >> "#{count_win}"
        if exist "#{marker_win}" (
          type "#{attempt2_win}"
          exit /b 1
        )
        echo. > "#{marker_win}"
        type "#{attempt1_win}"
        exit /b 1
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, "mix")

        File.write!(fake_path, """
        #!/bin/sh
        case "$*" in
          *"--dry-run"*)
            echo x >> "#{count_path}"
            if [ -f "#{marker_path}" ]; then
        cat <<'FAKE_STILL_FAILS_ATTEMPT2'
        #{block.(2)}
        FAKE_STILL_FAILS_ATTEMPT2
              exit 1
            else
              touch "#{marker_path}"
        cat <<'FAKE_STILL_FAILS_ATTEMPT1'
        #{block.(1)}
        FAKE_STILL_FAILS_ATTEMPT1
              exit 1
            fi
            ;;
          *)
            echo "Finished in 0.0 seconds"
            echo "Result: 0 passed"
            exit 0
            ;;
        esac
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  # Fixture 3: every --dry-run call returns the header, then `filler_line_count` lines
  # of numbered filler simulating unrelated compiler-warning noise (the real shape
  # measured live against this repository, design doc §3.2), then a terminator only
  # when `include_terminator?` is true. No retry-count state needed -- both calls
  # return the same (possibly oversized) response, since this fixture exercises the
  # window-vs-bound behavior, not the retry-count logic already covered by fixtures 1/2.
  defp install_wasm_hang_retry_noisy_window_fake_mix(
         fake_bin_dir,
         filler_line_count,
         include_terminator?
       ) do
    filler =
      Enum.map_join(1..filler_line_count, "\n", fn n ->
        "noise line #{n} simulating unrelated compiler warning output"
      end)

    body =
      if include_terminator? do
        """
        Tests that would be executed:
        #{filler}
        All tests have been excluded.
        Finished in 0.0 seconds
        Result: 0 tests, 1 excluded
        """
      else
        """
        Tests that would be executed:
        #{filler}
        """
      end

    case :os.type() do
      {:win32, _} ->
        content_file = Path.join(fake_bin_dir, "noisy_window_#{filler_line_count}.txt")
        File.write!(content_file, body)
        content_win = String.replace(content_file, "/", "\\")

        fake_path = Path.join(fake_bin_dir, "mix.bat")

        File.write!(fake_path, """
        @echo off
        setlocal
        set ARGS=%*
        echo %ARGS% | findstr /C:"--dry-run" >nul
        if %ERRORLEVEL%==0 goto dryrun
        echo Finished in 0.0 seconds
        echo Result: 0 passed
        exit /b 0

        :dryrun
        type "#{content_win}"
        exit /b 1
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, "mix")

        File.write!(fake_path, """
        #!/bin/sh
        case "$*" in
          *"--dry-run"*)
        cat <<'FAKE_NOISY_WINDOW_OUTPUT'
        #{body}
        FAKE_NOISY_WINDOW_OUTPUT
            exit 1
            ;;
          *)
            echo "Finished in 0.0 seconds"
            echo "Result: 0 passed"
            exit 0
            ;;
        esac
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  # Fixture 4: every --dry-run call returns non-empty output containing no "Tests that
  # would be executed:" line at all, modeling a dry-run subprocess that crashed/reshaped
  # rather than one that legitimately resolved to zero tests.
  defp install_wasm_hang_no_header_fake_mix(fake_bin_dir) do
    body = """
    ** (Mix) could not compile dependency :fake_dep (mix.exs)
    unexpected crash before any test discovery output was produced
    """

    case :os.type() do
      {:win32, _} ->
        content_file = Path.join(fake_bin_dir, "no_header.txt")
        File.write!(content_file, body)
        content_win = String.replace(content_file, "/", "\\")

        fake_path = Path.join(fake_bin_dir, "mix.bat")

        File.write!(fake_path, """
        @echo off
        setlocal
        set ARGS=%*
        echo %ARGS% | findstr /C:"--dry-run" >nul
        if %ERRORLEVEL%==0 goto dryrun
        echo Finished in 0.0 seconds
        echo Result: 0 passed
        exit /b 0

        :dryrun
        type "#{content_win}"
        exit /b 1
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, "mix")

        File.write!(fake_path, """
        #!/bin/sh
        case "$*" in
          *"--dry-run"*)
        cat <<'FAKE_NO_HEADER_OUTPUT'
        #{body}
        FAKE_NO_HEADER_OUTPUT
            exit 1
            ;;
          *)
            echo "Finished in 0.0 seconds"
            echo "Result: 0 passed"
            exit 0
            ;;
        esac
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  # Writes `name` under fixture_root/log_subdir with `content`, creating the directory
  # if needed. Returns the absolute, "/"-normalized path to log_subdir (the shape
  # find_partition_log_dir/1's regex expects, and what a real bash/MSYS subprocess on
  # this project's Windows host actually prints -- see resolve_native_path/1's own
  # commentary in the module under test).
  defp write_partition_log(fixture_root, log_subdir, name, content) do
    dir = Path.join(fixture_root, log_subdir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), content)
    dir |> Path.expand() |> String.replace("\\", "/")
  end

  # Builds the fake bash's own stdout: the required "test_parallel: N=..." line (not
  # parsed by the module under test, but present in every real invocation, so a
  # fixture omitting it would be unrealistic) plus, when log_dir is given, the
  # "test_parallel: partition logs in <dir>" line find_partition_log_dir/1 parses.
  defp fake_runner_stdout(log_dir) do
    header = "test_parallel: N=2 (source: fake)\n"

    case log_dir do
      nil -> header
      dir -> header <> "test_parallel: partition logs in #{dir}\n"
    end
  end

  defp run_and_capture_ok(fake_bin_dir) do
    install_executable_resolver(fake_bin_dir, ["bash", "mix"])

    ExUnit.CaptureIO.capture_io(fn ->
      assert Mix.Tasks.Letflow.Check.Test.run([]) == :ok
    end)
  end

  # ISS-0524: installs a clean-passing main suite (fake `bash`) so a test can reach
  # run_wasm_hang_tests/0 -- and therefore discover_wasm_hang_tests/0 -- without also
  # needing to exercise the main-suite gate itself. Mirrors the setup already used by
  # the "passes (no raise) when the wrapper exits 0..." test above.
  defp install_passing_main_suite(fixture_root, fake_bin_dir) do
    log_dir =
      write_partition_log(fixture_root, "logs", "partition-1.log", "Result: 5/5 passed\n")

    write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 3/3 passed\n")

    install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 0)
    :ok
  end

  # REWORK ITERATION 1 (ISS-0699 design doc §3a): a fake `bash` whose behavior
  # actually depends on whether TEST_PARALLEL_KEEP_LOGS reached its own process
  # environment -- not a static canned response. When the var is present (any
  # non-empty value, mirroring the real script's `[ -z "${TEST_PARALLEL_KEEP_LOGS:-}" ]`
  # truthiness check per design doc §2.4), it behaves like a normal clean run and
  # prints the partition-log-directory line; when absent, it deliberately does NOT
  # print that line and exits nonzero instead -- reproducing exactly what the real
  # script would do if this caller never set the var (its own trap would already
  # have deleted `tmp_dir` by the time this task tried to read it, per the design
  # doc's REWORK ITERATION 1 root-cause section). This is the only way to prove the
  # env var actually crosses the Port.open/2 boundary into the subprocess's own
  # environment -- asserting on `letflow.check.test.ex`'s source text would only
  # prove the call site was edited, not that Erlang's `:env` port option, the
  # charlist/binary typing, and stream_and_capture/3's threading of the value all
  # actually work end-to-end.
  defp install_env_var_aware_fake_bash(fake_bin_dir, log_dir) do
    case :os.type() do
      {:win32, _} ->
        # Companion-file + `type` technique (matches install_fake_executable/4 and the
        # ISS-0524 wasm_hang fixtures above), NOT inline `echo` -- batch's `echo`
        # unconditionally appends CRLF, which would leave a trailing "\r" glued onto
        # the captured directory path (find_partition_log_dir/1's regex is a plain
        # multiline match with no per-line "\r" stripping, unlike
        # split_output_lines/1's wasm_hang-discovery path), silently breaking
        # File.exists?/1 and Path.wildcard/1 downstream. Verified live: the inline-echo
        # version of this fixture reproducibly made check_main_suite_logs/2 report
        # "zero partition-*.log files" even though the directory and its files exist.
        set_output_path = Path.join(fake_bin_dir, "env_aware_bash_set.txt")
        unset_output_path = Path.join(fake_bin_dir, "env_aware_bash_unset.txt")

        File.write!(
          set_output_path,
          "test_parallel: N=2 (source: fake)\ntest_parallel: partition logs in #{log_dir}\n"
        )

        File.write!(
          unset_output_path,
          "test_parallel: TEST_PARALLEL_KEEP_LOGS was not set on this invocation\n"
        )

        set_output_win = String.replace(set_output_path, "/", "\\")
        unset_output_win = String.replace(unset_output_path, "/", "\\")

        fake_path = Path.join(fake_bin_dir, "bash.bat")

        File.write!(fake_path, """
        @echo off
        if defined TEST_PARALLEL_KEEP_LOGS (
          type "#{set_output_win}"
          exit /b 0
        ) else (
          type "#{unset_output_win}"
          exit /b 1
        )
        """)

      _ ->
        fake_path = Path.join(fake_bin_dir, "bash")

        File.write!(fake_path, """
        #!/bin/sh
        if [ -n "${TEST_PARALLEL_KEEP_LOGS:-}" ]; then
          echo "test_parallel: N=2 (source: fake)"
          echo "test_parallel: partition logs in #{log_dir}"
          exit 0
        else
          echo "test_parallel: TEST_PARALLEL_KEEP_LOGS was not set on this invocation"
          exit 1
        fi
        """)

        File.chmod!(fake_path, 0o755)
    end

    :ok
  end

  describe "mix letflow.check.test's re-pointed ISS-0069 gate (design doc section 1)" do
    test "raises and reports the offending line, with partition attribution, when the target substring is present in a per-partition log even though the wrapper exited 0",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      offending_line =
        "test/letflow/some_helper_test.exs:42: warning: default values for the optional arguments in unique_idempotency_key/1 are never used, because all calls in this file are made with all arguments"

      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", """
        Compiling 3 files (.ex)
        #{offending_line}
        Result: 5/5 passed
        """)

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 3/3 passed\n")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 0)
      install_passing_fake_mix(fake_bin_dir)

      exception =
        assert_raise Mix.Error, ~r/#{Regex.escape(@target_substring)}/, fn ->
          install_executable_resolver(fake_bin_dir, ["bash", "mix"])

          ExUnit.CaptureIO.capture_io(fn ->
            Mix.Tasks.Letflow.Check.Test.run([])
          end)
        end

      # Partition attribution (design doc §1.2 step 5) -- the raised message must name
      # WHICH partition log the warning came from, not just that a warning exists
      # somewhere. "[partition 1]" and never "[partition 2]", since only
      # partition-1.log contains the offending line.
      assert exception.message =~ "[partition 1]"
      refute exception.message =~ "[partition 2]"
      assert exception.message =~ offending_line
    end

    test "passes (no raise) when the wrapper exits 0 and the target substring is absent from every partition log, even with unrelated warnings present",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", """
        Compiling 3 files (.ex)
        warning: ExUnit.Case.register_test/4 is deprecated
        warning: variable "tenant" is unused
        Result: 5/5 passed
        """)

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 3/3 passed\n")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 0)
      install_wasm_hang_aware_fake_mix(fake_bin_dir)

      io = run_and_capture_ok(fake_bin_dir)

      assert io =~ "OK -- no test failures, no ISS-0069 warnings"
      assert io =~ "2 partitions"
      refute io =~ @target_substring
    end

    test "GH #2615: a passing run echoes the budget measurement line from its partition log to the job output",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      measurement =
        "GH2534 budget measurement (us): new_script median=112 p95=290; full run median=640 p95=1210"

      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", """
        Compiling 3 files (.ex)
        Result: 5/5 passed
        """)

      write_partition_log(fixture_root, "logs", "partition-2.log", """
      #{measurement}
      Result: 3/3 passed
      """)

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 0)
      install_wasm_hang_aware_fake_mix(fake_bin_dir)

      io = run_and_capture_ok(fake_bin_dir)

      assert io =~ "partition 2 #{measurement}"
      refute io =~ "partition 1 GH2534"
    end

    test "raises when the wrapper itself exits nonzero (real test failure), regardless of the substring, and prints the failing partition's full log content before raising",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", """
        1) test something (SomeTest)
           Assertion failed
        Failed: 1 test
        """)

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 2/2 passed\n")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 1)
      install_passing_fake_mix(fake_bin_dir)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      {exception, io} =
        ExUnit.CaptureIO.with_io(fn ->
          assert_raise Mix.Error, ~r/exited 1/, fn ->
            Mix.Tasks.Letflow.Check.Test.run([])
          end
        end)

      assert exception.message =~ "exited 1"
      assert exception.message =~ "Partition logs:"
      # Failure-mode parity (design doc §4.2): the failing partition's full log content
      # must be printed (not just its count/existence) so an agent reading the terminal
      # sees the real assertion detail without needing the discarded tmp dir.
      assert io =~ "partition 1"
      assert io =~ "Assertion failed"
      assert io =~ "FAILED"
    end
  end

  describe "mix letflow.check.test's two new hard-failure paths (design doc section 1.2, must never pass silently)" do
    test "hard-fails when the wrapper exits 0 but never prints a parseable partition-log-directory line",
         %{fake_bin_dir: fake_bin_dir} do
      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(nil), 0)
      install_passing_fake_mix(fake_bin_dir)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      assert exception.message =~ "never printed"
      assert exception.message =~ "partition logs in"
    end

    test "hard-fails when the log-dir line is present but the directory contains zero partition-*.log files",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      empty_dir = Path.join(fixture_root, "empty_logs")
      File.mkdir_p!(empty_dir)
      normalized = empty_dir |> Path.expand() |> String.replace("\\", "/")

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(normalized), 0)
      install_passing_fake_mix(fake_bin_dir)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      assert exception.message =~ "zero partition-*.log files"
    end
  end

  describe "mix letflow.check.test's ISS-0524 wasm_hang discovery bounded retry + diagnosability" do
    test "(b) retry actually retries once and succeeds -- returns :ok and logs that the first attempt was empty and the retry succeeded",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_passing_main_suite(fixture_root, fake_bin_dir)
      install_wasm_hang_retry_succeeds_fake_mix(fake_bin_dir)

      io = run_and_capture_ok(fake_bin_dir)

      assert io =~ "first" and io =~ "retry"
      assert io =~ "isolated wasm_hang tests passed"
    end

    test "(a)/(b2) retry retries exactly once, then hard-fails with the retry attempt's real captured output (header present, empty block)",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_passing_main_suite(fixture_root, fake_bin_dir)
      install_wasm_hang_retry_still_fails_fake_mix(fake_bin_dir)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      # Real captured output of the RETRY attempt is embedded, not the first attempt's.
      assert exception.message =~ "attempt=2"
      refute exception.message =~ "attempt=1"

      # Existing framing prose preserved.
      assert exception.message =~ "cannot tell"

      # The literal header string itself must be present (the defect this revision
      # fixes: a flat tail could embed post-header content while cutting the header).
      assert exception.message =~ "Tests that would be executed:"

      # --dry-run was invoked exactly twice: once for the first attempt, once for the
      # retry -- not zero, not looping.
      count_path = Path.join(fake_bin_dir, "still_fails_count")
      assert File.exists?(count_path)
      invocation_count = count_path |> File.read!() |> String.split("\n", trim: true) |> length()
      assert invocation_count == 2
    end

    test "(a2) header-anchored window covers real noisy output within the bound, including the header and terminator, with no bound-exceeded caveat",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_passing_main_suite(fixture_root, fake_bin_dir)
      install_wasm_hang_retry_noisy_window_fake_mix(fake_bin_dir, 250, true)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      assert exception.message =~ "Tests that would be executed:"
      assert exception.message =~ "All tests have been excluded."
      refute exception.message =~ "bound was reached"
    end

    test "(a3) bound reached before a terminator is stated explicitly, not silently truncated",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_passing_main_suite(fixture_root, fake_bin_dir)
      install_wasm_hang_retry_noisy_window_fake_mix(fake_bin_dir, 400, false)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      assert exception.message =~ "Tests that would be executed:"
      assert exception.message =~ "bound was reached"
      refute exception.message =~ "All tests have been excluded."
    end

    test "(a4) header entirely absent is reported as a distinct, more severe signal, with a last-40-lines fallback tail",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_passing_main_suite(fixture_root, fake_bin_dir)
      install_wasm_hang_no_header_fake_mix(fake_bin_dir)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      assert exception.message =~ "no \"Tests that would be executed:\" header"
      assert exception.message =~ "more severe"
      assert exception.message =~ "unexpected crash before any test discovery output"
    end

    test "(c) no-retry-needed path is unaffected -- existing passing-path fixture/test still passes",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_passing_main_suite(fixture_root, fake_bin_dir)
      install_wasm_hang_aware_fake_mix(fake_bin_dir)

      io = run_and_capture_ok(fake_bin_dir)

      assert io =~ "isolated wasm_hang tests passed"
      refute io =~ "NOTE"
    end
  end

  describe "mix letflow.check.test's ORDERING RULE (design doc section 1.2 step 1, CODE-DESIGN-VALIDATOR MINOR finding)" do
    test "when the wrapper exits nonzero AND the log-dir line is absent, reports the wrapper's nonzero exit FIRST, not \"log line missing\"",
         %{fake_bin_dir: fake_bin_dir} do
      # Mirrors the real, common case: `mix compile` fails inside test_parallel.sh's
      # own pre-compile step, so the script exits nonzero before its unconditional
      # "partition logs in <dir>" line is ever reached/printed.
      install_fake_executable(
        fake_bin_dir,
        "bash",
        "test_parallel: ERROR pre-compile failed with exit 1 -- no partition launched\n",
        1
      )

      install_passing_fake_mix(fake_bin_dir)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Letflow.Check.Test.run([]) end)
        end

      # Positive assertion: the message an agent sees leads with the wrapper's own
      # nonzero exit / compile-failure framing...
      assert exception.message =~ "exited 1 before ever printing"

      # ...and does NOT lead a reader toward hunting a nonexistent log-parsing bug.
      # This is the precise behavior the design doc's ordering rule exists to
      # guarantee: reporting "log line missing" here would send an agent looking in
      # the wrong place instead of at the real compile error in the streamed output.
      refute exception.message =~
               "never printed a \"test_parallel: partition logs in <dir>\" line. This " <>
                 "task cannot locate"
    end
  end

  # A "trap" fake is installed onto a directory that then gets PREPENDED onto real
  # PATH (not a replacement of PATH -- see the test below for why a full replacement
  # is unsafe here). If anything in the module under test ever consults real PATH for
  # `name`, it resolves to this trap instead of a real executable -- so the trap can
  # never actually recurse into a real `bash`/`mix` invocation, but its distinctive
  # exit code/output still makes "real PATH was consulted" observable and assertable.
  defp install_path_trap(trap_dir, name) do
    install_fake_executable(
      trap_dir,
      name,
      "TRAP-CONSULTED-REAL-PATH: #{name} should never be resolved via real PATH",
      97
    )
  end

  describe "ISS-0697 regression: resolver seam immune to real PATH mutation" do
    # This is the actual root-cause proof for ISS-0697: the old technique
    # (activate_fake_bin_dir/2, pre-fix) worked by prepending fake_bin_dir onto the
    # real, OS-process-global PATH, which is exactly the global mutable state a
    # concurrently-scheduled async:true test elsewhere in the suite could race --
    # winning the race meant letflow.check.test.ex's own System.find_executable("bash")
    # resolved the REAL bash and genuinely exec'd scripts/test_parallel.sh recursively.
    #
    # This test simulates that race deterministically: AFTER the override is
    # installed, real PATH is mutated (a trap directory is PREPENDED onto it) exactly
    # the way a racing async test's own PATH-prepending technique would, then run/1 is
    # driven to completion and asserted to succeed via the installed override.
    #
    # Deliberately PREPENDS the trap dir onto the real PATH rather than replacing PATH
    # outright, for two independent safety reasons:
    #   1. Windows' own tooling (findstr, used internally by the wasm_hang-aware fake
    #      `mix.bat` fixture below to dispatch on argv shape) needs the real
    #      System32 PATH entries to keep working -- wiping PATH would break the FIXTURE
    #      itself, not the code under test, and produce a false failure signal.
    #   2. If real PATH were instead consulted (the pre-fix hazard reoccurring) and
    #      this test replaced PATH outright, whatever real `bash`/`mix` originally sat
    #      on PATH would no longer be found either, silently masking the exact
    #      recursion hazard this test exists to catch. Prepending a trap that shadows
    #      the real executables (trap resolves first) instead makes "real PATH was
    #      consulted" observably fail LOUD (the trap's distinctive exit
    #      code/output) while never actually reaching a real `bash`/`scripts/test_parallel.sh`
    #      invocation even if this regresses -- see the trap's own exit code 97 above.
    test "run/1 succeeds via the override even when real PATH is mutated (prepended) afterward, never touching the PATH-prepended trap",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_passing_main_suite(fixture_root, fake_bin_dir)
      install_wasm_hang_aware_fake_mix(fake_bin_dir)

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      trap_dir =
        Path.join(
          System.tmp_dir!(),
          "letflow_check_test_pathtrap_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(trap_dir)
      on_exit(fn -> File.rm_rf!(trap_dir) end)

      install_path_trap(trap_dir, "bash")
      install_path_trap(trap_dir, "mix")

      original_path = System.get_env("PATH")

      on_exit(fn ->
        case original_path do
          nil -> System.delete_env("PATH")
          path -> System.put_env("PATH", path)
        end
      end)

      separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

      # Simulate what a concurrently-scheduled async:true test could do to real PATH
      # in the exact TOCTOU window ISS-0697 diagnosed -- between the override being
      # installed and run/1 actually resolving/spawning its subprocesses.
      System.put_env("PATH", trap_dir <> separator <> (original_path || ""))

      io =
        ExUnit.CaptureIO.capture_io(fn ->
          assert Mix.Tasks.Letflow.Check.Test.run([]) == :ok
        end)

      assert io =~ "isolated wasm_hang tests passed"
      refute io =~ "TRAP-CONSULTED-REAL-PATH"
    end

    # Proves the hazard's own mechanism (PATH mutation) is structurally gone from the
    # installer, not merely avoided by convention -- a regression that reintroduced a
    # `System.put_env("PATH", ...)` call inside install_executable_resolver/2 would
    # fail this deterministically, without needing a real concurrency repro.
    test "install_executable_resolver/2 never mutates real PATH (hazard mechanism itself is gone)",
         %{fake_bin_dir: fake_bin_dir} do
      install_fake_executable(
        fake_bin_dir,
        "bash",
        "Finished in 0.0 seconds\nResult: 0 passed\n",
        0
      )

      install_fake_executable(
        fake_bin_dir,
        "mix",
        "Finished in 0.0 seconds\nResult: 0 passed\n",
        0
      )

      path_before = System.get_env("PATH")

      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      assert System.get_env("PATH") == path_before
    end

    # Guards the "no fallback" invariant (design doc §3, point 2): an unfaked name
    # must resolve to nil, never silently fall through to a real System.find_executable
    # search. Reads the installed resolver back out of Application env and calls it
    # directly -- deterministic, no subprocess spawn -- rather than driving this
    # through run/1, which would (correctly, but riskily for a proof step) invoke a
    # REAL executable found on this host's real PATH if this invariant ever regressed.
    test "an unmapped executable name resolves to nil, not a silent fallback to real PATH search",
         %{fake_bin_dir: fake_bin_dir} do
      install_fake_executable(
        fake_bin_dir,
        "bash",
        "Finished in 0.0 seconds\nResult: 0 passed\n",
        0
      )

      install_executable_resolver(fake_bin_dir, ["bash"])

      resolver = Application.get_env(:letflow, :check_test_executable_resolver)
      assert is_function(resolver, 1)

      unmapped_name = "totally_unmapped_executable_name_#{System.unique_integer([:positive])}"
      assert resolver.(unmapped_name) == nil
    end
  end

  describe "ISS-0699 REWORK ITERATION 1 regression: caller-side env-var passthrough and log-dir cleanup (design doc §3a)" do
    # Proves (a): TEST_PARALLEL_KEEP_LOGS=1 set by run_main_suite/0's own
    # stream_and_capture/3 call actually reaches the invoked `bash` subprocess's own
    # environment, not merely present somewhere in this module's source. Uses
    # install_env_var_aware_fake_bash/2, whose behavior branches on whether the var is
    # visible inside ITS OWN process -- so this can only pass if Port.open/2 truly
    # received an :env entry carrying it.
    #
    # This is exactly the bug Step Final's CI run caught (design doc REWORK ITERATION 1
    # section): against the pre-rework-1 shape (stream_and_capture/2, no env
    # passthrough at all), this fake bash never observes TEST_PARALLEL_KEEP_LOGS, never
    # prints the partition-log-directory line, and exits 1 -- so run/1 raises instead of
    # returning :ok.
    test "TEST_PARALLEL_KEEP_LOGS=1 set on run_main_suite/0's own bash invocation reaches the subprocess's own environment",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", "Result: 5/5 passed\n")

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 3/3 passed\n")

      install_env_var_aware_fake_bash(fake_bin_dir, log_dir)
      install_wasm_hang_aware_fake_mix(fake_bin_dir)

      io = run_and_capture_ok(fake_bin_dir)

      assert io =~ "OK -- no test failures, no ISS-0069 warnings"
      refute io =~ "TEST_PARALLEL_KEEP_LOGS was not set"
    end

    # Proves (b): the partition-log directory is actually removed (not merely read)
    # once check_main_suite_logs/2 finishes with a clean run -- restoring, from this
    # caller's side, the bounded-accumulation property ISS-0699 originally wanted for
    # scripts/test_parallel.sh itself (design doc §3a, "now owned by this file instead
    # of the script"). Against the pre-rework-1 shape (no try/after, no
    # File.rm_rf!/1 call anywhere in run_main_suite/0), this directory survives the run
    # untouched, so the `refute File.exists?/1` below fails there and passes on the
    # current branch.
    test "the partition-log directory is removed after a clean run's own successful read",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", "Result: 5/5 passed\n")

      write_partition_log(fixture_root, "logs", "partition-2.log", "Result: 3/3 passed\n")

      assert File.exists?(log_dir)

      install_fake_executable(fake_bin_dir, "bash", fake_runner_stdout(log_dir), 0)
      install_wasm_hang_aware_fake_mix(fake_bin_dir)

      _io = run_and_capture_ok(fake_bin_dir)

      refute File.exists?(log_dir)
    end
  end

  # Q-1037 / GH #2364: `--shard K/M` and `--tails-only`, plus the `letflow.check` alias split.
  #
  # Seam: the same fake `bash`/`mix` + Application-env resolver technique as the rest of
  # this file (nothing real is spawned). The fakes below additionally append one line per
  # invocation to a single shared record file (`calls.txt`): `bash shard=<value of
  # TEST_PARALLEL_SHARD in the fake's own environment>` for the main-suite runner and
  # `mix <argv>` for each tail command, so a test can assert both WHAT ran and, by absence,
  # what did NOT run (and in what order).
  describe "mix letflow.check.test --shard / --tails-only (Q-1037 / GH #2364)" do
    defp calls_path(fake_bin_dir), do: Path.join(fake_bin_dir, "calls.txt")

    defp recorded_calls(fake_bin_dir) do
      path = calls_path(fake_bin_dir)

      if File.exists?(path),
        do: path |> File.read!() |> String.replace("\r", "") |> String.split("\n", trim: true),
        else: []
    end

    # Fake `bash`: records the value of TEST_PARALLEL_SHARD it was launched with (empty when
    # unset), prints the runner stdout pointing at `log_dir`, exits `exit_code`.
    defp install_recording_bash(fake_bin_dir, log_dir, exit_code \\ 0) do
      rec = calls_path(fake_bin_dir)

      case :os.type() do
        {:win32, _} ->
          out_path = Path.join(fake_bin_dir, "recording_bash_out.txt")
          File.write!(out_path, fake_runner_stdout(log_dir))
          rec_win = String.replace(rec, "/", "\\")
          out_win = String.replace(out_path, "/", "\\")

          File.write!(Path.join(fake_bin_dir, "bash.bat"), """
          @echo off
          if defined TEST_PARALLEL_SHARD (>>"#{rec_win}" echo bash shard=%TEST_PARALLEL_SHARD%) else (>>"#{rec_win}" echo bash shard=)
          type "#{out_win}"
          exit /b #{exit_code}
          """)

        _ ->
          fake_path = Path.join(fake_bin_dir, "bash")

          File.write!(fake_path, """
          #!/bin/sh
          echo "bash shard=${TEST_PARALLEL_SHARD:-}" >> "#{rec}"
          echo "test_parallel: N=2 (source: fake)"
          echo "test_parallel: partition logs in #{log_dir}"
          exit #{exit_code}
          """)

          File.chmod!(fake_path, 0o755)
      end

      :ok
    end

    # Fake `mix`: same dispatch as install_wasm_hang_aware_fake_mix/1 (one discovered
    # wasm_hang test, which passes; everything else passes), but every invocation is first
    # recorded as `mix <argv>`.
    defp install_recording_mix(fake_bin_dir) do
      rec = calls_path(fake_bin_dir)

      case :os.type() do
        {:win32, _} ->
          rec_win = String.replace(rec, "/", "\\")

          File.write!(Path.join(fake_bin_dir, "mix.bat"), """
          @echo off
          setlocal
          set ARGS=%*
          >>"#{rec_win}" echo mix %ARGS%
          echo %ARGS% | findstr /C:"--dry-run" >nul
          if %ERRORLEVEL%==0 (
            echo Tests that would be executed:
            echo test/fake_wasm_hang_test.exs:1
            echo All tests have been excluded.
            echo Finished in 0.0 seconds
            echo Result: 0 tests, 1 excluded
            exit /b 1
          )
          echo Finished in 0.0 seconds
          echo Result: 1 passed
          exit /b 0
          """)

        _ ->
          fake_path = Path.join(fake_bin_dir, "mix")

          File.write!(fake_path, """
          #!/bin/sh
          echo "mix $*" >> "#{rec}"
          case "$*" in
            *"--dry-run"*)
              echo "Tests that would be executed:"
              echo "test/fake_wasm_hang_test.exs:1"
              echo "All tests have been excluded."
              echo "Finished in 0.0 seconds"
              echo "Result: 0 tests, 1 excluded"
              exit 1
              ;;
            *)
              echo "Finished in 0.0 seconds"
              echo "Result: 1 passed"
              exit 0
              ;;
          esac
          """)

          File.chmod!(fake_path, 0o755)
      end

      :ok
    end

    defp clean_log_dir(fixture_root, name) do
      dir = write_partition_log(fixture_root, name, "partition-1.log", "Result: 5/5 passed\n")
      write_partition_log(fixture_root, name, "partition-2.log", "Result: 3/3 passed\n")
      dir
    end

    defp run_task_capturing(args) do
      ExUnit.CaptureIO.with_io(fn -> Mix.Tasks.Letflow.Check.Test.run(args) end)
    end

    test "--shard 2/3 exports TEST_PARALLEL_SHARD=2/3 to the runner, checks its logs, and runs no tails",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_recording_bash(fake_bin_dir, clean_log_dir(fixture_root, "logs"))
      install_recording_mix(fake_bin_dir)
      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      {_result, io} = run_task_capturing(["--shard", "2/3"])

      # the runner saw the slice, exactly once, and no `mix` tail command was launched
      assert recorded_calls(fake_bin_dir) == ["bash shard=2/3"]
      assert io =~ "OK -- no test failures, no ISS-0069 warnings"
      refute io =~ "wasm_hang"
      refute io =~ "lua_wallclock_race"
    end

    test "--shard still applies the ISS-0069 warnings gate to the slice's partition logs",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-5.log", """
        test/x_test.exs:1: warning: #{@target_substring} in helper/2 are never used
        Result: 5/5 passed
        """)

      install_recording_bash(fake_bin_dir, log_dir)
      install_recording_mix(fake_bin_dir)
      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, ~r/#{Regex.escape(@target_substring)}/, fn ->
          run_task_capturing(["--shard", "1/3"])
        end

      assert exception.message =~ "[partition 5]"
      assert recorded_calls(fake_bin_dir) == ["bash shard=1/3"]
    end

    test "--shard propagates a failing runner exit as a Mix.Error and still runs no tails",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      log_dir =
        write_partition_log(fixture_root, "logs", "partition-1.log", "Failed: 1 test\n")

      install_recording_bash(fake_bin_dir, log_dir, 1)
      install_recording_mix(fake_bin_dir)
      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      assert_raise Mix.Error, ~r/exited 1/, fn -> run_task_capturing(["--shard", "3/3"]) end
      assert recorded_calls(fake_bin_dir) == ["bash shard=3/3"]
    end

    test "--tails-only runs only the wasm_hang and lua tails and never launches the runner script",
         %{fake_bin_dir: fake_bin_dir} do
      install_recording_bash(fake_bin_dir, "/nonexistent")
      install_recording_mix(fake_bin_dir)
      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      {_result, io} = run_task_capturing(["--tails-only"])

      calls = recorded_calls(fake_bin_dir)
      refute Enum.any?(calls, &String.starts_with?(&1, "bash")), inspect(calls)
      assert length(calls) == 3, inspect(calls)
      assert Enum.at(calls, 0) =~ "--dry-run"
      assert Enum.at(calls, 1) =~ "fake_wasm_hang_test"
      assert Enum.at(calls, 2) =~ "--only lua_wallclock_race"
      assert io =~ "1/1 isolated wasm_hang tests passed"
      assert io =~ "isolated :lua_wallclock_race run also passed clean"
      refute io =~ "no ISS-0069 warnings"
    end

    test "no arguments still runs the whole suite (shard unset) and then the tails, in that order",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_recording_bash(fake_bin_dir, clean_log_dir(fixture_root, "logs"))
      install_recording_mix(fake_bin_dir)
      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      {_result, io} = run_task_capturing([])

      calls = recorded_calls(fake_bin_dir)
      assert length(calls) == 4, inspect(calls)
      # TEST_PARALLEL_SHARD is not exported by a plain run (the top-level setup scrubs
      # any ambient TEST_PARALLEL_* via Letflow.Test.TestParallelEnv.scrub_ambient!/0)
      assert Enum.at(calls, 0) == "bash shard="
      assert Enum.at(calls, 1) =~ "--dry-run"
      assert Enum.at(calls, 2) =~ "fake_wasm_hang_test"
      assert Enum.at(calls, 3) =~ "--only lua_wallclock_race"
      assert io =~ "OK -- no test failures, no ISS-0069 warnings"
    end

    test "--shard together with --tails-only is rejected as mutually exclusive, starting nothing",
         %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
      install_recording_bash(fake_bin_dir, clean_log_dir(fixture_root, "logs"))
      install_recording_mix(fake_bin_dir)
      install_executable_resolver(fake_bin_dir, ["bash", "mix"])

      exception =
        assert_raise Mix.Error, fn -> run_task_capturing(["--shard", "1/3", "--tails-only"]) end

      assert exception.message =~ "mutually exclusive"
      assert recorded_calls(fake_bin_dir) == []
    end

    for {label, args, needle} <- [
          {"K greater than M", ["--shard", "4/3"], "greater than M"},
          {"non-numeric shard", ["--shard", "abc"], "K/M"},
          {"zero M", ["--shard", "1/0"], "K/M"},
          {"unknown flag", ["--bogus"], "unrecognised arguments"},
          {"stray positional argument", ["extra"], "unrecognised arguments"},
          {"--shard without a value", ["--shard"], "unrecognised arguments"}
        ] do
      test "#{label} raises Mix.Error and starts no subprocess",
           %{fixture_root: fixture_root, fake_bin_dir: fake_bin_dir} do
        install_recording_bash(fake_bin_dir, clean_log_dir(fixture_root, "logs"))
        install_recording_mix(fake_bin_dir)
        install_executable_resolver(fake_bin_dir, ["bash", "mix"])

        exception =
          assert_raise Mix.Error, fn -> run_task_capturing(unquote(args)) end

        assert exception.message =~ unquote(needle)
        assert recorded_calls(fake_bin_dir) == []
      end
    end
  end

  describe "letflow.check alias split (Q-1037 / GH #2364)" do
    test "letflow.check is the static steps followed by letflow.check.test, and static ends at the boundary check" do
      aliases = Mix.Project.config()[:aliases]
      static = Keyword.fetch!(aliases, :"letflow.check.static")
      full = Keyword.fetch!(aliases, :"letflow.check")

      assert is_list(static)
      assert full == static ++ ["letflow.check.test"]
      assert List.last(static) == "letflow.check_boundaries"
      refute "letflow.check.test" in static
    end
  end
end
