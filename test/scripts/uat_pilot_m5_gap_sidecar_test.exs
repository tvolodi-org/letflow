defmodule Letflow.Scripts.UatPilotM5GapSidecarTest do
  @moduledoc """
  T-1719: the GAP sidecar for pilot milestone M5 (sign-in of created users) exists, is a GAP for
  `qa`, is not a skip.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @path "test/fixtures/uat/scenario-env-limitations/pilot-m5-created-users-sign-in.yaml"

  test "M5 sidecar states the gap" do
    {:ok, s} = YamlElixir.read_from_file(@path)
    assert s["scenario_id"] == "pilot-m5-created-users-sign-in"
    assert s["classification"] == "GAP"
    assert s["applies_to_environments"] == ["qa"]
    refute Map.has_key?(s, "disposition")
    assert s["reason"] =~ "NOT OBSERVABLE"
    assert s["issue_ref"] == "T-1719"
  end
end
