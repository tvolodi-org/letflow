defmodule Letflow.Modules.Stock.OpeningFourEyesScenarioTest do
  @moduledoc """
  FE-S-UAT (T-1988): the one-person four-eyes UAT scenario file exists and passes the scenario schema
  check (`Mix.Tasks.Letflow.CheckUatScenarioSchema.check_file/1`). No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @path "test/fixtures/uat/scenarios/assets/stock-opening-1-one-person-four-eyes-off.yaml"

  test "FE-S-UAT the scenario file exists and has no schema violation" do
    assert File.exists?(@path)

    assert %{ok?: true, violations: []} =
             Mix.Tasks.Letflow.CheckUatScenarioSchema.check_file(@path)
  end
end
