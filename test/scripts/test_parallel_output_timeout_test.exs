defmodule Letflow.Scripts.TestParallelOutputTimeoutTest do
  @moduledoc """
  T-2692: a CI test partition that stops saying anything must be killed after a
  bounded number of minutes and reported BY NAME -- not left to the CI job's own
  timeout, which ends the job without naming anything.

  Background: push CI run 45184714218 (2026-11-23) lost the isolated-tails job
  to the 30-minute job timeout with nothing in the log about which test was
  running, and extended run 45221672326 (attempt 1, shard 6/8) hung partition
  23 on a Postgrex "owner timed out ... owned the connection for longer than
  120000ms" with the same silence. `scripts/test_parallel.sh` now watches each
  partition's own output (`TEST_PARALLEL_OUTPUT_TIMEOUT_S`, default 480 s) and
  kills a silent partition, reporting the last test that started, the ExUnit
  seed of that run and the runner's load.

  This file drives the REAL `scripts/test_parallel.sh` with a stub `mix` on
  PATH, exactly the technique `test_parallel_file_timeout_test.exs` uses for
  the per-file limit:

    * the `hang` mode runs the seeded sleeping test file
      (`test/fixtures/seeded_hang/seeded_hang.exs` -- a real ExUnit file whose
      test never returns), which publishes the same marker the suite's own
      marker formatter publishes and prints the ExUnit header with a fixed
      seed, then hangs;
    * the `pass` mode prints a Result line and exits 0;
    * the `chatty` mode keeps printing a line per second for longer than the
      limit, and the `dots` mode prints the PRODUCTION shape -- one "." per
      finished test and NO newline -- so the log grows in bytes and never in
      lines. The `dots` case is what pins the signal to the byte count.

  The per-file limit (`TEST_PARALLEL_FILE_TIMEOUT_S`) is switched OFF in the
  hang case on purpose: the bound under test here is the OUTPUT one, and a test
  that passed because some other watchdog fired would prove nothing about it.
  """

  use ExUnit.Case, async: false
  @moduletag :unit
  @moduletag :tmp_dir
  # The script is driven for real: a few seconds of process work, plus slack.
  @moduletag timeout: 180_000

  alias Letflow.Test.TestParallelEnv

  @seeded_hang_file "test/fixtures/seeded_hang/seeded_hang.exs"
  @seeded_test_name "Letflow.Fixtures.SeededHangTest.test hangs forever"

  # The runner runs the partitions in its own working directory, so the
  # seeded file is addressed by its ABSOLUTE path -- the marker the seeded
  # file publishes then names the same absolute path.
  defp seeded_hang_path,
    do: Path.expand(Path.join(["..", "..", @seeded_hang_file]), __DIR__)

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script,
    do:
      System.get_env("TEST_PARALLEL_SCRIPT") ||
        Path.expand("../../scripts/test_parallel.sh", __DIR__)

  defp elixir_bin, do: System.find_executable("elixir")

  # Stub `mix`, env-driven (STUB_MODE):
  #   pass  `mix test` prints a Result line and exits 0
  #   hang  `mix test` runs the seeded sleeping test file (which hangs for
  #         real, and publishes the suite's marker format on its way in)
  defp write_stubs(tmp) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)
    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/usr/bin/env bash
    case "${STUB_MODE:-pass}" in
      hang)
        case "$1" in
          test) exec "${SEEDED_HANG_ELIXIR:-elixir}" "${SEEDED_HANG_FILE}" ;;
        esac
        exit 0 ;;
      chatty)
        # A partition that KEEPS SAYING SOMETHING: one line per second for
        # longer than the output limit. The watchdog must not touch it -- the
        # bound is on silence, not on the run's duration.
        case "$1" in
          test)
            i=0
            while [ "$i" -lt 6 ]; do
              echo "Running ExUnit with seed: 424242, max_cases: 8"
              sleep 1
              i=$((i + 1))
            done
            echo "Result: 1 passed"
            exit 0 ;;
        esac
        exit 0 ;;
      dots)
        # The PRODUCTION shape of ExUnit's CLI formatter: one "." per finished
        # test and NO newline (see ex_unit/lib/ex_unit/cli_formatter.ex).
        # The log grows in BYTES and never in LINES, so a watchdog that counted
        # lines would kill this healthy partition -- this case is what pins the
        # signal to the byte count.
        case "$1" in
          test)
            echo "Running ExUnit with seed: 424242, max_cases: 8"
            i=0
            while [ "$i" -lt 8 ]; do
              printf '.'
              sleep 1
              i=$((i + 1))
            done
            printf '\nResult: 1 passed\n'
            exit 0 ;;
        esac
        exit 0 ;;
    esac
    case "$1" in
      test)
        echo "Running ExUnit with seed: 424242, max_cases: 8"
        echo "Result: 1 passed"
        exit 0 ;;
      *) exit 0 ;;
    esac
    """)

    File.write!(Path.join(bin, "psql"), "#!/usr/bin/env bash\nexit 1\n")
    File.chmod!(mix, 0o755)
    File.chmod!(Path.join(bin, "psql"), 0o755)
    bin
  end

  # Runs the real script and returns {exit_status | :timeout, output}.
  defp run_script(tmp, extra_env, limit_ms) do
    bin = write_stubs(tmp)
    work = Path.join(tmp, "work")
    File.mkdir_p!(Path.join(work, "_build/test"))
    File.write!(Path.join(work, "_build/test/marker"), "x")
    tmpdir = Path.join(tmp, "tp_tmp")
    File.mkdir_p!(tmpdir)

    launcher =
      ~S{d=$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1"); PATH="$d:$PATH"; export PATH; shift; set -o pipefail; bash "$@" 2>&1 | cat}

    env =
      [
        {"TEST_PARALLEL_N", "1"},
        {"TEST_POOL_SIZE", "6"},
        # long enough that the PARTITION watchdog never fires: this test is
        # about the OUTPUT limit, not the per-partition one
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "600"},
        {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
        {"TEST_PARALLEL_MAX_CONCURRENT_CREATES", "4"},
        {"SEEDED_HANG_ELIXIR", elixir_bin() || "elixir"},
        {"SEEDED_HANG_FILE", seeded_hang_path()},
        {"TMPDIR", tmpdir},
        {"LETFLOW_DB_PORT", "1"}
      ] ++ extra_env

    port =
      Port.open({:spawn_executable, bash()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, work},
        {:env, TestParallelEnv.port_env(env)},
        {:args, ["-c", launcher, "launcher", bin, script()]}
      ])

    started = System.monotonic_time(:millisecond)
    result = collect(port, [], started, limit_ms)

    case result do
      {:ok, status, out} ->
        {status, out}

      {:timeout, out} ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        {:timeout, out}
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

  test "a partition that stops saying anything is killed and reported by test name", %{
    tmp_dir: tmp
  } do
    assert elixir_bin(), "no elixir on PATH -- the seeded hanging test file cannot be run"

    {status, out} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "hang"},
          {"TEST_PARALLEL_OUTPUT_TIMEOUT_S", "3"},
          # the per-FILE limit is off on purpose: the bound under test is the
          # output one, and a green run caused by another watchdog would
          # prove nothing about it
          {"TEST_PARALLEL_FILE_TIMEOUT_S", "0"}
        ],
        120_000
      )

    assert status != :timeout, "the script did not return:\n#{out}"
    assert status != 0, "a silent partition must fail the run:\n#{out}"

    assert out =~ "TEST_PARALLEL_OUTPUT_TIMEOUT_S",
           "the failure must name the limit that fired:\n#{out}"

    assert out =~ @seeded_hang_file,
           "the failure must name the hanging test file:\n#{out}"

    assert out =~ @seeded_test_name,
           "the failure must name the test that started:\n#{out}"

    assert out =~ "seed: 424242",
           "the failure must name the ExUnit seed of the hung run:\n#{out}"

    assert out =~ "runner load:",
           "the failure must name the runner's load:\n#{out}"
  end

  test "a healthy partition is untouched by the output limit", %{tmp_dir: tmp} do
    {status, out} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "pass"},
          {"TEST_PARALLEL_OUTPUT_TIMEOUT_S", "3"},
          {"TEST_PARALLEL_FILE_TIMEOUT_S", "0"}
        ],
        120_000
      )

    assert status == 0, out
    refute out =~ "TEST_PARALLEL_OUTPUT_TIMEOUT_S", out
  end

  test "a partition that keeps saying something is never killed, however long it runs", %{
    tmp_dir: tmp
  } do
    # The bound is on SILENCE: a partition that reports every second for
    # longer than the limit is healthy, and killing it would be the false
    # positive this watchdog must not have.
    {status, out} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "chatty"},
          {"TEST_PARALLEL_OUTPUT_TIMEOUT_S", "3"},
          {"TEST_PARALLEL_FILE_TIMEOUT_S", "0"}
        ],
        120_000
      )

    assert status == 0, out
    refute out =~ "TEST_PARALLEL_OUTPUT_TIMEOUT_S", out
    refute out =~ "killing the partition", out
  end

  test "a partition that grows in bytes but never in lines is not killed", %{tmp_dir: tmp} do
    # The signal the watchdog rests on is the partition log's BYTE count. A
    # healthy partition grows that way in CI: ExUnit's CLI formatter writes one
    # "." per finished test and NO newline, so the log grows without ever
    # adding a line. A watchdog that counted LINES would therefore kill every
    # healthy partition in every CI run -- and the other cases in this file
    # would stay green, because their stubs print newline-terminated lines.
    # This case is the one that fails if the signal is ever regressed to a
    # line count: the log here has exactly one line and grows by one byte per
    # second.
    {status, out} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "dots"},
          {"TEST_PARALLEL_OUTPUT_TIMEOUT_S", "3"},
          {"TEST_PARALLEL_FILE_TIMEOUT_S", "0"}
        ],
        120_000
      )

    assert status == 0, out
    refute out =~ "TEST_PARALLEL_OUTPUT_TIMEOUT_S", out
    refute out =~ "killing the partition", out
  end
end
