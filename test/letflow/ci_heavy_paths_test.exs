defmodule Letflow.CiHeavyPathsTest do
  @moduledoc """
  T-1139: exam and `:slow` tests run in a pull request only when the change touches exam code
  or a path they depend on (`scripts/ci_heavy_paths.sh`); the nightly and on-demand runs of
  `ci.yml` run everything, and `scripts/test_parallel.sh` drops the heavy files only when
  `TEST_PARALLEL_SKIP_HEAVY=1`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/ci_heavy_paths.sh")
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")
  @runner Path.join(@root, "scripts/test_parallel.sh")

  defp run_rule(list) do
    path = Path.join(System.tmp_dir!(), "heavy_paths_#{System.unique_integer([:positive])}.txt")
    File.write!(path, list)

    try do
      {out, 0} = System.cmd("bash", ["-c", "bash #{@script} < #{path}"], cd: @root)
      String.trim(out)
    after
      File.rm(path)
    end
  end

  test "script parses" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "H1: unrelated backend, docs and web changes do not need the heavy tests" do
    for list <- [
          "",
          "README.md\n",
          "lib/letflow/engine.ex\n",
          "test/letflow/engine_test.exs\n",
          "web/src/a.tsx\n"
        ] do
      assert run_rule(list) == "heavy=false", inspect(list)
    end
  end

  test "H2: exam code, exam tests, dependencies and heavy test files themselves need them" do
    for list <- [
          "lib/letflow/modules/exam/session.ex\n",
          "test/letflow/modules/exam/session_test.exs\n",
          "test/support/exam_fixtures.ex\n",
          "priv/repo/migrations/20261101000000_x.exs\n",
          "config/test.exs\n",
          "mix.lock\n",
          "scripts/test_parallel.sh\n",
          ".github/workflows/ci.yml\n",
          "test/letflow/routers/tasks_test.exs\n",
          "README.md\nlib/letflow/engine.ex\ntest/letflow/sandbox_pool_test.exs\n"
        ] do
      assert run_rule(list) == "heavy=true", inspect(list)
    end
  end

  test "H3: the heavy file list holds the exam tests and every :slow-tagged file" do
    {out, 0} = System.cmd("bash", [@script, "files"], cd: @root)
    files = String.split(out, "\n", trim: true)
    assert "test/letflow/modules/exam/session_test.exs" in files
    assert "test/letflow/routers/tasks_test.exs" in files
    refute "test/letflow/engine_test.exs" in files
  end

  test "H4: ci.yml runs the full suite nightly and on demand, and keeps the required names" do
    ci = @ci_yml |> File.read!() |> String.replace("\r\n", "\n")
    assert ci =~ ~r/^  schedule:\n    - cron: /m
    assert ci =~ ~r/^  workflow_dispatch:/m

    assert ci =~
             "TEST_PARALLEL_SKIP_HEAVY: ${{ needs.changes.outputs.heavy == 'false' && '1' || '' }}"

    assert ci =~ "name: Backend gate (mix letflow.check)"
    assert ci =~ "name: Frontend gate (npm run check)"
  end

  test "H5: test_parallel.sh skips heavy files only on TEST_PARALLEL_SKIP_HEAVY=1" do
    src = @runner |> File.read!() |> String.replace("\r\n", "\n")
    assert src =~ ~s|"${TEST_PARALLEL_SKIP_HEAVY:-}" = "1"|
    assert src =~ "skipped by path"
  end
end
