defmodule Letflow.Gh2622CiCdTimeoutsTest do
  @moduledoc """
  GH #2622 R4 / OQ-4 (design `lib/letflow/design/gh2622-ci-push-concurrency-and-cd-tip.md` §4):
  every CI and CD job carries an explicit `timeout-minutes`, pinned to the design's values, so a
  hung job (the 360-minute default held CI's push slot on run 38665714603) ends as a
  non-success instead of starving the workflow.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")
  @cd_yml Path.join(@root, ".github/workflows/cd.yml")

  @ci_timeouts %{
    "changes" => 10,
    "backend_static" => 30,
    "backend_shard" => 45,
    "backend" => 15,
    "frontend" => 30,
    "mobile" => 45,
    "full_run_marker" => 10
  }

  @cd_timeouts %{"deploy" => 20, "skip-log" => 5}

  defp timeouts(path) do
    path
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("jobs")
    |> Map.new(fn {job, spec} -> {job, spec["timeout-minutes"]} end)
  end

  test "R1: every CI job has a reversible ten-minute rollout with old defaults" do
    actual = timeouts(@ci_yml)

    for {job, budget} <- @ci_timeouts do
      expression = actual[job]
      assert expression =~ "github.event_name == 'schedule'"
      assert expression =~ "github.event_name == 'workflow_dispatch'"
      assert expression =~ "&& 60 ||"
      assert expression =~ "vars.CI_TIMEOUT_MINUTES == '10' && 10 || #{budget}"
    end
  end

  test "every CD job carries its pinned timeout-minutes" do
    assert timeouts(@cd_yml) == @cd_timeouts
  end

  test "no job anywhere lacks a timeout" do
    for path <- [@ci_yml, @cd_yml], {job, t} <- timeouts(path) do
      assert (is_integer(t) and t > 0) or
               (is_binary(t) and t =~ "vars.CI_TIMEOUT_MINUTES == '10'"),
             "#{Path.basename(path)} job #{job}: timeout-minutes #{inspect(t)}"
    end
  end

  @tag :tmp_dir
  test "R2: deadline fails with job and unfinished files before cancellation", %{tmp_dir: dir} do
    plan = Path.join(dir, "plan.txt")

    File.write!(
      plan,
      "1 test/finished_test.exs\n2 test/running_test.exs\n5 test/other_shard_test.exs\n"
    )

    logs = Path.join(dir, "letflow_test_parallel.fixture")
    File.mkdir_p!(logs)
    File.write!(Path.join(logs, "partition-1.log"), "Result: 1 passed\n")
    File.write!(Path.join(logs, "partition-2.log"), "still running\n")

    {out, status} =
      System.cmd(
        "python3",
        [
          "-I",
          "-B",
          "scripts/ci_job_deadline.py",
          "--",
          "python3",
          "-I",
          "-c",
          "import signal; signal.pause()"
        ],
        cd: @root,
        stderr_to_stdout: true,
        env: [
          {"CI_JOB_DEADLINE_S", to_string(System.os_time(:second) + 2)},
          {"CI_JOB_LABEL", "Backend shard 1/8"},
          {"CI_JOB_LIMIT_MINUTES", "10"},
          {"TEST_PARALLEL_PLAN", plan},
          {"TEST_PARALLEL_SHARD", "1/8"},
          {"TEST_PARALLEL_N", "4"},
          {"TMPDIR", dir},
          {"GITHUB_STEP_SUMMARY", Path.join(dir, "summary.md")}
        ]
      )

    assert status == 124, out
    assert out =~ "Backend shard 1/8"
    assert out =~ "600 s job limit"
    assert out =~ "test/running_test.exs"
    refute out =~ "test/finished_test.exs"
    refute out =~ "test/other_shard_test.exs"
    assert File.read!(Path.join(dir, "summary.md")) =~ "test/running_test.exs"
  end

  @long_jobs ~w(backend_static backend_shard frontend mobile)

  test "R2b: every long job records its deadline and runs its long steps under the wrapper" do
    workflow = YamlElixir.read_from_file!(@ci_yml)
    # a custom workflow-wide shell template is not honoured with single quotes by the runner
    refute Map.has_key?(workflow, "defaults")
    jobs = Map.fetch!(workflow, "jobs")

    for job <- @long_jobs do
      steps = jobs[job]["steps"]
      record = Enum.find(steps, &(&1["name"] == "Record job deadline"))
      assert record["shell"] == "bash", job
      assert record["run"] =~ "CI_JOB_DEADLINE_S", job
      assert record["run"] =~ "* 60 - 45", job
      assert Enum.find_index(steps, &(&1 == record)) == 0, job

      wrapped = Enum.filter(steps, &((&1["run"] || "") =~ "ci_job_deadline.py\" -- "))
      assert wrapped != [], job
    end

    shard = Enum.find(jobs["backend_shard"]["steps"], &(&1["name"] == "Run test shard"))
    assert shard["run"] =~ "ci_job_deadline.py\" -- mix letflow.check.test --shard"
    assert shard["env"]["TEST_PARALLEL_SHARD"] =~ "matrix.shard"

    front = Enum.find(jobs["frontend"]["steps"], &(&1["name"] == "Run frontend gate"))
    assert front["run"] =~ "-- npm run check"
  end

  @tag :tmp_dir
  test "R2c: the wrapped command runs from web, passes success and keeps failure codes",
       %{tmp_dir: dir} do
    # the exact prefix the workflow uses, run from the `web` working directory
    prefix = ~s(python3 -I -B "$GITHUB_WORKSPACE/scripts/ci_job_deadline.py" --)

    for {cmd, status} <- [{"echo completed", 0}, {"exit 7", 7}] do
      {out, actual} =
        System.cmd("bash", ["-c", prefix <> " bash -c '" <> cmd <> "'"],
          cd: Path.join(@root, "web"),
          stderr_to_stdout: true,
          env: [
            {"GITHUB_WORKSPACE", @root},
            {"CI_JOB_DEADLINE_S", to_string(System.os_time(:second) + 30)},
            {"TMPDIR", dir}
          ]
        )

      assert actual == status, out
    end

    # refusing an unbounded step: no deadline, no run
    {_out, status} =
      System.cmd("python3", ["-I", "-B", "scripts/ci_job_deadline.py", "--", "true"],
        cd: @root,
        stderr_to_stdout: true,
        env: [{"CI_JOB_DEADLINE_S", ""}]
      )

    assert status != 0
  end

  test "R3: a timed-out shard fails the required gate without setting a queue-wide marker" do
    jobs = @ci_yml |> YamlElixir.read_from_file!() |> Map.fetch!("jobs")

    aggregate =
      Enum.find(jobs["backend"]["steps"], &(&1["name"] == "Aggregate backend legs (fail closed)"))

    for result <- ["failure", "cancelled"] do
      {out, status} =
        System.cmd("bash", ["-c", aggregate["run"]],
          cd: @root,
          stderr_to_stdout: true,
          env: [
            {"FILTER", "true"},
            {"CHANGES", "success"},
            {"STATIC", "success"},
            {"SHARDS", result},
            {"MODE", "selective"},
            {"REASON", "timeout regression"},
            {"GITHUB_STEP_SUMMARY", "/dev/null"}
          ]
        )

      assert status == 1, out
    end

    assert jobs["full_run_marker"]["if"] =~ "github.event_name != 'merge_group'"
    assert jobs["backend"]["if"] == "${{ always() }}"
  end

  test "every standard shard requires a bounded plan including docs changes" do
    steps = @ci_yml |> YamlElixir.read_from_file!() |> get_in(["jobs", "backend_shard", "steps"])
    shard = Enum.find(steps, &(&1["name"] == "Run test shard"))
    assert shard["run"] =~ "standard shard requires a nonempty bounded plan"
    assert shard["run"] =~ "schedule|workflow_dispatch) ;;"
    refute shard["if"] =~ "docs_only"
    refute Enum.any?(steps, &(&1["name"] == "Run docs tests (docs-only change)"))
  end
end
