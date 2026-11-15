defmodule Letflow.Modules.Assets.OpeningFourEyesScenarioTest do
  @moduledoc """
  FE-UAT (T-1987): the one-person four-eyes UAT scenario file exists and passes the scenario schema
  check (`Mix.Tasks.Letflow.CheckUatScenarioSchema.check_file/1`). No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @path "test/fixtures/uat/scenarios/assets/assets-opening-3-one-person-four-eyes-off.yaml"

  test "FE-UAT the scenario file exists and has no schema violation" do
    assert File.exists?(@path)

    assert %{ok?: true, violations: []} =
             Mix.Tasks.Letflow.CheckUatScenarioSchema.check_file(@path)
  end
end
