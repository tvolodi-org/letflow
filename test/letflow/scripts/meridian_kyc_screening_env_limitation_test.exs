defmodule Letflow.Scripts.MeridianKycScreeningEnvLimitationTest do
  @moduledoc """
  GH #3076 -- the `kyc-aml-check` service task of the QA Meridian loan origination definition
  calls a static stub URL that always answers `kyc_status=clear`, so the scenario
  `meridian-loan-origination-kyc-manual-review` cannot run on QA. The gap is recorded as
  permanent in a `scenario-env-limitations` sidecar instead of forcing a `hit` for
  `borrower-kyc-hit-001` from inside the definition.

  The first test is the reason an applicant-dependent stub was not added: the screening
  endpoint carries no instance data, so no applicant (or its submitter) can choose its own
  screening result. Any future templating of these nodes (`{{variables.KEY}}` is the only
  applicant-dependent mechanism the engine has) fails it and forces a revisit.

  Pure: no DB, no HTTP.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @definition "test/fixtures/qa/meridian_loan_origination_process_definition.json"
  @sidecar "test/fixtures/uat/scenario-env-limitations/meridian-loan-origination-kyc-manual-review.yaml"
  @scenario "test/fixtures/uat/scenarios/meridian/loan-origination-kyc-manual-review.yaml"
  @scenario_id "meridian-loan-origination-kyc-manual-review"

  defp node!(id) do
    @definition
    |> File.read!()
    |> Jason.decode!()
    |> find_nodes()
    |> Enum.find(&(&1["id"] == id)) || flunk("node #{id} not found")
  end

  defp find_nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp find_nodes(%{"graph" => graph}), do: find_nodes(graph)
  defp find_nodes(%{"definition" => d}), do: find_nodes(d)

  describe "GH #3076 kyc screening stub" do
    test "T1 no applicant-controlled input reaches kyc-aml-check or kyc-timeout" do
      for id <- ["kyc-aml-check", "kyc-timeout"] do
        attrs = node!(id)["attributes"]
        assert is_binary(attrs["endpoint"])
        refute attrs["endpoint"] =~ "{{", "#{id} endpoint must stay a static URL"

        for key <- ["body_template", "headers", "service_id"] do
          refute Map.has_key?(attrs, key), "#{id} must not carry #{key}"
        end
      end

      assert node!("kyc-aml-check")["attributes"]["endpoint"] ==
               "https://httpbin.org/response-headers?kyc_status=clear"
    end

    test "T2 sidecar matches the scenario and records the gap for qa" do
      {:ok, sidecar} = YamlElixir.read_from_file(@sidecar)
      {:ok, scenario} = YamlElixir.read_from_file(@scenario)

      assert scenario["id"] == @scenario_id
      assert sidecar["scenario_id"] == scenario["id"]
      assert sidecar["classification"] == "ENV_NOT_SUPPORTED"
      assert "qa" in sidecar["applies_to_environments"]
      assert sidecar["issue_ref"] =~ "3076"

      # preflight's fallback regex only matches the single-line flow form
      assert File.read!(@sidecar) =~ ~r/^applies_to_environments: \[qa\]\s*$/m
      assert File.read!(@scenario) =~ "borrower-kyc-hit-001"
    end

    test "T3 scenario header and precondition match the outcome" do
      text = File.read!(@scenario)

      assert text =~ "scenario-env-limitations"
      assert text =~ "3076"
      refute text =~ "Until that exists"
      refute text =~ "BLOCKED"
    end
  end
end
