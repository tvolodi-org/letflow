# T-2692: a SEEDED hanging test file for the ISOLATED LUA GROUP -- the
# `mix letflow.check.test --tails-only` subprocess that runs
# `mix test --only lua_wallclock_race`.
#
# Why this file exists: that tail runs a GROUP of tests in ONE subprocess, and
# the group's own output carries ExUnit's dots and no names. A hang inside it
# could therefore only be reported as "the lua group" -- which is exactly the
# failure mode this task is about (push CI run 45184714218 lost the
# isolated-tails job to the 30-minute job timeout with nothing named).
#
# So the group needs to publish WHICH test it is on. This file does that with
# the suite's OWN marker formatter (test/support/file_timeout_marker.ex -- the
# same one `scripts/test_parallel.sh`'s partitions install), which writes the
# running test's file, module and name into the marker file the watcher reads.
#
# It runs STANDALONE (`elixir test/fixtures/seeded_lua_hang/seeded_lua_hang.exs`
# -- no mix, no database, no project build), so the seeded hang is cheap and
# hermetic. The marker module is loaded from its source file for the same
# reason: it is not compiled into this standalone run.
#
# It is deliberately NOT named `*_test.exs` and does NOT live under
# `test/support`, so:
#   * `mix test` never collects it (the default pattern is `*_test.exs`), and
#   * it is never compiled into the test build (`elixirc_paths(:test)` is
#     `["lib", "test/support"]`), so its test is never registered in any run.
# The one thing that ever runs it is
# `test/mix/tasks/letflow_check_test_tail_watchdog_test.exs`, which drives the
# isolated tails runner with it.
#
# The `:lua_wallclock_race` tag is what the real group is selected by; it is
# kept so the fixture cannot be collected by a plain `mix test` even if the
# collection pattern ever changes (test/test_helper.exs excludes that tag).
marker_source = Path.expand("../../support/file_timeout_marker.ex", __DIR__)
_ = Code.require_file(marker_source)

# The module name is built at runtime (Module.concat/1) so that compiling this
# file does not warn about a module that is only loaded at run time.
marker = Module.concat(["Letflow.Test.FileTimeoutMarker"])

# A FIXED seed, so the report of a hang names a seed that reproduces it.
ExUnit.start(seed: 424_242, formatters: [marker, ExUnit.CLIFormatter])

defmodule Letflow.Fixtures.SeededLuaHangTest do
  @moduledoc """
  A test that hangs on purpose, so the isolated lua group's hang report can
  name the test that was running.
  """

  use ExUnit.Case

  @tag timeout: :infinity
  @tag :lua_wallclock_race
  test "hangs forever, so the lua group's hang report can name it" do
    Process.sleep(:infinity)
  end
end
