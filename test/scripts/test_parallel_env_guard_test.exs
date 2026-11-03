defmodule Letflow.Scripts.TestParallelEnvGuardTest do
  @moduledoc """
  Q-1037 / GH #2364 regression guard: a test that drives the real parallel-runner shell
  script or calls the check.test Mix task's `run/1` inherits the `TEST_PARALLEL_*` variables
  of a sharded CI job unless it scrubs them. This guard fails when such a test file does not
  reference the scrub helper module. There is NO allow-list.

  ## Detection rule (per file under `test/**/*.{ex,exs}`)

  First the source is reduced to "code": triple-quote heredocs (moduledocs, docs, multi-line
  strings) and whole-line `#` comments are dropped. Then a file is a SPAWN SITE when either

    * (A) a string literal in the code ENDS in the script's file name (a path such as
      `Path.expand("../../scripts/<script>", __DIR__)`) AND the code contains a process
      spawn primitive (`System.cmd(`, `System.shell(`, `Port.open(`, `:os.cmd(`); or
    * (B) the code calls the check.test task module's `run(` function, or runs the
      `"letflow.check.test"` task through `Mix.Task.run/rerun`.

  A spawn site must contain the code token for the helper module. A spawner reached only
  through another helper function is covered when that function's file uses the scrub helper
  (that file is itself a spawn site under rule A).

  ## Blind spots (deliberate, documented)

    * A script path assembled at runtime (concatenation, `Path.join/2` pieces), or a command
      string such as `"bash <path> --x"` that does not END in the script name.
    * A spawn via a primitive not listed above, or via a helper module living outside `test/`.
    * An aliased call to the check.test task module (`alias ...Check.Test` then `Test.run(`).
    * Spawns written inside a heredoc (heredocs are stripped as docs) and a helper-module
      mention in a trailing comment (counts as a reference).
    * Shell harnesses (`test/**/*.sh`) -- not run by ExUnit; they set their own env.
    * The check proves the helper is REFERENCED, not that it is applied to every spawn in the
      file; per-variable behaviour is pinned by `test_parallel_env_test.exs` and by the
      env-sensitive tests themselves.

  This file's own source avoids matching its own rule (patterns are built from fragments),
  which is what keeps the allow-list empty.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @script_name "test_parallel" <> ".sh"
  @helper "Letflow.Test." <> "TestParallelEnv"

  @spawn_primitives [~r/System\.cmd\(/, ~r/System\.shell\(/, ~r/Port\.open\(/, ~r/:os\.cmd\(/]

  # A string literal whose final characters before the closing quote are the script name.
  @script_literal Regex.compile!("[\"'][^\"'\\n]*" <> Regex.escape(@script_name) <> "[\"']")

  @check_test_call [
    Regex.compile!(Regex.escape("Mix.Tasks.Letflow.Check." <> "Test.run(")),
    Regex.compile!("Mix\\.Task\\.(?:re)?run\\(\\s*\"letflow\\.check\\." <> "test\"")
  ]

  defp code(path) do
    path
    |> File.read!()
    |> String.replace(~r/(?:~[a-zA-Z])?"""\R.*?^[ \t]*"""/ms, "")
    |> String.replace(~r/^[ \t]*#.*$/m, "")
  end

  defp spawn_site?(code) do
    (Regex.match?(@script_literal, code) and Enum.any?(@spawn_primitives, &Regex.match?(&1, code))) or
      Enum.any?(@check_test_call, &Regex.match?(&1, code))
  end

  defp test_sources do
    root = Path.expand("..", __DIR__)
    Path.wildcard(Path.join(root, "**/*.{ex,exs}"))
  end

  test "the scan sees the known spawn sites (guards against a silently empty scan)" do
    sites = for p <- test_sources(), spawn_site?(code(p)), do: Path.basename(p)

    for expected <- ~w(
          test_parallel_instrumentation_test.exs
          test_parallel_shard_test.exs
          test_parallel_watchdog_diag_test.exs
          test_parallel_watchdog_orphan_test.exs
          letflow_check_test_test.exs
        ) do
      assert expected in sites, "scan no longer detects #{expected} as a spawn site"
    end
  end

  test "every file that spawns the script or runs the check.test task uses the scrub helper" do
    root = Path.expand("..", __DIR__)

    violations =
      for path <- test_sources(),
          src = code(path),
          spawn_site?(src),
          not String.contains?(src, @helper),
          do: Path.relative_to(path, root)

    assert violations == [],
           "these files spawn the script / run check.test without #{@helper} " <>
             "(an ambient TEST_PARALLEL_* from a shard job would leak in): #{inspect(violations)}"
  end
end
