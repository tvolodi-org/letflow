# T-2692: a SEEDED hanging test file -- the fixture that seeds a real hang for
# `scripts/test_parallel.sh`'s output-silence watchdog.
#
# This is a real ExUnit test file with a real test that never returns. It is run
# STANDALONE (`elixir test/fixtures/seeded_hang/seeded_hang.exs` -- no mix, no
# database, no project build), so the seeded hang is cheap and hermetic.
#
# It is deliberately NOT named `*_test.exs` and does NOT live under
# `test/support`, so:
#   * `mix test` never collects it (the default pattern is `*_test.exs`), and
#   * it is never compiled into the test build (`elixirc_paths(:test)` is
#     `["lib", "test/support"]`), so its test is never registered in any run.
# The one thing that ever runs it is
# `test/scripts/test_parallel_output_timeout_test.exs`, which drives the real
# runner with it.
#
# Before it hangs, the file publishes the marker the suite's own marker
# formatter publishes (`test/support/file_timeout_marker.ex` -- the format is
# copied here on purpose, because this file runs outside the project's build
# and that module is not loaded there) and prints the ExUnit header line with
# a FIXED seed, so the watchdog's report has a seed that reproduces the hang.
ExUnit.start(seed: 424_242)

defmodule Letflow.Fixtures.SeededHangTest do
  @moduledoc """
  A test that hangs on purpose, so the CI partition watchdog can be shown
  naming it instead of costing a job timeout.
  """

  use ExUnit.Case

  @tag timeout: :infinity
  test "hangs forever, so the partition watchdog has a test to name" do
    publish_marker()
    Process.sleep(:infinity)
  end

  # The same key=value format the suite's marker formatter writes (see
  # test/support/file_timeout_marker.ex): the runner reads it to name the
  # running file and the last test that started in it.
  defp publish_marker do
    dir = System.get_env("TEST_PARALLEL_FILE_MARKER_DIR")

    if is_binary(dir) and dir != "" do
      partition = System.get_env("MIX_TEST_PARTITION") || "0"
      now = System.system_time(:second)

      File.write!(Path.join(dir, "current-#{partition}.txt"), """
      file=#{Path.expand(__ENV__.file)}
      module=Letflow.Fixtures.SeededHangTest
      started=#{now}
      progress=#{now}
      tests=Letflow.Fixtures.SeededHangTest.test hangs forever, so the partition watchdog has a test to name
      """)
    end
  end
end
