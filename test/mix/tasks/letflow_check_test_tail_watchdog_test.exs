defmodule Mix.Tasks.Letflow.Check.TestTailWatchdogTest do
  @moduledoc """
  T-2692: an isolated tail that stops saying anything must be killed and reported
  BY NAME, instead of the CI job running into its own timeout.

  Background: push CI run 45184714218 (2026-11-23) lost the isolated-tails job to
  the 30-minute job timeout, and the log never named the test that was running.
  The isolated tails (`mix letflow.check.test --tails-only`) spawn their own
  subprocesses -- the `:wasm_hang` discovery run, one subprocess per
  `:wasm_hang` test, and the `:lua_wallclock_race` run -- and those subprocesses
  had no bound of their own. `mix letflow.check.test` now watches each of them
  for silence (`TEST_TAIL_OUTPUT_TIMEOUT_S`, default 480 s) and, when one goes
  quiet, kills it and fails with a report that names the run, the ExUnit seed it
  used, the runner's load and the LAST TEST STARTED.

  The "last test started" is the part a group run needs: the
  `:lua_wallclock_race` tail runs eleven tests in ONE subprocess, and that
  subprocess's output carries ExUnit's dots and no names, so the report has to
  read the marker the child's own ExUnit run publishes
  (test/support/file_timeout_marker.ex) to name the test that was running.

  The technique is the one the existing `letflow_check_test_test.exs` uses: a fake
  `mix` on PATH, installed through the task's own executable-resolver seam
  (`{:letflow, :check_test_executable_resolver}`), so the module under test runs
  unmodified.
  """

  use ExUnit.Case, async: false
  @moduletag :unit
  @moduletag timeout: 120_000

  @hang_location "test/fake_wasm_hang_test.exs:42"
  @seed "424242"

  # The seeded lua hang's own test name, as the marker publishes it.
  @lua_hang_test "Letflow.Fixtures.SeededLuaHangTest.test hangs forever, " <>
                   "so the lua group's hang report can name it"

  setup do
    # An ambient TEST_* knob from a sharded CI job must not reach the task.
    Letflow.Test.TestParallelEnv.scrub_ambient!()

    fake_bin =
      Path.join(System.tmp_dir!(), "t2692_fake_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(fake_bin)
    on_exit(fn -> File.rm_rf!(fake_bin) end)

    %{fake_bin: fake_bin}
  end

  # A fake `mix` that behaves like the real one for the two calls the tails
  # runner makes: the `--dry-run` discovery (which prints the block the task
  # parses) and the per-test run. The hanging branch `exec`s its sleeper, so the
  # process the task kills is the sleeper itself and no orphan is left behind.
  #
  # `:wasm` -- the per-test wasm run HANGS (the hang under test).
  # `:lua`  -- the per-test wasm run passes and the LUA GROUP hangs instead, by
  #            running the real seeded-hang fixture (which installs the suite's
  #            own marker formatter), so the report has to read the marker to
  #            name the test that was running.
  defp install_fake_mix(fake_bin, mode) do
    fake_path = Path.join(fake_bin, "mix")

    body =
      case mode do
        :wasm ->
          """
            *"fake_wasm_hang_test"*)
              echo "Running ExUnit with seed: #{@seed}, max_cases: 8"
              exec sleep 600
              ;;
          """

        :lua ->
          """
            *"fake_wasm_hang_test"*)
              echo "Finished in 0.0 seconds"
              echo "Result: 0 passed"
              exit 0
              ;;
            *"lua_wallclock_race"*)
              exec #{lua_hang_command()}
              ;;
          """
      end

    File.write!(fake_path, """
    #!/usr/bin/env bash
    case "$*" in
      *"--dry-run"*)
        cat <<'FAKE_DISCOVERY_OUTPUT'
    Tests that would be executed:
    test/fake_wasm_hang_test.exs:42
    All tests have been excluded.
    Finished in 0.0 seconds
    Result: 0 tests, 1 excluded
    FAKE_DISCOVERY_OUTPUT
        exit 1
        ;;
    #{body}
      *)
        echo "Finished in 0.0 seconds"
        echo "Result: 0 passed"
        exit 0
        ;;
    esac
    """)

    File.chmod!(fake_path, 0o755)
  end

  # The command the fake `mix` runs for the lua group: the REAL seeded-hang
  # fixture, standalone (no mix, no database, no project build), with the
  # suite's own marker formatter installed -- so the marker the report reads is
  # written by the same code that writes it in a real run.
  defp lua_hang_command do
    elixir =
      System.find_executable("elixir") ||
        flunk("elixir not found on PATH -- the lua hang fixture runs standalone with it")

    fixture = Path.expand("../../fixtures/seeded_lua_hang/seeded_lua_hang.exs", __DIR__)

    "#{elixir} #{fixture}"
  end

  defp install_executable_resolver(fake_bin, name) do
    fake_path = Path.join(fake_bin, name)
    assert File.exists?(fake_path), "the fake #{name} was not installed at #{fake_path}"

    Application.put_env(:letflow, :check_test_executable_resolver, fn
      ^name -> fake_path
      _ -> nil
    end)

    on_exit(fn -> Application.delete_env(:letflow, :check_test_executable_resolver) end)
  end

  test "an isolated tail that goes silent is killed and reported by name", %{fake_bin: fake_bin} do
    install_fake_mix(fake_bin, :wasm)
    install_executable_resolver(fake_bin, "mix")

    System.put_env("TEST_TAIL_OUTPUT_TIMEOUT_S", "3")

    error =
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Letflow.Check.Test.run(["--tails-only"])
      end

    message = Exception.message(error)

    assert message =~ "TEST_TAIL_OUTPUT_TIMEOUT_S",
           "the failure must name the limit that fired:\n#{message}"

    assert message =~ @hang_location,
           "the failure must name the test that was running:\n#{message}"

    assert message =~ "seed: #{@seed}",
           "the failure must name the ExUnit seed of the hung run:\n#{message}"

    assert message =~ "runner load:",
           "the failure must name the runner's load:\n#{message}"

    # This subprocess published no marker (it is not an ExUnit run), so the
    # report says "unknown" rather than guessing a test name.
    assert message =~ "last test started: unknown",
           "the failure must state that no test was named:\n#{message}"
  end

  test "a hang inside the lua group is reported by the test that was running", %{
    fake_bin: fake_bin
  } do
    install_fake_mix(fake_bin, :lua)
    install_executable_resolver(fake_bin, "mix")

    System.put_env("TEST_TAIL_OUTPUT_TIMEOUT_S", "3")

    error =
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Letflow.Check.Test.run(["--tails-only"])
      end

    message = Exception.message(error)

    assert message =~ "mix test --only lua_wallclock_race",
           "the failure must name the group that hung:\n#{message}"

    assert message =~ "last test started: #{@lua_hang_test}",
           "the failure must name the lua test that was running:\n#{message}"

    assert message =~ "seeded_lua_hang.exs",
           "the failure must name the file that lua test lives in:\n#{message}"

    assert message =~ "seed: #{@seed}",
           "the failure must name the ExUnit seed of the hung run:\n#{message}"
  end

  test "the silence limit defaults to eight minutes and is configurable" do
    System.delete_env("TEST_TAIL_OUTPUT_TIMEOUT_S")
    assert Mix.Tasks.Letflow.Check.Test.tail_output_timeout_s() == 480

    System.put_env("TEST_TAIL_OUTPUT_TIMEOUT_S", "12")
    assert Mix.Tasks.Letflow.Check.Test.tail_output_timeout_s() == 12

    System.put_env("TEST_TAIL_OUTPUT_TIMEOUT_S", "not-a-number")

    assert_raise Mix.Error, ~r/TEST_TAIL_OUTPUT_TIMEOUT_S/, fn ->
      Mix.Tasks.Letflow.Check.Test.tail_output_timeout_s()
    end
  end
end
