defmodule Letflow.Scripts.TestParallelShardTest do
  @moduledoc """
  Q-1037 / GH #2364: partition-space slicing in `scripts/test_parallel.sh`
  (`TEST_PARALLEL_SHARD=K/M`, or the lower-level `TEST_PARALLEL_TOTAL` +
  `TEST_PARALLEL_OFFSET`).

  A runner with `N` local partitions that is shard `K` of `M` executes GLOBAL partitions
  `(K-1)*N+1 .. K*N` of a `TOTAL = N*M` partition space, so M independent runners tile the
  suite exactly (Mix's `--partitions TOTAL` assigns files by `rem(index, TOTAL)`). Everything
  keyed by the partition index must therefore be the GLOBAL index: `MIX_TEST_PARTITION`, the
  per-partition build path and database (`config/test.exs` builds the database name as
  `"letflow_test\#{System.get_env("MIX_TEST_PARTITION")}"`, so asserting the
  `MIX_TEST_PARTITION` seen by `mix ecto.create`/`mix ecto.migrate` IS the database check),
  the `partition-<i>.ready` file of the template-build admission control (the stub `mix test`
  writes it exactly where `test/test_helper.exs` does) and the `partition <i>:` summary lines.

  Drives the REAL script under bash with a stub `mix` (and `psql`) first on `PATH`; same
  harness style as `test_parallel_instrumentation_test.exs`. The stub logs every invocation
  to `calls.log`, so "nothing was launched" for a rejected input is asserted as "no
  `mix compile`, no `mix test`, no ecto call". Needs a real `bash`; on Windows set
  `UAT_PF_BASH` (or `TEST_PARALLEL_BASH`). `async: false`: spawns process trees.
  """
  use ExUnit.Case, async: false

  alias Letflow.Test.TestParallelCapture

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @run_limit_ms 120_000

  defp bash,
    do:
      System.get_env("TEST_PARALLEL_BASH") || System.get_env("UAT_PF_BASH") ||
        System.find_executable("bash")

  defp script, do: Path.expand("../../scripts/test_parallel.sh", __DIR__)

  # Stub `mix` (env-driven), every invocation first appended to $STUB_ARGV_DIR/calls.log
  # as "<MIX_TEST_PARTITION or -> <argv>":
  #   test                 argv (one word per line) -> argv-<partition>; when
  #                        TEST_PARALLEL_TEMPLATE_READY_DIR is set, writes
  #                        partition-<partition>.ready there (mimicking
  #                        test/test_helper.exs) and logs its path to ready.log; prints
  #                        `Result: 5 passed`
  #   ecto.create/migrate  appends "<partition> <MIX_BUILD_PATH> <subcommand>" to db.log
  #   anything else        (e.g. compile) exit 0
  defp write_stubs(tmp) do
    bin = Path.join(tmp, "stubbin")
    File.mkdir_p!(bin)
    mix = Path.join(bin, "mix")

    File.write!(mix, ~S"""
    #!/usr/bin/env bash
    part="${MIX_TEST_PARTITION:--}"
    echo "$part $*" >> "$STUB_ARGV_DIR/calls.log"
    case "$1" in
      test)
        printf '%s\n' "$@" > "$STUB_ARGV_DIR/argv-$part"
        if [ -d "${MIX_BUILD_PATH:-}" ]; then s=seeded; else s=MISSING; fi
        echo "$part ${MIX_BUILD_PATH:-} $s" >> "$STUB_ARGV_DIR/build.log"
        if [ -n "${TEST_PARALLEL_TEMPLATE_READY_DIR:-}" ]; then
          : > "$TEST_PARALLEL_TEMPLATE_READY_DIR/partition-${MIX_TEST_PARTITION}.ready"
          echo "partition-${MIX_TEST_PARTITION}.ready" >> "$STUB_ARGV_DIR/ready.log"
        fi
        echo "Result: 5 passed"
        exit 0
        ;;
      ecto.create|ecto.migrate)
        echo "$part ${MIX_BUILD_PATH:-} $1" >> "$STUB_ARGV_DIR/db.log"
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

  # NB: test names become the tmp_dir path, which is passed to bash as an argument on
  # Windows; keep test names free of quotes and slashes.
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

    out_file = Path.join(tmp, "script.out")

    # `nil` unsets a variable in Port's :env, so an ambient knob cannot leak in
    # (MIX_TEST_PARTITION included: the script sets it per command itself).
    env =
      [
        {"TEST_PARALLEL_N", "4"},
        {"TEST_POOL_SIZE", "4"},
        {"TEST_PARALLEL_PARTITION_TIMEOUT_S", "240"},
        {"TEST_PARALLEL_PARTITION_KILL_GRACE_S", "1"},
        {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "4"},
        {"TEST_PARALLEL_SHARD", nil},
        {"TEST_PARALLEL_TOTAL", nil},
        {"TEST_PARALLEL_OFFSET", nil},
        {"TEST_PARALLEL_EXTRA_ARGS", nil},
        {"TEST_PARALLEL_PRINT_SLOWEST", nil},
        {"MIX_TEST_PARTITION", nil},
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
        {:args, ["-c", launcher, "launcher", bin, out_file, script()]}
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

  defp expected_argv(total),
    do: ["test", "--partitions", "#{total}", "--no-color", "--exclude", "high_pool_demand"]

  defp argv_parts(argv_dir) do
    argv_dir
    |> File.ls!()
    |> Enum.flat_map(fn
      "argv-" <> p -> [String.to_integer(p)]
      _ -> []
    end)
    |> Enum.sort()
  end

  defp argv(argv_dir, part),
    do: argv_dir |> Path.join("argv-#{part}") |> File.read!() |> String.split("\n", trim: true)

  defp db_log(argv_dir) do
    path = Path.join(argv_dir, "db.log")
    if File.exists?(path), do: path |> File.read!() |> String.split("\n", trim: true), else: []
  end

  # Each launched partition's build path must have been seeded by the script's Step 1.5
  # (the stub records, at `mix test` time, whether $MIX_BUILD_PATH exists as a directory).
  defp assert_build_paths_seeded(argv_dir, parts, out) do
    seeded =
      argv_dir
      |> Path.join("build.log")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Enum.sort(seeded) ==
             Enum.sort(for p <- parts, do: "#{p} _build/test-partition-#{p} seeded"),
           out
  end

  defp summary_parts(lines) do
    for l <- lines, [_, p] <- [Regex.run(~r/^partition (\d+): /, l)], do: String.to_integer(p)
  end

  defp assert_sliced_run(tmp, env, range, total) do
    {status, lines, argv_dir} = run_script(tmp, env)
    out = Enum.join(lines, "\n")

    # ISS-1080: on failure the message carries the tmp tree + partition/create logs.
    TestParallelCapture.with_context(tmp, out, fn ->
      assert_sliced_run_body(status, lines, argv_dir, out, range, total)
    end)
  end

  defp assert_sliced_run_body(status, lines, argv_dir, out, first..last//1 = range, total) do
    assert status == 0, out
    parts = Enum.to_list(range)

    # (1) every launched partition is a GLOBAL index and sees the global --partitions
    assert argv_parts(argv_dir) == parts, out
    for p <- parts, do: assert(argv(argv_dir, p) == expected_argv(total), out)

    # (2) DB create/migrate and build path use the same global index (config/test.exs
    # derives the DB name letflow_test<MIX_TEST_PARTITION> from that variable)
    expected_db =
      for p <- parts, sub <- ["ecto.create", "ecto.migrate"] do
        "#{p} _build/test-partition-#{p} #{sub}"
      end

    assert Enum.sort(db_log(argv_dir)) == Enum.sort(expected_db), out

    assert_build_paths_seeded(argv_dir, parts, out)

    # (3) summary lines are the global indices, nothing else
    assert summary_parts(lines) == parts, out

    # (4) the slice announcement and the combined-line suffix
    assert "test_parallel: slice #{first}..#{last} of #{total} (TOTAL=#{total} OFFSET=#{first - 1})" in lines,
           out

    combined = Enum.find(lines, &String.starts_with?(&1, "combined: "))
    assert combined, out

    assert String.ends_with?(
             combined,
             "-- #{length(parts)}/#{length(parts)} partitions reported (slice #{first}..#{last} of #{total})"
           ),
           combined

    {lines, argv_dir}
  end

  describe "TEST_PARALLEL_SHARD" do
    test "shard 2 of 3 with N=4 runs global partitions 5..8 of 12", %{tmp_dir: tmp} do
      {lines, _} =
        assert_sliced_run(
          tmp,
          [{"TEST_PARALLEL_SHARD", "2/3"}],
          5..8,
          12
        )

      refute Enum.any?(lines, &String.starts_with?(&1, "partition 1:"))
    end

    test "shard 2 of 3 under admission control cap 1 pairs the ready-file with the global index",
         %{tmp_dir: tmp} do
      # The loop index of the admission-control wait is the global partition number: the
      # runner must wait for partition-5.ready ... partition-8.ready (which the stub writes
      # exactly as test_helper.exs does). A loop-local 1..N index would wait for
      # partition-1.ready forever / fail.
      {lines, argv_dir} =
        assert_sliced_run(
          tmp,
          [
            {"TEST_PARALLEL_SHARD", "2/3"},
            {"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", "1"}
          ],
          5..8,
          12
        )

      assert Enum.any?(lines, &(&1 =~ "template-build admission control capped at 1 concurrent"))

      ready = argv_dir |> Path.join("ready.log") |> File.read!() |> String.split("\n", trim: true)

      assert Enum.sort(ready) ==
               for(p <- 5..8, do: "partition-#{p}.ready")
    end

    test "shard 1 of 3 with N=4 runs global partitions 1..4 of 12", %{tmp_dir: tmp} do
      assert_sliced_run(tmp, [{"TEST_PARALLEL_SHARD", "1/3"}], 1..4, 12)
    end

    test "shard 3 of 3 with N=4 runs global partitions 9..12 of 12", %{tmp_dir: tmp} do
      assert_sliced_run(tmp, [{"TEST_PARALLEL_SHARD", "3/3"}], 9..12, 12)
    end

    test "SHARD wins over TOTAL and OFFSET (even invalid ones)", %{tmp_dir: tmp} do
      assert_sliced_run(
        tmp,
        [
          {"TEST_PARALLEL_SHARD", "1/3"},
          {"TEST_PARALLEL_TOTAL", "abc"},
          {"TEST_PARALLEL_OFFSET", "77"}
        ],
        1..4,
        12
      )
    end
  end

  describe "TEST_PARALLEL_TOTAL and TEST_PARALLEL_OFFSET" do
    test "TOTAL=12 OFFSET=8 with N=4 is the same slice as shard 3 of 3", %{tmp_dir: tmp} do
      assert_sliced_run(
        tmp,
        [{"TEST_PARALLEL_TOTAL", "12"}, {"TEST_PARALLEL_OFFSET", "8"}],
        9..12,
        12
      )
    end
  end

  describe "no shard environment (regression: output and argv exactly as before)" do
    for {label, cap} <- [{"default admission cap", "4"}, {"admission cap 1", "1"}] do
      test "N=4 runs partitions 1..4 of 4 with no slice text, #{label}", %{tmp_dir: tmp} do
        {status, lines, argv_dir} =
          run_script(tmp, [{"TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS", unquote(cap)}])

        out = Enum.join(lines, "\n")

        TestParallelCapture.with_context(tmp, out, fn ->
          assert_no_shard_run(status, lines, argv_dir, out)
        end)
      end
    end
  end

  defp assert_no_shard_run(status, lines, argv_dir, out) do
    assert status == 0, out

    assert argv_parts(argv_dir) == [1, 2, 3, 4], out
    for p <- 1..4, do: assert(argv(argv_dir, p) == expected_argv(4), out)

    assert Enum.sort(db_log(argv_dir)) ==
             Enum.sort(
               for p <- 1..4, sub <- ["ecto.create", "ecto.migrate"] do
                 "#{p} _build/test-partition-#{p} #{sub}"
               end
             ),
           out

    assert_build_paths_seeded(argv_dir, [1, 2, 3, 4], out)
    assert summary_parts(lines) == [1, 2, 3, 4], out
    # (not a bare "slice": the test name, hence the tmp path in the output, may contain it)
    refute Enum.any?(lines, &Regex.match?(~r/slice [0-9]+\.\.[0-9]+|\(slice /, &1)), out

    combined = Enum.find(lines, &String.starts_with?(&1, "combined: "))
    assert combined, out
    assert String.ends_with?(combined, "-- 4/4 partitions reported"), combined
  end

  describe "invalid slice inputs are rejected before anything is launched" do
    bad_inputs = [
      {"SHARD 0 of 3", [{"TEST_PARALLEL_SHARD", "0/3"}], "TEST_PARALLEL_SHARD"},
      {"SHARD 4 of 3", [{"TEST_PARALLEL_SHARD", "4/3"}], "greater than M"},
      {"SHARD abc", [{"TEST_PARALLEL_SHARD", "abc"}], "TEST_PARALLEL_SHARD"},
      {"SHARD 2 of 0", [{"TEST_PARALLEL_SHARD", "2/0"}], "TEST_PARALLEL_SHARD"},
      {"SHARD 1 of 3 of 4", [{"TEST_PARALLEL_SHARD", "1/3/4"}], "TEST_PARALLEL_SHARD"},
      {"SHARD negative K", [{"TEST_PARALLEL_SHARD", "-1/3"}], "TEST_PARALLEL_SHARD"},
      {"OFFSET plus N exceeds TOTAL",
       [{"TEST_PARALLEL_TOTAL", "12"}, {"TEST_PARALLEL_OFFSET", "9"}], "exceeds TOTAL"},
      {"TOTAL abc", [{"TEST_PARALLEL_TOTAL", "abc"}], "TEST_PARALLEL_TOTAL"},
      {"TOTAL zero", [{"TEST_PARALLEL_TOTAL", "0"}], "TEST_PARALLEL_TOTAL"},
      {"OFFSET abc", [{"TEST_PARALLEL_OFFSET", "abc"}], "TEST_PARALLEL_OFFSET"},
      {"OFFSET negative", [{"TEST_PARALLEL_OFFSET", "-1"}], "TEST_PARALLEL_OFFSET"}
    ]

    for {label, env, needle} <- bad_inputs do
      test "#{label} exits 1 with an error and launches nothing", %{tmp_dir: tmp} do
        {status, lines, argv_dir} = run_script(tmp, unquote(Macro.escape(env)))
        out = Enum.join(lines, "\n")

        assert status == 1, out
        assert out =~ "test_parallel: ERROR", out
        assert out =~ unquote(needle), out

        # nothing launched: not even the pre-compile
        assert argv_parts(argv_dir) == [], out
        assert db_log(argv_dir) == [], out
        refute File.exists?(Path.join(argv_dir, "calls.log")), out
        refute out =~ "pre-compiling", out
      end
    end
  end
end
