defmodule Letflow.Scripts.TestParallelPoolBehaviourTest do
  @moduledoc """
  GH #2460: behavioural coverage of `scripts/test_parallel.sh` Step 1.4 (host Postgres
  ceiling check), Step 1.5 (pool clamp) and the opt-in connection sampler. Restores the
  15 cases of the removed `test_parallel_pool_sizing_test.sh`, without extracting or
  evaluating any script text.

  Drives the REAL script under bash with a stub `mix` on `PATH` (compile, `ecto.*` and
  `test` succeed; `STUB_FAIL_CREATE=1` makes `ecto.create` fail so a run ends right after
  the lines under test) and a fake `psql` that answers `show max_connections;` /
  `show superuser_reserved_connections;` from `STUB_PSQL_MAX` / `STUB_PSQL_SUPER`
  (`STUB_PSQL_FAIL=1`: unreachable server) and logs every query. The "no psql" cases hide
  any real `psql` from `PATH` by shadowing its directory without that binary.

  Expected pool sizes are hand-computed oracles (defaults: max 100, superuser 3, headroom
  10, nonpool reserve 5, so budget = 82 - N * per_partition_headroom, pool = budget / N,
  floor 2); they are not read from the script. `async: false`: spawns process trees.
  Needs a real `bash`; on Windows set `UAT_PF_BASH` (or `TEST_PARALLEL_BASH`).
  """
  use ExUnit.Case, async: false

  alias Letflow.Test.TestParallelEnv

  @moduletag timeout: 240_000

  @run_limit_ms 120_000

  # A short per-test directory: the generated `tmp_dir` embeds the test name, and a long
  # path makes `Port.open` fail with :eacces on Windows.
  setup do
    dir = Path.join(System.tmp_dir!(), "tpb#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, tmp_dir: dir}
  end

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # Both stubs are env driven; see the moduledoc.
  defp write_stubs(tmp, psql?) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)

    mix = Path.join(bin, "mix")

    File.write!(mix, """
    #!/usr/bin/env bash
    case "$1" in
      ecto.create)
        if [ "${STUB_FAIL_CREATE:-0}" = "1" ]; then echo "stub: create refused"; exit 1; fi
        exit 0
        ;;
      test)
        if [ "${STUB_WAIT_SAMPLER:-0}" = "1" ]; then
          # Bounded wait (<= 10 s) for the sampler's first poll to reach the fake psql.
          n=0
          while [ "$n" -lt 100 ] && ! grep -q pg_stat_activity "$STUB_PSQL_LOG" 2>/dev/null; do
            sleep 0.1
            n=$((n + 1))
          done
        fi
        if [ -n "${TEST_PARALLEL_TEMPLATE_READY_DIR:-}" ]; then
          : > "$TEST_PARALLEL_TEMPLATE_READY_DIR/partition-${MIX_TEST_PARTITION}.ready"
        fi
        echo "Result: 5 passed"
        exit 0
        ;;
      *) exit 0 ;;
    esac
    """)

    File.chmod!(mix, 0o755)

    if psql? do
      psql = Path.join(bin, "psql")

      File.write!(psql, """
      #!/usr/bin/env bash
      q="$*"
      echo "$q" >> "$STUB_PSQL_LOG"
      if [ "${STUB_PSQL_FAIL:-0}" = "1" ]; then exit 1; fi
      case "$q" in
        *"show max_connections;"*) echo "${STUB_PSQL_MAX:-100}" ;;
        *"show superuser_reserved_connections;"*) echo "${STUB_PSQL_SUPER:-3}" ;;
        *pg_stat_activity*) echo 0 ;;
      esac
      exit 0
      """)

      File.chmod!(psql, 0o755)
    end

    bin
  end

  # Prepends the stub dir to PATH; when `HIDE_PSQL=1`, every other PATH directory holding a
  # `psql` is replaced by a shadow directory of links/copies to everything but `psql`.
  @launcher ~S"""
  d=$(cygpath -u "$1" 2>/dev/null || printf '%s' "$1"); out="$2"; shadow="$3"; shift 3
  newpath="$d"
  IFS=:
  for p in $PATH; do
    [ -d "$p" ] || continue
    if [ "${HIDE_PSQL:-0}" = "1" ] && { [ -e "$p/psql" ] || [ -e "$p/psql.exe" ]; }; then
      s="$shadow/$(printf '%s' "$p" | tr -c 'A-Za-z0-9' _)"
      mkdir -p "$s"
      for f in "$p"/*; do
        b="${f##*/}"
        case "$b" in psql|psql.exe) continue ;; esac
        ln -s "$f" "$s/$b" 2>/dev/null || cp "$f" "$s/$b" 2>/dev/null
      done
      p="$s"
    fi
    newpath="$newpath:$p"
  done
  unset IFS
  PATH="$newpath"; export PATH
  bash "$@" > "$out" 2>&1
  """

  # NB: test names become the tmp_dir path; keep names free of quotes and slashes.
  # Returns {exit_status, output, psql_log}.
  defp run_script(tmp, env, opts \\ []) do
    psql? = Keyword.get(opts, :psql, true)
    bin = write_stubs(tmp, psql?)
    work = Path.join(tmp, "work")
    File.mkdir_p!(Path.join(work, "_build/test"))
    File.write!(Path.join(work, "_build/test/marker"), "x")
    tmpdir = Path.join(tmp, "tp_tmp")
    File.mkdir_p!(tmpdir)
    psql_log = Path.join(tmp, "psql.log")
    File.write!(psql_log, "")
    out_file = Path.join(tmp, "script.out")

    base = [
      {"TEST_PARALLEL_N", "4"},
      {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "240"},
      {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
      {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
      {"HIDE_PSQL", if(psql?, do: "0", else: "1")},
      {"TMPDIR", tmpdir},
      {"LETFLOW_DB_PORT", "5999"},
      {"STUB_PSQL_LOG", psql_log}
    ]

    port =
      Port.open({:spawn_executable, bash()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, work},
        {:env, TestParallelEnv.port_env(Map.merge(Map.new(base), Map.new(env)))},
        {:args,
         [
           "-c",
           @launcher,
           "launcher",
           bin,
           out_file,
           Path.join(tmp, "shadow"),
           script()
         ]}
      ])

    status = collect(port, System.monotonic_time(:millisecond))
    out = out_file |> File.read!() |> String.replace("\r", "")
    {status, out, File.read!(psql_log)}
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

  # The clamp only matters up to the pool line, so sweeps stop there (create refused).
  @fast [{"STUB_FAIL_CREATE", "1"}]

  defp pool_line(out),
    do: Regex.run(~r/^test_parallel: TEST_POOL_SIZE=(\d+) \(computed: (.*)\)$/m, out)

  defp assert_pool(out, pool, budget_note \\ nil) do
    assert [_, got, detail] = pool_line(out) || flunk("no TEST_POOL_SIZE line in:\n#{out}")
    assert String.to_integer(got) == pool, out
    if budget_note, do: assert(detail =~ budget_note, out)
  end

  describe "Step 1.5 pool clamp (defaults: max 100, superuser 3, headroom 10, reserve 5)" do
    test "N=4 gives 20", %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"TEST_PARALLEL_N", "4"}])
      assert status == 0, out
      assert_pool(out, 20, "N=4, max_connections=100, superuser_reserved=3, headroom=10")
      assert out =~ "nonpool_reserve=5, per_partition_headroom=0"
      refute out =~ "WARN N="
    end

    test "N=16 gives 5", %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"TEST_PARALLEL_N", "16"}])
      assert status == 0, out
      assert_pool(out, 5, "N=16")
    end

    test "both new reserves neutralised: N=4 gives 22, the pre-fix value", %{tmp_dir: tmp} do
      {status, out, _} =
        run_script(tmp, [
          {"TEST_SUPERUSER_RESERVED", "0"},
          {"TEST_NONPOOL_CONNECTION_RESERVE", "0"}
        ])

      assert status == 0, out
      assert_pool(out, 22, "nonpool_reserve=0")
    end

    test "a caller-set TEST_POOL_SIZE wins and is reported as an override", %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"TEST_POOL_SIZE", "9"}])
      assert status == 0, out
      assert out =~ "test_parallel: TEST_POOL_SIZE=9 (caller override, not computed)"
    end

    test "N sweep at the default per-partition headroom (0): budget 82 at every N",
         %{tmp_dir: tmp} do
      expected = %{
        1 => 82,
        2 => 41,
        3 => 27,
        4 => 20,
        5 => 16,
        6 => 13,
        7 => 11,
        8 => 10,
        9 => 9,
        12 => 6,
        16 => 5,
        24 => 3,
        32 => 2
      }

      for {n, pool} <- expected do
        {_status, out, _} =
          run_script(Path.join(tmp, "n#{n}"), [{"TEST_PARALLEL_N", "#{n}"} | @fast])

        assert_pool(out, pool, "N=#{n},")
        refute out =~ "WARN N=", "N=#{n}: " <> out
      end
    end

    test "N sweep with TEST_PER_PARTITION_HEADROOM=1: budget 82 - N, N=32 clamps to 2",
         %{tmp_dir: tmp} do
      expected = %{
        1 => 81,
        2 => 40,
        3 => 26,
        4 => 19,
        5 => 15,
        6 => 12,
        7 => 10,
        8 => 9,
        9 => 8,
        12 => 5,
        16 => 4,
        24 => 2,
        32 => 2
      }

      for {n, pool} <- expected do
        {_status, out, _} =
          run_script(Path.join(tmp, "n#{n}"), [
            {"TEST_PARALLEL_N", "#{n}"},
            {"TEST_PER_PARTITION_HEADROOM", "1"} | @fast
          ])

        assert_pool(out, pool, "per_partition_headroom=1")

        if n == 32 do
          # raw 50 / 32 = 1 < floor 2: warned and clamped, the run still goes on.
          assert out =~ "WARN N=32 partitions would need pool_size=1 to fit within 50 connections"
          assert out =~ "clamping to the TEST_MIN_POOL_SIZE floor of 2"
        else
          refute out =~ "WARN N=", "N=#{n}: " <> out
        end
      end
    end

    test "dynamic N (no TEST_PARALLEL_N): the pool matches the host's own nproc", %{tmp_dir: tmp} do
      {nproc, 0} = System.cmd(bash(), ["-c", "nproc"])
      n = nproc |> String.trim() |> String.to_integer()

      {_status, out, _} = run_script(tmp, [{"TEST_PARALLEL_N", nil} | @fast])

      assert out =~ "test_parallel: N=#{n} (source: nproc)"
      assert_pool(out, max(div(82, n), 2), "N=#{n},")
    end

    test "malformed TEST_SUPERUSER_RESERVED is an ERROR and exit 1", %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"TEST_SUPERUSER_RESERVED", "abc"}])
      assert status == 1, out

      assert out =~
               "test_parallel: ERROR TEST_SUPERUSER_RESERVED='abc' is not a non-negative integer"

      refute out =~ "TEST_POOL_SIZE="
    end

    test "malformed TEST_NONPOOL_CONNECTION_RESERVE is an ERROR and exit 1", %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"TEST_NONPOOL_CONNECTION_RESERVE", "xyz"}])
      assert status == 1, out

      assert out =~
               "test_parallel: ERROR TEST_NONPOOL_CONNECTION_RESERVE='xyz' is not a non-negative integer"

      refute out =~ "TEST_POOL_SIZE="
    end
  end

  describe "Step 1.4 host ceiling check" do
    test "no psql: WARN and skip, the run continues", %{tmp_dir: tmp} do
      {status, out, log} = run_script(tmp, [], psql: false)
      assert status == 0, out

      assert out =~
               "test_parallel: WARN psql not found -- skipping host Postgres ceiling verification"

      refute out =~ "host ceiling verified"
      assert log == ""
      assert_pool(out, 20)
    end

    test "defaults verified when the server reports max 100 and superuser 3", %{tmp_dir: tmp} do
      {status, out, log} = run_script(tmp, [])
      assert status == 0, out

      assert out =~
               "test_parallel: host ceiling verified -- live max_connections=100, superuser_reserved_connections=3 match"

      refute out =~ "does not match"
      assert log =~ "show max_connections;"
      assert log =~ "-p 5999"
    end

    test "live max_connections=90 against the assumed 100 is a WARN, not a failure",
         %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"STUB_PSQL_MAX", "90"}])
      assert status == 0, out

      assert out =~
               "test_parallel: WARN live Postgres max_connections=90 does not match assumed TEST_MAX_CONNECTIONS=100"

      refute out =~ "host ceiling verified"
      assert_pool(out, 20)
    end

    test "unreachable server is a WARN, not a failure", %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"STUB_PSQL_FAIL", "1"}])
      assert status == 0, out
      assert out =~ "test_parallel: WARN could not reach Postgres at localhost:5999"
      refute out =~ "host ceiling verified"
    end
  end

  describe "connection sampler gating (TEST_PARALLEL_SAMPLE_CONNECTIONS)" do
    test "unset: never started", %{tmp_dir: tmp} do
      {status, out, log} = run_script(tmp, [])
      assert status == 0, out
      refute out =~ "connection sampler"
      refute log =~ "pg_stat_activity"
    end

    test "set without psql: WARN, sampler not started", %{tmp_dir: tmp} do
      {status, out, _} = run_script(tmp, [{"TEST_PARALLEL_SAMPLE_CONNECTIONS", "1"}], psql: false)
      assert status == 0, out

      assert out =~
               "test_parallel: WARN TEST_PARALLEL_SAMPLE_CONNECTIONS set but psql not found -- sampler not started"

      refute out =~ "connection sampler enabled"
    end

    test "set with psql: the sampler runs and polls pg_stat_activity", %{tmp_dir: tmp} do
      {status, out, log} =
        run_script(tmp, [{"TEST_PARALLEL_SAMPLE_CONNECTIONS", "1"}, {"STUB_WAIT_SAMPLER", "1"}])

      assert status == 0, out
      assert out =~ "test_parallel: connection sampler enabled -- logging to"
      refute out =~ "sampler not started"
      assert log =~ "pg_stat_activity"
    end
  end
end
