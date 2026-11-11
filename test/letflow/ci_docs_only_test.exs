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

  test "T-1617: select returns only tests naming the changed path, plus the smoke set" do
    run = fn list ->
      {out, 0} =
        System.cmd("bash", ["-c", "printf '%s' \"$1\" | bash \"$2\" select", "_", list, @script],
          cd: @root
        )

      String.split(out, "\n", trim: true)
    end

    {all_out, 0} = System.cmd("bash", [@script, "files"], cd: @root)
    all = String.split(all_out, "\n", trim: true)

    picked = run.("docs/requirements.yaml\n")
    assert "test/mix/tasks/letflow_check_requirements_registration_test.exs" in picked

    assert Enum.all?(
             picked,
             &(&1 in all or &1 =~ "roles_scoped_approvers" or &1 =~ "form_schema_expressions")
           )

    unrelated = run.("docs/zz_" <> "nowhere/qzx_unique_name.md\n")
    assert length(unrelated) <= 6
    assert length(unrelated) < length(all)
    refute "test/mix/tasks/letflow_check_requirements_registration_test.exs" in unrelated
  end

  test "D3: the docs test list holds the tests that read docs/requirements.yaml" do
    {out, 0} = System.cmd("bash", [@script, "files"], cd: @root)
    files = String.split(out, "\n", trim: true)
    assert "test/docs/requirement_status_invariants_test.exs" in files
    assert Enum.all?(files, &String.ends_with?(&1, "_test.exs"))
  end

  test "D5: the boilerplate guide mention does not select a test file, any other docs path does",
       %{
         tmp_dir: dir
       } do
    File.mkdir_p!(Path.join(dir, "test"))

    files = %{
      "guide_only_test.exs" =>
        "@moduledoc \"\"\"\nUses DataCase per `docs/guides/test_developer_guide.md`\n\"\"\"\n",
      "helper_test.exs" => ~s|{:ok, doc: read("docs/roles.md")}\n|,
      "piped_test.exs" => "\"docs/roles.md\" |> File.read!()\n",
      "guide_and_other_test.exs" =>
        "# docs/guides/test_developer_guide.md\nread(\"docs/runbooks/x-y.md\")\n",
      "yaml_test.exs" => ~s|File.read!("docs/requirements.yaml")\n|,
      # T-1404: a mention in a comment line or in backtick prose is not a read
      "comment_only_test.exs" => "# reads docs/requirements.yaml\n    # (docs/roles.md)\n",
      "prose_only_test.exs" =>
        "@moduledoc \"\"\"\nSee `docs/requirements.yaml` and \\`docs/roles.md\\`\n\"\"\"\n"
    }

    for {name, body} <- files, do: File.write!(Path.join([dir, "test", name]), body)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {_, 0} = System.cmd("git", ["add", "."], cd: dir)

    {out, 0} = System.cmd("bash", [@script, "files"], cd: dir)
    selected = String.split(out, "\n", trim: true)

    assert selected == [
             "test/guide_and_other_test.exs",
             "test/helper_test.exs",
             "test/piped_test.exs",
             "test/yaml_test.exs"
           ]
  end

  test "D6: the real docs test list stays bounded and is computed fast (T-1363)" do
    {t, {out, 0}} =
      :timer.tc(fn -> System.cmd("bash", [@script, "files"], cd: @root) end, :millisecond)

    files = String.split(out, "\n", trim: true)
    assert t < 10_000, "selector took #{t} ms"
    # 173 files (about 3000 s serial) before T-1363; the budget leaves room for new docs guards
    # T-1675: +1 for letflow_case_test.exs (companion canary reads docs/requirements.yaml)
    # T-1683: +1 for scripts/companion_bootstrap_test.exs (reads the companion move list)
    assert length(files) < 72, "docs test list grew to #{length(files)} files"
    refute "test/letflow/engine_test.exs" in files
    # T-1404: 79 files still ran 575 s on main; these DB suites (80 s each) only cite a docs
    # path in a moduledoc or a comment and must stay out
    for f <- ~w(entities/records_test.exs help_test.exs routers/instances_test.exs) do
      refute "test/letflow/#{f}" in files
    end

    # tests that read a docs file through a helper or a piped File.read! stay selected
    assert "test/letflow/docs/roles_scoped_approvers_test.exs" in files
    assert "test/letflow/identity/sync_scope_guard_test.exs" in files
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
    assert steps["Run docs tests (docs-only change)"]["run"] =~ "ci_docs_only.sh select"
    # static job is not gated on docs_only: the register consistency checks still run
    refute inspect(get_in(ci, ["jobs", "backend_static"])) =~ "docs_only"
  end
end
