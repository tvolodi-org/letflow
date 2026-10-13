defmodule Letflow.Scripts.TestParallelWatchdogOrphanTest do
  @moduledoc """
  CI-gate stall regression: `scripts/test_parallel.sh` starts one background watchdog
  subshell per partition (`sleep "$TEST_PARALLEL_PARTITION_TIMEOUT_S"`, default 1800 s,
  then TERM/KILL the partition's process group). When a partition finished, the script
  only did `kill <watchdog subshell pid>`, which does NOT kill the subshell's `sleep`
  child. That orphaned `sleep` inherited the script's stdout/stderr pipe, and the reader
  of that pipe -- `mix letflow.check.test` reads the script through an Erlang `Port` with
  `:exit_status`, which is only delivered once the pipe reaches EOF -- blocked until the
  sleep expired (measured on CI run 37641894774: partitions done 15:27:29, task returned
  15:35:36 = 8m07s, i.e. watchdog start + 1800 s).

  The fix kills the watchdog's whole process group (`kill -- -$pid`, falling back to
  `kill $pid`) at the post-`wait` site (Step 3) and in the EXIT trap.

  ## What is driven

  The REAL `scripts/test_parallel.sh` under bash, with a stub `mix` (and `psql`) first on
  `PATH` so no compile, database or real test run happens. The invocation is made through
  `Port.open/2` with `:exit_status` + `:stderr_to_stdout` -- exactly how
  `Mix.Tasks.Letflow.Check.Test` reads it -- and the primary assertion is the elapsed time
  until `{:exit_status, _}` arrives: seconds, versus the watchdog timeout (`@timeout_s`
  = 240 s here; an orphaned sleep would hold the pipe that long).

  The script runs inside `bash -c "set -o pipefail; bash script | cat"`. On Linux the Port
  alone only reports the exit status at pipe EOF, but on Windows erts reports it from the
  process handle without waiting for EOF -- the first version of this test passed against
  the BUGGY script there (the orphans only showed up as an 11 minute `mix test | grep`
  stall). A shell pipeline waits for EOF on every platform, so the bound is discriminating
  everywhere; `pipefail` keeps the script's own exit status.

  Cases:

    1. success: partitions exit 0 -> script exits 0 promptly, no orphan `sleep`
       (Step 3 site)
    2. failing partition: script exits non-zero (the log-dump path) and also promptly
    3. EXIT-trap site: the script aborts (`exit 1`) while a partition's watchdog is
       still running (admission-control abort) -> non-zero and prompt; only the trap's
       watchdog kill can release the pipe here
    4. Step 3 site in isolation: a finished partition's watchdog sleep is gone while a later
       partition is still running (the trap would only reap it at exit)
    5. hung partition: the watchdog must still TERM the partition group after
       `TEST_PARALLEL_PARTITION_TIMEOUT_S` -> script exits non-zero within seconds

  Needs a real `bash`; on Windows set `UAT_PF_BASH` (or `TEST_PARALLEL_BASH`) to git-bash.
  `async: false`: the cases spawn process trees and are timing-sensitive.
  """
  use ExUnit.Case, async: false

  alias Letflow.Test.TestParallelCapture

  @moduletag :tmp_dir

  # The watchdog's sleep length. Large on purpose: an orphan would hold the pipe this
  # long, which dwarfs the prompt-return bound below.
  @timeout_s 240
  # Prompt-return bound (ms). Generous for a loaded 4-vCPU runner and a slow Windows
  # fork-heavy bash (observed ~2-6 s), but ~6x below @timeout_s, so a regression of the
  # orphaned-sleep kind cannot hide inside it.
  @prompt_ms 40_000

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # Writes the stub `mix` and `psql`, returns the stub bin dir.
  #
  # Stub `mix test` behaviour is per-partition, driven by env:
  #   STUB_MODE=pass            every partition prints a Result line and exits 0
  #   STUB_MODE=fail            partition STUB_FAIL_PARTITION (default 1) reports a failure, exit 2
  #   STUB_MODE=die_early       partition 1 exits 1 at once with no Result and no ready-file
  #   STUB_MODE=hang            partition 1 sleeps for 600 s (until killed)
  #   STUB_MODE=staggered       partition 1 passes after 2 s; partition 2 first waits (bounded, 100 ms
  #                             poll) until it sees BOTH watchdog sleeps alive, then polls until only one
  #                             remains (or the deadline), and writes the LAST count of live
  #                             `sleep $TEST_PARALLEL_PARTITION_TIMEOUT_S` processes (read from /proc,
  #                             which exists on Linux and in git-bash) to $STUB_MARKER, then passes.
  #                             No fixed wall-clock sample point (ISS-1080): a real orphan stays at 2.
  defp write_stubs(tmp) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)

    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/usr/bin/env bash
    case "$1" in
      compile|ecto.create|ecto.migrate) exit 0 ;;
      test) ;;
      *) exit 0 ;;
    esac
    part="${MIX_TEST_PARTITION:-0}"
    case "${STUB_MODE:-pass}" in
      pass)
        echo "Result: 1 passed"
        exit 0 ;;
      fail)
        if [ "$part" = "${STUB_FAIL_PARTITION:-1}" ]; then
          echo "Result: 0/1 passed"
          echo "Failed: 1 tests"
          exit 2
        fi
        echo "Result: 1 passed"
        exit 0 ;;
      staggered)
        if [ "$part" = "1" ]; then
          sleep 2
        fi
        if [ "$part" = "2" ]; then
          count_sleeps() {
            local n=0 d c
            for d in /proc/[0-9]*; do
              c=$(tr "\\0" " " <"$d/cmdline" 2>/dev/null)
              case "$c" in "sleep $TEST_PARALLEL_PARTITION_TIMEOUT_S "*) n=$((n + 1)) ;; esac
            done
            echo "$n"
          }
          deadline=$((SECONDS + 25))
          n=0
          # phase 1: both watchdogs alive (own + partition 1's). If never seen (starved
          # host) fall through and record the last value.
          while [ "$SECONDS" -lt "$deadline" ]; do
            n=$(count_sleeps)
            [ "$n" -ge 2 ] && break
            sleep 0.1
          done
          # phase 2: partition 1 finishes (2 s) and Step 3 must reap its watchdog.
          while [ "$SECONDS" -lt "$deadline" ]; do
            n=$(count_sleeps)
            [ "$n" -le 1 ] && break
            sleep 0.1
          done
          echo "$n" > "$STUB_MARKER"
        fi
        echo "Result: 1 passed"
        exit 0 ;;
      die_early)
        if [ "$part" = "1" ]; then
          exit 1
        fi
        sleep 600 ;;
      hang)
        if [ "$part" = "1" ]; then
          sleep 600
        fi
        echo "Result: 1 passed"
        exit 0 ;;
    esac
    """)

    File.write!(Path.join(bin, "psql"), "#!/usr/bin/env bash\nexit 1\n")
    File.chmod!(mix, 0o755)
    File.chmod!(Path.join(bin, "psql"), 0o755)
    bin
  end

  # Runs the real script through a Port, the way Mix.Tasks.Letflow.Check.Test does.
  # Returns {exit_status, output, elapsed_ms}. If the pipe is not released within
  # `limit_ms` the result is {:timeout, output_so_far, elapsed_ms}.
  defp run_script(tmp, extra_env, limit_ms) do
    bin = write_stubs(tmp)
    work = Path.join(tmp, "work")
    File.mkdir_p!(Path.join(work, "_build/test"))
    File.write!(Path.join(work, "_build/test/marker"), "x")
    tmpdir = Path.join(tmp, "tp_tmp")
    File.mkdir_p!(tmpdir)

    # Prepend the stub dir to PATH *inside* bash, in POSIX form (cygpath on Windows
    # git-bash, a no-op elsewhere), so a drive-letter path never lands in a `:`-list.
    launcher =
      ~S{d=$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1"); PATH="$d:$PATH"; export PATH; shift; set -o pipefail; bash "$@" 2>&1 | cat}

    env =
      [
        {"TEST_PARALLEL_N", "2"},
        {"TEST_POOL_SIZE", "4"},
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", Integer.to_string(@timeout_s)},
        {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
        {"TMPDIR", tmpdir},
        {"LETFLOW_DB_PORT", "1"}
      ] ++ extra_env

    port =
      Port.open({:spawn_executable, bash()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, work},
        {:env, Letflow.Test.TestParallelEnv.port_env(env)},
        {:args, ["-c", launcher, "launcher", bin, script()]}
      ])

    started = System.monotonic_time(:millisecond)
    result = collect(port, [], started, limit_ms)
    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, status, out} ->
        {status, out, elapsed}

      {:timeout, out} ->
        close_quietly(port)
        {:timeout, out, elapsed}
    end
  end

  defp collect(port, acc, started, limit_ms) do
    remaining = limit_ms - (System.monotonic_time(:millisecond) - started)

    receive do
      {^port, {:data, chunk}} -> collect(port, [acc, chunk], started, limit_ms)
      {^port, {:exit_status, status}} -> {:ok, status, IO.iodata_to_binary(acc)}
    after
      max(remaining, 0) -> {:timeout, IO.iodata_to_binary(acc)}
    end
  end

  defp close_quietly(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Secondary, portable-where-possible check: no surviving `sleep @timeout_s`. `ps -eo
  # args` is procps (Linux CI); git-bash's ps does not support it, so the check is
  # skipped there -- the EOF-timing assertion above is the primary one.
  #
  # ISS-1080: a group-killed `sleep` can still be LISTED for a few ms after the script
  # returned (it is being reaped), so the listing is polled every 100 ms for up to 5 s and
  # the assertion is made on the last listing at the deadline: a real orphan (it sleeps
  # for @timeout_s+) is still there, a reaped one is gone.
  defp assert_no_orphan_sleep(timeout_s) do
    case orphan_survivors(timeout_s, 50) do
      :unsupported ->
        :ok

      survivors ->
        assert survivors == [], "orphaned watchdog sleep survived: #{inspect(survivors)}"
    end
  end

  defp orphan_survivors(timeout_s, attempts_left) do
    case System.cmd("ps", ["-eo", "args"], stderr_to_stdout: true) do
      {out, 0} ->
        survivors =
          out |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/(^|\s|\/)sleep #{timeout_s}\s*$/))

        if survivors == [] or attempts_left <= 0 do
          survivors
        else
          Process.sleep(100)
          orphan_survivors(timeout_s, attempts_left - 1)
        end

      _ ->
        :unsupported
    end
  rescue
    ErlangError -> :unsupported
  end

  defp unique_timeout, do: @timeout_s + :rand.uniform(300)

  test "success: pipe is released promptly and no watchdog sleep is orphaned", %{tmp_dir: tmp} do
    t = unique_timeout()

    {status, out, elapsed} =
      run_script(
        tmp,
        [{"STUB_MODE", "pass"}, {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "#{t}"}],
        @prompt_ms
      )

    IO.puts("[watchdog-orphan] success case returned in #{elapsed} ms (watchdog timeout #{t} s)")

    TestParallelCapture.with_context(tmp, out, fn ->
      refute status == :timeout,
             "script did not release its stdout pipe within #{@prompt_ms} ms (an orphaned " <>
               "watchdog sleep holds it for up to #{t} s); output:\n#{out}"

      assert status == 0, out
      assert out =~ "combined: 2 tests"
      assert elapsed < @prompt_ms
      assert_no_orphan_sleep(t)
    end)
  end

  test "failing partition: exits non-zero and still returns promptly", %{tmp_dir: tmp} do
    t = unique_timeout()

    {status, out, elapsed} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "fail"},
          {"STUB_FAIL_PARTITION", "1"},
          {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "#{t}"}
        ],
        @prompt_ms
      )

    IO.puts("[watchdog-orphan] failing case returned in #{elapsed} ms")

    TestParallelCapture.with_context(tmp, out, fn ->
      refute status == :timeout,
             "script did not release its stdout pipe within #{@prompt_ms} ms; output:\n#{out}"

      assert status == 1,
             "expected non-zero exit for a failing partition, got #{inspect(status)}:\n#{out}"

      assert out =~ "partition 1: "
      assert out =~ "1 failures"
      assert_no_orphan_sleep(t)
    end)
  end

  test "EXIT-trap path: abort while a watchdog is running releases the pipe promptly",
       %{tmp_dir: tmp} do
    t = unique_timeout()

    # Admission cap 1 with N=2: partition 1 is launched (its watchdog starts), then the
    # admission loop notices partition 1 died without a ready-file and `exit 1`s -- the
    # script leaves through the EXIT trap with partition 1's watchdog still sleeping.
    {status, out, elapsed} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "die_early"},
          {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "1"},
          {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "#{t}"}
        ],
        @prompt_ms
      )

    IO.puts("[watchdog-orphan] trap case returned in #{elapsed} ms")

    TestParallelCapture.with_context(tmp, out, fn ->
      refute status == :timeout,
             "script did not release its stdout pipe within #{@prompt_ms} ms after an " <>
               "EXIT-trap exit; output:\n#{out}"

      assert status == 1,
             "expected exit 1 from the admission abort, got #{inspect(status)}:\n#{out}"

      assert out =~ "exited during its own template build"
      assert_no_orphan_sleep(t)
    end)
  end

  test "Step 3 reaps a finished partition watchdog while later partitions still run",
       %{tmp_dir: tmp} do
    t = unique_timeout()
    marker = Path.join(tmp, "sleep_count")

    # Partition 1 finishes after 2 s (long enough that its watchdog `sleep` really is
    # running, so this does not race the fork). Partition 2 first waits until it sees BOTH
    # watchdog sleeps alive, then polls until only one remains and records the LAST count;
    # only partition 2's own watchdog may remain. The EXIT trap would also reap an orphan,
    # but only at script exit -- this is what pins the Step 3 kill itself. A real orphan
    # keeps the count at 2 until the stub's deadline, so it still fails the assertion.
    {status, out, elapsed} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "staggered"},
          {"STUB_MARKER", marker},
          {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "#{t}"}
        ],
        @prompt_ms
      )

    IO.puts("[watchdog-orphan] staggered case returned in #{elapsed} ms")

    TestParallelCapture.with_context(tmp, out, fn ->
      refute status == :timeout,
             "script did not release its stdout pipe in time; output:\n#{out}"

      assert status == 0, out
      assert File.exists?(marker), "stub partition 2 did not record the sleep count:\n#{out}"

      assert marker |> File.read!() |> String.trim() == "1",
             "expected exactly 1 live watchdog sleep (partition 2's own) while partition 2 " <>
               "ran, got #{String.trim(File.read!(marker))} -- partition 1's watchdog sleep was " <>
               "orphaned by the Step 3 kill"
    end)
  end

  test "hung partition: the watchdog still TERMs it after the timeout", %{tmp_dir: tmp} do
    {status, out, elapsed} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "hang"},
          {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "2"},
          {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"}
        ],
        @prompt_ms
      )

    IO.puts("[watchdog-orphan] hung case returned in #{elapsed} ms (watchdog timeout 2 s)")

    TestParallelCapture.with_context(tmp, out, fn ->
      refute status == :timeout,
             "hung partition was not killed by the watchdog within #{@prompt_ms} ms; output:\n#{out}"

      assert status == 1,
             "expected non-zero exit for a killed partition, got #{inspect(status)}:\n#{out}"

      assert out =~ "exceeded TEST_PARALLEL_PARTITION_TIMEOUT_S=2s"
      # the 600 s stub partition must have been cut short by the watchdog, not run out
      assert elapsed < 60_000
    end)
  end
end
