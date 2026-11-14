defmodule Letflow.ProblemReportsRunbookTest do
  @moduledoc """
  T-1948 RB1: the handoff runbook names the channel, the token handling and who forwards, and the
  variable is listed in `deploy/.env.example` and read by `config/runtime.exs`.
  """

  use ExUnit.Case, async: true

  @runbook File.read!(Path.expand("../../docs/runbooks/problem-report-handoff.md", __DIR__))

  test "RB1 the runbook states the channel, token handling, forwarder and the public-issue rule" do
    for needle <- [
          "LETFLOW_PROBLEM_REPORT_EXPORT_SHA256",
          "scripts/problem_reports_pull.sh",
          "ack",
          "mode 600",
          "operator session",
          "Never into a GitHub issue"
        ] do
      assert @runbook =~ needle, "runbook lacks #{inspect(needle)}"
    end
  end

  test "RB1 the variable is in deploy/.env.example and read by runtime.exs" do
    example = File.read!(Path.expand("../../deploy/.env.example", __DIR__))
    assert example =~ "LETFLOW_PROBLEM_REPORT_EXPORT_SHA256="

    runtime = File.read!(Path.expand("../../config/runtime.exs", __DIR__))
    assert runtime =~ ~s|System.get_env("LETFLOW_PROBLEM_REPORT_EXPORT_SHA256")|
  end
end
