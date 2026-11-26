defmodule Letflow.CiJobDeadlineRunningStateTest do
  @moduledoc """
  T-2652: when a CI job runs into its deadline, the report must say WHAT WAS RUNNING,
  not only which test files were unfinished.

  Push CI run 45010058431 (Backend shard 3/8, 2026-11-22) burned its whole 2700 s job
  budget and was killed by the deadline with a report that listed 24 unfinished test
  files and nothing else: no partition number, no running file, no log lines. The shard
  had in fact hung in the create/migrate phase, before any partition had launched, so
  there was no partition log to read either -- the report has to say that too.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)

  @tag :tmp_dir
  test "the deadline report names the partition, the running file and the log tail", %{
    tmp_dir: dir
  } do
    plan = Path.join(dir, "plan.txt")
    File.write!(plan, "2 test/hanging_test.exs\n")

    logs = Path.join(dir, "letflow_test_parallel.fixture")
    File.mkdir_p!(Path.join(logs, "markers"))

    File.write!(
      Path.join(logs, "partition-2.log"),
      "some dots....\nthe last line before the hang\n"
    )

    File.write!(
      Path.join([logs, "markers", "current-2.txt"]),
      "file=test/letflow/hanging_test.exs\nmodule=Letflow.HangingTest\nstarted=100\nprogress=100\n" <>
        "tests=Letflow.HangingTest.test sleeps forever\n"
    )

    File.write!(Path.join(logs, "create-9.log"), "mix ecto.create ... still running\n")

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
          {"TMPDIR", dir}
        ]
      )

    assert status == 124, out

    # the unfinished file (the plan's own answer)
    assert out =~ "test/hanging_test.exs"

    # the partition number, the running file and the test names that had started
    assert out =~ "partition 2"
    assert out =~ "file=test/letflow/hanging_test.exs"
    assert out =~ "Letflow.HangingTest.test sleeps forever"

    # the last lines of the partition log
    assert out =~ "the last line before the hang"

    # a shard that hung before any partition launched still says so
    assert out =~ "create-9.log"
    assert out =~ "still running"
  end
end
