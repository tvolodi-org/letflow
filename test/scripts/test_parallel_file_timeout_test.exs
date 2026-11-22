defmodule Letflow.Scripts.TestParallelFileTimeoutTest do
  @moduledoc """
  T-2652: the CI test runner must fail LOUDLY and NAME the offending file when a test
  file stalls, instead of letting the shard run into the CI job limit.

  Background: push CI run 45010058431 (sha 74867e559, 2026-11-22) failed on Backend
  shard 3/8, which burned its whole 2700 s job budget and was killed by the job
  deadline with no assertion failure and no hint of what was running. The shard's own
  runner had no bound below the job limit, so a stalled step cost 45 minutes of CI and
  told nobody anything.

  Two bounds are covered here, both driven through the REAL `scripts/test_parallel.sh`
  with a stub `mix` on PATH:

    1. the per-test-file stall limit (`TEST_PARALLEL_FILE_TIMEOUT_S`): a file that
       neither starts nor finishes a test for that many seconds is killed, and the
       job log names the file;
    2. the create+migrate phase limit (`TEST_PARALLEL_CREATE_TIMEOUT_S`): a partition
       database that never finishes being created is killed, and the job log says so
       (this is the phase the 45010058431 shard actually hung in).

  The stub publishes the same marker file the real suite publishes
  (`test/support/file_timeout_marker.ex`), so the script is exercised through the
  contract it really has with the suite.
  """

  use ExUnit.Case, async: false
  @moduletag :unit
  @moduletag :tmp_dir
  # The script is driven for real: a few seconds of process work, plus slack.
  @moduletag timeout: 180_000

  alias Letflow.Test.TestParallelEnv

  @hanging_file "test/letflow/fixtures/hanging_file_test.exs"

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # Stub `mix`, env-driven (STUB_MODE):
  #   pass      `mix test` prints a Result line and exits 0
  #   stall     `mix test` publishes the marker file (as the real suite's marker
  #             formatter does) naming the running file, then sleeps forever
  #   create    `mix ecto.create`/`ecto.migrate` sleep forever (the create phase
  #             never finishes)
  defp write_stubs(tmp) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)
    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/usr/bin/env bash
    case "${STUB_MODE:-pass}" in
      create)
        case "$1" in
          ecto.create|ecto.migrate) sleep 600 ;;
        esac
        exit 0 ;;
    esac
    case "$1" in
      test)
        if [ "${STUB_MODE:-pass}" = "stall" ]; then
          marker="${TEST_PARALLEL_FILE_MARKER_DIR:-}/current-${MIX_TEST_PARTITION:-0}.txt"
          if [ -n "${TEST_PARALLEL_FILE_MARKER_DIR:-}" ]; then
            now=$(date +%s)
            printf 'file=%s\\nmodule=Letflow.Fixtures.HangingFileTest\\nstarted=%s\\nprogress=%s\\ntests=Letflow.Fixtures.HangingFileTest.test sleeps forever\\n' \\
              "${STUB_STALL_FILE}" "$((now - 300))" "$((now - 300))" > "$marker"
          fi
          sleep 600
        fi
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
        # long enough that the PARTITION watchdog never fires: this test is about
        # the per-FILE limit, not the per-partition one
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "600"},
        {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
        {"TEST_PARALLEL_MAX_CONCURRENT_CREATES", "4"},
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

  test "a stalled test file fails the run loudly, naming the file", %{tmp_dir: tmp} do
    {status, out} =
      run_script(
        tmp,
        [
          {"STUB_MODE", "stall"},
          {"STUB_STALL_FILE", @hanging_file},
          {"TEST_PARALLEL_FILE_TIMEOUT_S", "2"}
        ],
        120_000
      )

    assert status != :timeout, "the script did not return:\n#{out}"
    assert status != 0, "a stalled test file must fail the run:\n#{out}"

    assert out =~ "TEST_PARALLEL_FILE_TIMEOUT_S",
           "the failure must name the limit that fired:\n#{out}"

    assert out =~ @hanging_file,
           "the failure must name the stalled test file:\n#{out}"

    assert out =~ "has not completed a test",
           "the failure must say the file stalled:\n#{out}"
  end

  test "a partition database that never finishes being created fails the run loudly", %{
    tmp_dir: tmp
  } do
    {status, out} =
      run_script(
        tmp,
        [{"STUB_MODE", "create"}, {"TEST_PARALLEL_CREATE_TIMEOUT_S", "3"}],
        120_000
      )

    assert status != :timeout, "the script did not return:\n#{out}"
    assert status != 0, "a hung create/migrate phase must fail the run:\n#{out}"

    assert out =~ "TEST_PARALLEL_CREATE_TIMEOUT_S",
           "the failure must name the limit that fired:\n#{out}"

    assert out =~ "create+migrate phase",
           "the failure must name the phase that hung:\n#{out}"
  end

  test "a healthy run is untouched by the file limit", %{tmp_dir: tmp} do
    {status, out} =
      run_script(
        tmp,
        [{"STUB_MODE", "pass"}, {"TEST_PARALLEL_FILE_TIMEOUT_S", "2"}],
        120_000
      )

    assert status == 0, out
    refute out =~ "TEST_PARALLEL_FILE_TIMEOUT_S", out
  end
end
