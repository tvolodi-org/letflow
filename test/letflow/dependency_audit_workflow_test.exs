defmodule Letflow.DependencyAuditWorkflowTest do
  @moduledoc """
  T-1742: the weekly dependency audit workflow is a report, never a gate: scheduled, read-only, no secrets,
  every audit step continue-on-error, summary plus artifact. Text checks on the workflow file.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @path Path.expand("../../.github/workflows/dependency-audit.yml", __DIR__)

  setup do
    {:ok, text: File.read!(@path)}
  end

  test "runs weekly and on demand, not on pull requests or merge groups", %{text: t} do
    assert t =~ ~r/schedule:\s*\n\s*- cron: "[^"]+ [^"]+ \* \* 1"/
    assert t =~ "workflow_dispatch:"
    refute t =~ "pull_request"
    refute t =~ "merge_group"
    refute t =~ ~r/^\s*push:/m
  end

  test "is read-only and uses no secrets", %{text: t} do
    assert t =~ ~r/permissions:\s*\n\s*contents: read/
    refute t =~ "secrets."
    refute t =~ "write"
  end

  test "every run step of the audit is continue-on-error", %{text: t} do
    steps = t |> String.split(~r/\n      - name: /) |> tl()
    assert length(steps) >= 8

    for s <- steps, s =~ "\n        run:" or s =~ "\n        uses:" do
      checkout? = s =~ "actions/checkout"

      assert checkout? or s =~ "continue-on-error: true" or s =~ "Write job summary",
             "step without continue-on-error: #{String.slice(s, 0, 40)}"
    end
  end

  test "posts the report as a job summary and an artifact", %{text: t} do
    assert t =~ "$GITHUB_STEP_SUMMARY"
    assert t =~ "actions/upload-artifact@v4"
    assert t =~ "name: dependency-audit"
  end

  test "covers hex, npm, pub and base images", %{text: t} do
    for needle <- ["mix hex.audit", "npm audit", "flutter pub outdated", "deploy/Dockerfile"] do
      assert t =~ needle, "missing #{needle}"
    end
  end
end
