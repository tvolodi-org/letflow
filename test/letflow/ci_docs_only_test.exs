defmodule Letflow.CiDocsOnlyTest do
  @moduledoc """
  T-1249: a pull request whose changed files are all under docs/ runs the static job and only the
  docs-related tests (`scripts/ci_docs_only.sh`); any other change runs the full shards. Dry-runs
  the path rule with sample file lists and pins the `ci.yml` wiring.
  """

  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/ci_docs_only.sh")
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")

  defp run_rule(dir, list) do
    input = Path.join(dir, "changed-#{System.unique_integer([:positive])}.txt")
    File.write!(input, list)
    driver = Path.join(dir, "drive.sh")
    File.write!(driver, ~s|exec bash "$1" < "$2"\n|)
    {out, 0} = System.cmd("bash", [driver, @script, input], cd: @root)
    String.trim(out)
  end

  test "script parses" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "D1: docs-only lists are docs_only=true", %{tmp_dir: dir} do
    for list <- [
          "docs/requirements.yaml\n",
          "docs/requirements.yaml\ndocs/migration/decisions/0100-x.md\ndocs/assets/a.png\n",
          "docs/a/b.md"
        ] do
      assert run_rule(dir, list) == "docs_only=true", inspect(list)
    end
  end

  test "D2: docs plus code, code only, empty or lookalike paths are docs_only=false", %{
    tmp_dir: dir
  } do
    for list <- [
          "docs/requirements.yaml\nlib/letflow/engine.ex\n",
          "lib/letflow/engine.ex\n",
          "test/letflow/engine_test.exs\n",
          "docs/a.md\n.github/workflows/ci.yml\n",
          "docs/a.md\nscripts/ci_docs_only.sh\n",
          "README.md\n",
          "mydocs/a.md\n",
          ""
        ] do
      assert run_rule(dir, list) == "docs_only=false", inspect(list)
    end
  end

  test "D3: the docs test list holds the tests that read docs/requirements.yaml" do
    {out, 0} = System.cmd("bash", [@script, "files"], cd: @root)
    files = String.split(out, "\n", trim: true)
    assert "test/docs/requirement_status_invariants_test.exs" in files
    assert Enum.all?(files, &String.ends_with?(&1, "_test.exs"))
  end

  test "D4: ci.yml wires the rule: shards keep their names, full test step is skipped when docs-only" do
    ci = YamlElixir.read_from_file!(@ci_yml)

    assert get_in(ci, ["jobs", "changes", "outputs", "docs_only"]) =~
             "steps.docs.outputs.docs_only"

    shard = get_in(ci, ["jobs", "backend_shard"])
    assert shard["name"] == "Backend shard ${{ matrix.shard }}/${{ strategy.job-total }}"
    assert get_in(ci, ["jobs", "backend", "name"]) == "Backend gate (mix letflow.check)"

    assert get_in(ci, ["jobs", "backend_static", "name"]) ==
             "Backend static checks + isolated tails"

    # job-level if is untouched, so the check names report on a docs-only change too
    assert shard["if"] =~ "needs.changes.outputs.backend != 'false'"
    refute shard["if"] =~ "docs_only"

    steps = Map.new(shard["steps"], &{&1["name"], &1})
    assert steps["Run test shard"]["if"] =~ "docs_only != 'true'"
    assert steps["Run docs tests (docs-only change)"]["if"] =~ "docs_only == 'true'"
    assert steps["Run docs tests (docs-only change)"]["run"] =~ "ci_docs_only.sh files"
    # static job is not gated on docs_only: the register consistency checks still run
    refute inspect(get_in(ci, ["jobs", "backend_static"])) =~ "docs_only"
  end
end
