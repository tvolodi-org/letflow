defmodule Letflow.Scripts.TestParallelRaceRegressionTest do
  @moduledoc """
  Q-1053 / GH #2399 / ISS-1062: deterministic regression tests for three races in
  `scripts/test_parallel.sh` that made the `test_parallel` test family flaky (and, for the
  create-burst one, could hit real CI shard runs).

  Each race needs an instantly-finishing stub partition to show up on a loaded host, so the
  tests do not wait for luck: a `BASH_ENV` shim file (non-interactive bash sources it before
  running; functions shadow builtins) widens the exact window. No production change is
  needed for the seam. The shims only define functions; stubs call none of them.

    * T1 -- RC-B, `poll_template_ready_dir` TOCTOU: the ready-file was tested BEFORE the
      liveness probe, so a partition that wrote its ready-file and exited between the two
      builtins was reported as "exited during its own template build". The shim makes the
      `kill -0` probe return only once the partition is gone, and the stub only writes its
      ready-file after the probe has started (gate file, no wall-clock window).
    * T2a / T2b -- RC-C, the create-burst `wait -n -p finished_pid` returned without setting
      the variable (observed on CI: `finished_pid: unbound variable`, `set -u` abort). The
      shim makes the FIRST `wait -n` return 127 with the variable untouched. T2a caps the
      create burst at 1 so the in-loop wait site is reached, T2b at >= N so the drain site
      is; each also has an exit-3 variant (the failing partition lies inside the shard
      slice) proving the fallback still reports a real create failure.
    * T3 -- RC-A, the EXIT trap is inherited by the per-partition watchdog subshells: a
      watchdog killed in the fork window ran `cleanup_tmp_dir` with `$?=0` and
      `rm -rf`'d the run's tmp dir under the running parent. The shim re-arms the inherited
      trap inside the watchdog subshell and exits 0 (what bash does in that window).

  `TEST_PARALLEL_KEEP_LOGS` is deliberately NOT set: it would skip the `rm -rf` that T3
  exists to expose. Assertion failures carry `Letflow.Test.TestParallelCapture` context.
  Needs a real `bash`; on Windows set `UAT_PF_BASH` (or `TEST_PARALLEL_BASH`).
  `async: false`: spawns process trees.
  """
  use ExUnit.Case, async: false

  alias Letflow.Test.TestParallelCapture

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @run_limit_ms 120_000
  # A value no other `sleep` in the script uses; the T3 shim keys on it.
  @watchdog_s "241"

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # `mix test`: waits (bounded 5 s, 20 ms ticks) for $SHIM_GO when set and absent, writes
  # the ready-file like test/test_helper.exs, prints `Result:`. `ecto.create`: exits 3 for
  # $STUB_FAIL_CREATE (a partition index) at once; every other partition first waits
  # (bounded 5 s, 20 ms ticks) for $STUB_HOLD_FOR to exist, else exits 0. With the hold
  # pointed at the wait shim's flag file, the failing partition is the ONLY finished
  # create job when the shimmed `wait -n` falls back to polling, so a fallback that loses
  # the exit status of the pid it reaps is observable (MU-C2).
  defp write_stubs(tmp) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)
    mix = Path.join(bin, "mix")

    File.write!(mix, ~S"""
    #!/usr/bin/env bash
    part="${MIX_TEST_PARTITION:--}"
    case "$1" in
      test)
        if [ -n "${SHIM_GO:-}" ]; then
          n=0
          while [ ! -e "$SHIM_GO" ] && [ "$n" -lt 250 ]; do
            sleep 0.02
            n=$((n + 1))
          done
        fi
        if [ -n "${TEST_PARALLEL_TEMPLATE_READY_DIR:-}" ]; then
          : > "$TEST_PARALLEL_TEMPLATE_READY_DIR/partition-${MIX_TEST_PARTITION}.ready"
        fi
        echo "Result: 5 passed"
        exit 0
        ;;
      ecto.create)
        if [ -n "${STUB_FAIL_CREATE:-}" ] && [ "$part" = "$STUB_FAIL_CREATE" ]; then
          echo "stub: ecto.create failing for partition $part"
          exit 3
        fi
        if [ -n "${STUB_HOLD_FOR:-}" ]; then
          n=0
          while [ ! -e "$STUB_HOLD_FOR" ] && [ "$n" -lt 250 ]; do
            sleep 0.02
            n=$((n + 1))
          done
        fi
        exit 0
        ;;
      *) exit 0 ;;
    esac
    """)

    File.write!(Path.join(bin, "psql"), "#!/usr/bin/env bash\nexit 1\n")
    File.chmod!(mix, 0o755)
    File.chmod!(Path.join(bin, "psql"), 0o755)
    bin
  end

  defp write_shim(tmp, body) do
    path = Path.join(tmp, "shim.sh")
    File.write!(path, body)
    path
  end

  # T1: the liveness probe only returns once the probed partition is gone; touching the
  # gate file first lets the stub proceed (write ready-file, exit) AFTER the probe began.
  @shim_t1 ~S"""
  kill() {
    if [ "${1:-}" = "-0" ]; then
      : > "$SHIM_GO"
      _shim_n=0
      while builtin kill -0 "${2:-0}" 2>/dev/null && [ "$_shim_n" -lt 250 ]; do
        command sleep 0.02
        _shim_n=$((_shim_n + 1))
      done
    fi
    builtin kill "$@"
  }
  """

  # T2: the first `wait -n` returns 127 and leaves the `-p` variable untouched (the
  # observed CI symptom), recording that it fired.
  @shim_t2 ~S"""
  wait() {
    if [ "${1:-}" = "-n" ] && [ ! -e "$SHIM_FLAG" ]; then
      : > "$SHIM_FLAG"
      return 127
    fi
    builtin wait "$@"
  }
  """

  # T3: inside a subshell (BASHPID != $$) the watchdog's own `sleep $SHIM_WATCHDOG_S`
  # re-arms the inherited EXIT trap and leaves with status 0.
  @shim_t3 ~S"""
  sleep() {
    if [ "${BASHPID:-$$}" != "$$" ] && [ "${1:-}" = "$SHIM_WATCHDOG_S" ]; then
      eval "$(trap -p EXIT)"
      exit 0
    fi
    command sleep "$@"
  }
  """

  # Returns {status, out, tmp_dir}. `shim` is the shim file path or nil.
  defp run_script(tmp, shim, extra_env) do
    bin = write_stubs(tmp)
    work = Path.join(tmp, "work")
    File.mkdir_p!(Path.join(work, "_build/test"))
    File.write!(Path.join(work, "_build/test/marker"), "x")
    tmpdir = Path.join(tmp, "tp_tmp")
    File.mkdir_p!(tmpdir)

    # The output file travels in the environment, NOT as a positional argument: MSYS bash
    # parses a command line itself and treats a single quote as quoting, so a quote in the
    # test's tmp path used to shift the arguments and make the launcher redirect INTO the
    # script (`bash "$@" > "$out"` with out == the script path), truncating it.
    #
    # BASH_ENV is exported only after the launcher shell started, as a POSIX path
    # (cygpath on Windows git-bash, a no-op elsewhere), so the launcher itself is not
    # shimmed and the shim reaches the script and its stubs.
    launcher =
      ~S{d=$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1"); PATH="$d:$PATH"; export PATH; shift; if [ -n "$SHIM_FILE" ]; then BASH_ENV=$(cygpath -u "$SHIM_FILE" 2>/dev/null || printf '%s' "$SHIM_FILE"); export BASH_ENV; fi; bash "$@" > "$OUT_FILE" 2>&1}

    out_file = Path.join(tmp, "script.out")

    env =
      [
        {"TEST_PARALLEL_N", "4"},
        {"TEST_POOL_SIZE", "4"},
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "240"},
        {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
        {"TMPDIR", tmpdir},
        {"LETFLOW_DB_PORT", "1"},
        {"SHIM_FLAG", Path.join(tmp, "shim.flag")},
        {"SHIM_WATCHDOG_S", @watchdog_s},
        {"SHIM_FILE", shim},
        {"OUT_FILE", out_file}
      ]
      |> Map.new()
      |> Map.merge(Map.new(extra_env))

    port =
      Port.open({:spawn_executable, bash()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, work},
        {:env, Letflow.Test.TestParallelEnv.port_env(env)},
        {:args, ["-c", launcher, "launcher", bin, script()]}
      ])

    status = collect(port, System.monotonic_time(:millisecond))
    out = out_file |> File.read!() |> String.replace("\r", "")
    {status, out}
  end

  defp collect(port, started) do
    remaining = @run_limit_ms - (System.monotonic_time(:millisecond) - started)

    receive do
      {^port, {:data, _chunk}} -> collect(port, started)
      {^port, {:exit_status, status}} -> status
    after
      max(remaining, 0) ->
        Port.close(port)
        flunk("test_parallel.sh did not finish within #{@run_limit_ms} ms")
    end
  end

  test "T1 ready-file written and process exited between the two probes is READY not an error",
       %{tmp_dir: tmp} do
    shim = write_shim(tmp, @shim_t1)

    {status, out} =
      run_script(tmp, shim, [
        {"TEST_PARALLEL_SHARD", "2/3"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "1"},
        {"SHIM_GO", Path.join(tmp, "shim.go")}
      ])

    TestParallelCapture.with_context(tmp, out, fn ->
      # no vacuous pass: the probe (hence the gate) really ran
      assert File.exists?(Path.join(tmp, "shim.go"))
      refute out =~ "exited during its own template build"
      assert status == 0
      assert out =~ "-- 4/4 partitions reported"
    end)
  end

  for {label, cap} <- [{"T2a in-loop wait site", "1"}, {"T2b drain wait site", "4"}] do
    test "#{label} survives a wait that leaves finished_pid unset with create cap #{cap}",
         %{tmp_dir: tmp} do
      shim = write_shim(tmp, @shim_t2)

      {status, out} =
        run_script(tmp, shim, [
          {"TEST_PARALLEL_SHARD", "1/3"},
          {"TEST_PARALLEL_MAX_CONCURRENT_CREATES", unquote(cap)}
        ])

      TestParallelCapture.with_context(tmp, out, fn ->
        assert File.exists?(Path.join(tmp, "shim.flag")), "the wait -n shim never fired"
        refute out =~ "unbound variable"
        assert status == 0
        assert out =~ "-- 4/4 partitions reported"
      end)
    end

    test "#{label} still reports a real create failure exit 3 with create cap #{cap}",
         %{tmp_dir: tmp} do
      shim = write_shim(tmp, @shim_t2)

      {status, out} =
        run_script(tmp, shim, [
          {"TEST_PARALLEL_SHARD", "1/3"},
          {"TEST_PARALLEL_MAX_CONCURRENT_CREATES", unquote(cap)},
          {"STUB_FAIL_CREATE", "1"},
          {"STUB_HOLD_FOR", Path.join(tmp, "shim.flag")}
        ])

      TestParallelCapture.with_context(tmp, out, fn ->
        assert File.exists?(Path.join(tmp, "shim.flag")), "the wait -n shim never fired"
        refute out =~ "unbound variable"
        assert out =~ "partition 1 ecto.create/ecto.migrate failed with exit 3"
        assert status == 1
      end)
    end
  end

  test "T3 a watchdog subshell inheriting the EXIT trap does not delete the run tmp dir",
       %{tmp_dir: tmp} do
    shim = write_shim(tmp, @shim_t3)

    {status, out} =
      run_script(tmp, shim, [
        {"TEST_PARALLEL_SHARD", "1/3"},
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", @watchdog_s}
      ])

    TestParallelCapture.with_context(tmp, out, fn ->
      refute out =~ "No such file"
      refute out =~ "preserving"
      assert status == 0
      assert out =~ "-- 4/4 partitions reported"

      # the script's own contract on a clean exit with KEEP_LOGS unset: its tmp dir is
      # removed by the MAIN shell's trap (a guard that never fires would leak it)
      assert File.ls!(Path.join(tmp, "tp_tmp")) == []
    end)
  end

  test "failure context carries the tmp tree listing and the partition log content",
       %{tmp_dir: tmp} do
    # Probe for the capture helper itself: a deliberately failing assertion inside
    # with_context/3 must come back with the listing and the log text appended.
    nested = Path.join([tmp, "tp_tmp", "letflow_test_parallel.PROBE"])
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "partition-1.log"), "probe-line-A
probe-line-B
")

    error =
      assert_raise ExUnit.AssertionError, fn ->
        TestParallelCapture.with_context(tmp, "probe-script-output", fn ->
          assert 1 == 2, "original-message"
        end)
      end

    assert error.message =~ "original-message"
    assert error.message =~ "probe-script-output"
    assert error.message =~ "letflow_test_parallel.PROBE/partition-1.log"
    assert error.message =~ "probe-line-B"

    # and a vanished nested dir is named as such instead of raising
    File.rm_rf!(nested)
    assert TestParallelCapture.failure_context(tmp, "x") =~ "tmp dir missing"
  end
end
