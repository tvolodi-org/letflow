defmodule Letflow.Gh2622CiCdTimeoutsTest do
  @moduledoc """
  GH #2622 R4 / OQ-4 (design `lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md` §4):
  every CI and CD job carries an explicit `timeout-minutes`, pinned to the design's values, so a
  hung job (the 360-minute default held CI's push slot on run 38665714603) ends as a
  non-success instead of starving the workflow.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")
  @cd_yml Path.join(@root, ".github/workflows/cd.yml")

  @ci_timeouts %{
    "changes" => 10,
    "backend_static" => 30,
    "backend_shard" => 45,
    "backend" => 15,
    "frontend" => 30,
    "mobile" => 45
  }

  @cd_timeouts %{"deploy" => 20, "skip-log" => 5}

  defp timeouts(path) do
    path
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("jobs")
    |> Map.new(fn {job, spec} -> {job, spec["timeout-minutes"]} end)
  end

  test "every CI job carries its pinned timeout-minutes" do
    assert timeouts(@ci_yml) == @ci_timeouts
  end

  test "every CD job carries its pinned timeout-minutes" do
    assert timeouts(@cd_yml) == @cd_timeouts
  end

  test "no job anywhere lacks timeout-minutes, and each is a positive integer" do
    for path <- [@ci_yml, @cd_yml], {job, t} <- timeouts(path) do
      assert is_integer(t) and t > 0,
             "#{Path.basename(path)} job #{job}: timeout-minutes #{inspect(t)}"
    end
  end
end
