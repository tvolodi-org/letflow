defmodule Letflow.CiDownloadRetryTest do
  @moduledoc """
  T-2224: `scripts/ci_job_deadline.py --retry-downloads` re-runs a dependency-download step
  once, only when its output matches a download/network flake pattern; a real failure is
  never retried, the retry is logged and counted in the step summary.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../..", __DIR__)
  @ci_yml Path.join(@root, ".github/workflows/ci.yml")

  # Fake command: fails on its first run with `msg`, succeeds on the second; counts runs.
  defp fake(dir, msg, always_fail \\ false) do
    count = Path.join(dir, "count")
    script = Path.join(dir, "fake.sh")

    File.write!(script, """
    echo run >> "#{count}"
    if [ "#{always_fail}" = "true" ] || [ "$(wc -l < "#{count}")" -lt 2 ]; then
      echo "#{msg}"
      exit 3
    fi
    echo fine
    """)

    {script, count}
  end

  defp run(dir, script, extra \\ ["--retry-downloads"]) do
    summary = Path.join(dir, "summary.md")

    {out, status} =
      System.cmd(
        "python3",
        ["-I", "-B", "scripts/ci_job_deadline.py"] ++ extra ++ ["--", "bash", script],
        cd: @root,
        stderr_to_stdout: true,
        env: [
          {"CI_JOB_DEADLINE_S", to_string(System.os_time(:second) + 300)},
          {"CI_RETRY_PAUSE_S", "0"},
          {"CI_RETRY_MIN_REMAINING_S", "1"},
          {"GITHUB_STEP_SUMMARY", summary},
          {"TMPDIR", dir}
        ]
      )

    {out, status, if(File.exists?(summary), do: File.read!(summary), else: "")}
  end

  defp runs(count), do: count |> File.read!() |> String.split("\n", trim: true) |> length()

  @tag :tmp_dir
  test "a download flake is retried once, visibly, and counted in the summary", %{tmp_dir: dir} do
    {script, count} = fake(dir, "Could not GET 'https://plugins.gradle.org/x.pom'")
    {out, status, summary} = run(dir, script)
    assert status == 0, out
    assert runs(count) == 2
    assert out =~ "retry 1/1: Could not GET"
    assert summary =~ "retry 1/1: Could not GET"
  end

  @tag :tmp_dir
  test "a flake that persists is retried only once", %{tmp_dir: dir} do
    {script, count} = fake(dir, "npm ERR! code ECONNRESET", true)
    {_out, status, _} = run(dir, script)
    assert status == 3
    assert runs(count) == 2
  end

  @tag :tmp_dir
  test "a real failure is not retried", %{tmp_dir: dir} do
    {script, count} = fake(dir, "lib/a.ex:3: error: undefined function foo/0")
    {out, status, summary} = run(dir, script)
    assert status == 3
    assert runs(count) == 1
    refute out =~ "retry 1/1"
    refute summary =~ "retry 1/1"
  end

  @tag :tmp_dir
  test "without the flag a flake is not retried", %{tmp_dir: dir} do
    {script, count} = fake(dir, "Could not resolve org.jetbrains.kotlin:x")
    {_out, status, _} = run(dir, script, [])
    assert status == 3
    assert runs(count) == 1
  end

  @tag :tmp_dir
  test "no retry when the pause would not leave time inside the job limit", %{tmp_dir: dir} do
    {script, count} = fake(dir, "Could not resolve x")

    {_out, status} =
      System.cmd(
        "python3",
        ["-I", "-B", "scripts/ci_job_deadline.py", "--retry-downloads", "--", "bash", script],
        cd: @root,
        stderr_to_stdout: true,
        env: [
          {"CI_JOB_DEADLINE_S", to_string(System.os_time(:second) + 30)},
          {"CI_RETRY_PAUSE_S", "0"},
          {"CI_RETRY_MIN_REMAINING_S", "3600"}
        ]
      )

    assert status == 3
    assert runs(count) == 1
  end

  test "workflow: download steps use the retry flag, test and compile steps do not" do
    jobs = @ci_yml |> YamlElixir.read_from_file!() |> Map.fetch!("jobs")
    runs = for {_, j} <- jobs, s <- j["steps"] || [], is_binary(s["run"]), do: s["run"]

    flagged = Enum.filter(runs, &(&1 =~ "--retry-downloads"))

    for cmd <- ["mix deps.get", "npm ci", "flutter pub get", "flutter build apk --debug"] do
      assert Enum.any?(flagged, &(&1 =~ "-- " <> cmd)), cmd
    end

    for r <- flagged do
      refute r =~ "mix letflow.check", r
      refute r =~ "flutter test", r
      refute r =~ "npm run check", r
    end
  end
end
