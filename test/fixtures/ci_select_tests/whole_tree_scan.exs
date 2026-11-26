defmodule Letflow.Fixtures.WholeTreeScan do
  @moduledoc false
  # A seeded scan for the CI selection test: it carries its own pinned list and reads the
  # whole tree, so it is a member of the class the selector reserves for a backend-source
  # diff. It lives in a fixture, not in the test file: a test file that reads the whole tree
  # is itself a member of that class, and the selector's own test must not be one (its
  # runtime would land in every bounded run).
  use ExUnit.Case, async: true

  @dynamic_sql_files [
    "lib/letflow/demo/pinned.ex"
  ]

  defp files, do: Path.wildcard("lib/**/*.ex")
end
