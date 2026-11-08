defmodule Letflow.Modules.Assets.OpeningImportScenariosTest do
  @moduledoc """
  G6-18 (T-1493, REQ-784 criterion 8): the two UAT scenario files of the opening-line import pass the
  scenario schema check (`mix letflow.check_uat_scenario_schema`, `check_file/1`), and the scenario
  directory is matched by the backend path filter. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @dir "test/fixtures/uat/scenarios/assets"
  @files ~w(assets-opening-import-1-draft-lines-from-xlsx.yaml
            assets-opening-import-2-refusals-and-other-company.yaml)

  test "G6-18 both scenario files exist and have no schema violation" do
    for file <- @files do
      path = Path.join(@dir, file)
      assert File.exists?(path), path

      assert %{ok?: true, violations: []} =
               Mix.Tasks.Letflow.CheckUatScenarioSchema.check_file(path)
    end
  end
end
