defmodule Letflow.Scripts.BpPlatform01OnboardingStatusTest do
  use ExUnit.Case, async: true

  # The 202 answer of POST /api/v1/onboarding carries the engine's status atom as a
  # string (`Letflow.PlatformProcesses.RouteStart.answer/2`: `to_string(result.status)`
  # = "active"), unlike the definition and instance GETs, which upcase it.
  @scenario "test/uat/processes/BP-PLATFORM-01-register-tenant.json"

  test "every onboarding start step expects the lowercase status of the 202 answer" do
    steps = @scenario |> File.read!() |> Jason.decode!() |> Map.fetch!("steps")

    starts =
      Enum.filter(steps, fn s ->
        get_in(s, ["do", "path"]) == "/api/v1/onboarding" and
          get_in(s, ["expect", "status"]) == 202
      end)

    assert length(starts) == 4

    for s <- starts do
      assert get_in(s, ["expect", "json", "$.status"]) == "active", "step #{s["id"]}"
    end
  end
end
