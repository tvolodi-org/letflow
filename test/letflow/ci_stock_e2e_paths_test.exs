defmodule Letflow.CiStockE2ePathsTest do
  @moduledoc """
  T-1383: the selective rule of the CI job "Stock browser e2e (playwright)" (`scripts/ci_stock_e2e_paths.sh`) and the
  wiring of that job in `.github/workflows/stock-e2e.yml`. The browser specs themselves need a live stack and run in that job.

    * P1 a stock or asset web file (T-1915), a GATE B spec, the e2e stack scripts or the rule itself -> `stock_web=true`;
      docs, backend and other web files -> `stock_web=false`; an empty list -> false; always exit 0, one line;
    * W1 the job exists with the required-check name, runs on PR, merge queue, schedule and dispatch, decides per path
      through the script, runs the relogin spec only on schedule / dispatch, and fails (does not skip) a missing credential.
  """

  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/ci_stock_e2e_paths.sh")
  @wf_yml Path.join(@root, ".github/workflows/stock-e2e.yml")

  defp run_rule(dir, list) do
    input = Path.join(dir, "changed-#{System.unique_integer([:positive])}.txt")
    File.write!(input, list)
    driver = Path.join(dir, "rule.sh")
    File.write!(driver, ~s|script="$1"; input="$2"\nexec bash "$script" < "$input"\n|)
    System.cmd("bash", [driver, @script, input], stderr_to_stdout: true)
  end

  @cases [
    {"web/src/modules/stock/documents/Zz.tsx", "stock_web=true"},
    {"web/src/pages/tasks/Zz.tsx", "stock_web=true"},
    {"web/src/modules/assets/documents/Zz.tsx", "stock_web=true"},
    {"web/tests/e2e/gate-b-zz.e2e.spec.ts", "stock_web=true"},
    {"web/tests/e2e/gate-b-yy.e2e.spec.ts", "stock_web=true"},
    {"web/tests/e2e/support/zz.ts", "stock_web=true"},
    {"scripts/e2e/zz.sh", "stock_web=true"},
    {"scripts/ci_stock_e2e_paths.sh", "stock_web=true"},
    {"docs/testing/zz-note.md", "stock_web=false"},
    {"lib/letflow/zz.ex", "stock_web=false"},
    {"web/src/pages/zz/Zz.tsx", "stock_web=false"},
    {"", "stock_web=false"}
  ]

  describe "P1 the path rule" do
    for {path, expected} <- @cases do
      test "#{inspect(path)} -> #{expected}", %{tmp_dir: dir} do
        assert {out, 0} = run_rule(dir, unquote(path) <> "\n")
        assert String.split(out, "\n", trim: true) == [unquote(expected)]
      end
    end

    test "one matching file among many decides true", %{tmp_dir: dir} do
      list =
        Enum.map_join(1..2000, "\n", &"docs/file#{&1}.md") <> "\nweb/src/modules/stock/index.ts\n"

      assert {"stock_web=true\n", 0} = run_rule(dir, list)
    end
  end

  describe "W1 the job in ci.yml" do
    setup do
      %{ci: YamlElixir.read_from_file!(@wf_yml)}
    end

    test "has the required-check name and runs on PR, merge queue, schedule and dispatch", %{
      ci: ci
    } do
      assert get_in(ci, ["jobs", "stock_e2e", "name"]) == "Stock browser e2e (playwright)"
      on = ci["on"] || ci[true]

      for ev <- ["pull_request", "merge_group", "schedule", "workflow_dispatch"],
          do: assert(Map.has_key?(on, ev))
    end

    test "decides per path through the script and fails open", %{ci: ci} do
      steps = get_in(ci, ["jobs", "stock_e2e", "steps"])
      decide = Enum.find(steps, &(&1["id"] == "decide"))
      assert decide["run"] =~ "scripts/ci_stock_e2e_paths.sh"
      assert decide["run"] =~ "schedule|workflow_dispatch"
      assert decide["run"] =~ "fail open"
    end

    test "relogin spec only on schedule and dispatch; a missing credential fails the job", %{
      ci: ci
    } do
      steps = get_in(ci, ["jobs", "stock_e2e", "steps"])
      relogin = Enum.find(steps, &String.contains?(&1["run"] || "", "gate-b-relogin"))
      assert relogin["if"] =~ "schedule"
      assert relogin["if"] =~ "workflow_dispatch"
      assert get_in(relogin, ["env", "E2E_TOKEN_LIFESPAN"]) == "90"

      click = Enum.find(steps, &String.contains?(&1["run"] || "", "gate-b-stock"))
      assert click["run"] =~ ~s|"${E2E_ADMIN_USER:?|
      assert click["run"] =~ ~s|"${E2E_ADMIN_PASSWORD:?|
    end
  end
end
