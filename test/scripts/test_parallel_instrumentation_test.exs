defmodule Letflow.Scripts.TestParallelInstrumentationTest do
  @moduledoc """
  Q-1037 / GH #2364: `scripts/test_parallel.sh` observability and diagnostic hooks.

    * `TEST_PARALLEL_EXTRA_ARGS` -- whitespace-split words appended to every partition's
      `mix test` argv AFTER the script's own `"$@"`, never glob-expanded; unset leaves the
      argv exactly as before.
    * always-printed instrumentation: one `test_parallel: runner nproc=` line, one
      `test_parallel: partition N elapsed=<s>s start=<utc> end=<utc>` line per partition
      (after the pre-existing `partition N: ...` summary line, which must stay byte-exact),
      one `test_parallel: phase elapsed=<s>s` line.
    * `TEST_PARALLEL_PRINT_SLOWEST=1` -- each partition log's ExUnit "slowest" blocks
      (headers and content, real ExUnit shape) echoed once each with the prefix
      `test_parallel: partition N slowest: `, also for a failing partition; absent when the
      variable is unset or `0`.

  Drives the REAL script under bash with a stub `mix` (records its argv per partition,
  prints canned output) and stub `psql` first on `PATH`; same harness style as
  `test_parallel_watchdog_orphan_test.exs`. Needs a real `bash`; on Windows set
  `UAT_PF_BASH` (or `TEST_PARALLEL_BASH`). `async: false`: spawns process trees and
  measures elapsed seconds.
  """
  use ExUnit.Case, async: false
  @moduletag :unit

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @run_limit_ms 120_000
  @sentinel "SENTINEL_ARG"

  # argv the stub sees with no extra args: N=2, TEST_POOL_SIZE=4 (< 100, so the
  # high_pool_demand exclude is present), then the script's "$@" (the sentinel).
  @base_argv [
    "test",
    "--partitions",
    "2",
    "--no-color",
    "--exclude",
    "high_pool_demand",
    @sentinel
  ]

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # Stub `mix test` (env-driven):
  #   always:                    writes argv, one word per line, to $STUB_ARGV_DIR/argv-<partition>
  #   STUB_SLOWEST=1             prints a tests block and a modules block naming the partition
  #   STUB_FAIL_PARTITION=<n>    that partition prints `Result: 0/1 passed`, `Failed: 1 tests`, exit 2
  #   STUB_SLEEP_PARTITION=<n>   that partition sleeps 2 s first
  defp write_stubs(tmp) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)
    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/usr/bin/env bash
    case "$1" in
      test) ;;
      *) exit 0 ;;
    esac
    part="${MIX_TEST_PARTITION:-0}"
    printf '%s\\n' "$@" > "$STUB_ARGV_DIR/argv-$part"
    if [ "$part" = "${STUB_SLEEP_PARTITION:-none}" ]; then
      sleep 2
    fi
    if [ "${STUB_SLOWEST:-0}" = "1" ]; then
      echo "Top 3 slowest (2.4s), 51.8% of total time:"
      echo ""
      echo "  * test foo_p$part (Mod$part) (834.6ms) [test/x_test.exs:128]"
      echo "  * test bar_p$part (Mod$part) (700.1ms) [test/x_test.exs:140]"
      echo ""
      echo ""
      echo "Top 3 slowest (3.9s), 83.3% of total time:"
      echo ""
      echo "Letflow.XTestP$part (3936.0ms)"
      echo " [test/x_test$part.exs]"
      echo ""
      echo ""
    fi
    if [ "$part" = "${STUB_FAIL_PARTITION:-none}" ]; then
      echo "Result: 0/1 passed"
      echo "Failed: 1 tests"
      exit 2
    fi
    echo "Result: 5 passed"
    exit 0
    """)

    File.write!(Path.join(bin, "psql"), "#!/usr/bin/env bash\nexit 1\n")
    File.chmod!(mix, 0o755)
    File.chmod!(Path.join(bin, "psql"), 0o755)
    bin
  end

  # NB: test names become the tmp_dir path, which is passed to bash as an argument on
  # Windows; an apostrophe in a test name broke that quoting (script never started), so
  # keep names free of quotes.
  # Returns {exit_status, output_lines, argv_dir}.
  defp run_script(tmp, extra_env) do
    bin = write_stubs(tmp)
    work = Path.join(tmp, "work")
    File.mkdir_p!(Path.join(work, "_build/test"))
    File.write!(Path.join(work, "_build/test/marker"), "x")
    tmpdir = Path.join(tmp, "tp_tmp")
    File.mkdir_p!(tmpdir)
    argv_dir = Path.join(tmp, "argv")
    File.mkdir_p!(argv_dir)

    launcher =
      ~S{d=$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1"); PATH="$d:$PATH"; export PATH; shift; out="$1"; shift; bash "$@" > "$out" 2>&1}

    # Output goes to a file, not a pipe: a straggler holding a pipe open must not be able
    # to stall the read (the watchdog-orphan test covers the pipe-EOF behaviour itself).
    out_file = Path.join(tmp, "script.out")

    # `false` unsets a variable in Port's :env, so an ambient knob cannot leak in.
    env =
      [
        {"TEST_PARALLEL_N", "2"},
        {"TEST_POOL_SIZE", "4"},
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "240"},
        {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
        {"TEST_PARALLEL_EXTRA_ARGS", nil},
        {"TEST_PARALLEL_PRINT_SLOWEST", nil},
        {"TMPDIR", tmpdir},
        {"LETFLOW_DB_PORT", "1"},
        {"STUB_ARGV_DIR", argv_dir}
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
        {:args, ["-c", launcher, "launcher", bin, out_file, script(), @sentinel]}
      ])

    status = collect(port, System.monotonic_time(:millisecond))
    lines = out_file |> File.read!() |> String.replace("\r", "") |> String.split("\n")
    {status, lines, argv_dir}
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

  defp argv(argv_dir, part),
    do: argv_dir |> Path.join("argv-#{part}") |> File.read!() |> String.split("\n", trim: true)

  defp slowest_lines(lines, part) do
    prefix = "test_parallel: partition #{part} slowest: "

    for l <- lines, String.starts_with?(l, prefix), do: String.replace_prefix(l, prefix, "")
  end

  test "no extra args and PRINT_SLOWEST=0: argv is exactly the pre-change shape, no slowest lines",
       %{tmp_dir: tmp} do
    {status, lines, argv_dir} =
      run_script(tmp, [{"STUB_SLOWEST", "1"}, {"TEST_PARALLEL_PRINT_SLOWEST", "0"}])

    out = Enum.join(lines, "\n")
    assert status == 0, out

    for part <- [1, 2], do: assert(argv(argv_dir, part) == @base_argv)

    refute Enum.any?(lines, &String.contains?(&1, " slowest: ")), out
  end

  test "TEST_PARALLEL_EXTRA_ARGS lands after the other args, word-split, unglobbed; instrumentation lines are well-formed",
       %{tmp_dir: tmp} do
    {status, lines, argv_dir} =
      run_script(tmp, [
        {"TEST_PARALLEL_EXTRA_ARGS", "--slowest 7 --slowest-modules 3 *"},
        {"STUB_SLEEP_PARTITION", "2"}
      ])

    out = Enum.join(lines, "\n")
    assert status == 0, out

    # (a) extra words come last, after "$@" (the sentinel); `*` stays literal (the work
    # dir contains `_build`, which a glob would have expanded it to).
    for part <- [1, 2] do
      assert argv(argv_dir, part) ==
               @base_argv ++ ["--slowest", "7", "--slowest-modules", "3", "*"]
    end

    # (b) runner facts: once
    assert Enum.count(lines, &String.contains?(&1, "test_parallel: runner nproc=")) == 1, out

    # (b) per partition: byte-exact summary once, then exactly one well-formed elapsed line
    for part <- [1, 2] do
      summary = "partition #{part}: 5 tests, 0 properties, 0 failures, exit 0"
      assert Enum.count(lines, &(&1 == summary)) == 1, out

      re = ~r/^test_parallel: partition #{part} elapsed=([0-9]+)s start=\S+ end=\S+$/
      assert [elapsed_line] = Enum.filter(lines, &Regex.match?(re, &1)), out

      assert Enum.find_index(lines, &(&1 == summary)) <
               Enum.find_index(lines, &(&1 == elapsed_line))

      [_, secs] = Regex.run(re, elapsed_line)
      secs = String.to_integer(secs)

      # partition 2's stub slept 2 s, so its elapsed must reflect that; the upper bound
      # is generous for a loaded host
      if part == 2, do: assert(secs >= 1, elapsed_line)
      assert secs <= 60, elapsed_line
    end

    # (b) phase line: exactly one, well-formed
    assert Enum.count(lines, &String.contains?(&1, "phase elapsed=")) == 1, out
    assert Enum.count(lines, &Regex.match?(~r/^test_parallel: phase elapsed=[0-9]+s$/, &1)) == 1
  end

  test "PRINT_SLOWEST=1 echoes each partition own blocks exactly once also for a failing partition",
       %{tmp_dir: tmp} do
    {status, lines, _argv_dir} =
      run_script(tmp, [
        {"TEST_PARALLEL_PRINT_SLOWEST", "1"},
        {"STUB_SLOWEST", "1"},
        {"STUB_FAIL_PARTITION", "1"}
      ])

    out = Enum.join(lines, "\n")
    assert status == 1, out

    for part <- [1, 2] do
      assert slowest_lines(lines, part) == [
               "Top 3 slowest (2.4s), 51.8% of total time:",
               "  * test foo_p#{part} (Mod#{part}) (834.6ms) [test/x_test.exs:128]",
               "  * test bar_p#{part} (Mod#{part}) (700.1ms) [test/x_test.exs:140]",
               "Top 3 slowest (3.9s), 83.3% of total time:",
               "Letflow.XTestP#{part} (3936.0ms)",
               " [test/x_test#{part}.exs]"
             ],
             out
    end

    # the failing partition's pre-existing summary is untouched (the failure is real)
    assert Enum.count(lines, &(&1 == "partition 1: 1 tests, 0 properties, 1 failures, exit 2")) ==
             1,
           out
  end
end
