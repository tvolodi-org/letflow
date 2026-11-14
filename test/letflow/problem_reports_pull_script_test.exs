defmodule Letflow.ProblemReportsPullScriptTest do
  @moduledoc """
  T-1948 S1-S4: `scripts/problem_reports_pull.sh` (the forwarder's tool). No network: `render` and `ack`
  run on files; the token-mode check exits before any request.
  """

  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/problem_reports_pull.sh", __DIR__)

  @answer %{
    "reports" => [
      %{
        "number" => "SR-7",
        "received_at" => "2026-11-14T10:00:00Z",
        "reporter" => %{
          "tenant_id" => "t1",
          "tenant_name" => "Acme",
          "user_id" => "u1",
          "name" => "Ann",
          "roles" => ["TENANT_ADMIN", "X"],
          "permissions" => ["a", "b"]
        },
        "text" => "Line one\nLine two",
        "context" => %{
          "route" => "/admin/assets/documents",
          "ui_language" => "ru",
          "browser" => %{"user_agent" => "UA", "viewport" => "1440x900"},
          "crash" => %{"name" => "Err", "message" => "boom"},
          "actions" => [
            %{"at" => "t", "kind" => "click", "name" => "btn"},
            %{"at" => "t2", "kind" => "nav", "name" => "/x"}
          ],
          "requests" => [
            %{
              "method" => "GET",
              "path" => "/api/v1/tasks",
              "status" => 500,
              "trace_id" => "abc",
              "error_code" => "boom"
            }
          ]
        },
        "server_version" => "abc123",
        "trace_id" => "tr1"
      }
    ],
    "next_after" => 7
  }

  @golden """
  === Letflow problem report SR-7 (qa.example.org) received 2026-11-14T10:00:00Z ===
  From: Ann (user u1), company Acme (t1)
  Roles: TENANT_ADMIN, X   Permissions: 2
  Screen: /admin/assets/documents   Language: ru   Browser: UA 1440x900
  Server version: abc123   Report trace: tr1
  Text:
  Line one
  Line two
  Crash: Err: boom
  Last actions: t click btn; t2 nav /x
  Last requests:
    GET /api/v1/tasks -> 500 trace=abc code=boom

  NEXT_AFTER=7
  """

  @moduletag :tmp_dir

  defp run(args, env) do
    System.cmd("bash", [@script | args], env: env, stderr_to_stdout: true)
  end

  test "S1 the script parses", _ do
    assert {"", 0} = System.cmd("bash", ["-n", @script], stderr_to_stdout: true)
  end

  test "S2 render prints the block template exactly, then NEXT_AFTER", %{tmp_dir: dir} do
    file = Path.join(dir, "answer.json")
    File.write!(file, Jason.encode!(@answer))
    assert {out, 0} = run(["render", file], [{"LETFLOW_URL", "https://qa.example.org/"}])
    assert out == @golden

    empty = Path.join(dir, "empty.json")
    File.write!(empty, Jason.encode!(%{"reports" => [], "next_after" => 5}))
    assert {"NEXT_AFTER=5\n", 0} = run(["render", empty], [])
  end

  test "S2 REPORT_OUT_DIR writes one SR file per report and never overwrites", %{tmp_dir: dir} do
    file = Path.join(dir, "answer.json")
    File.write!(file, Jason.encode!(@answer))
    out_dir = Path.join(dir, "out")
    env = [{"REPORT_OUT_DIR", out_dir}, {"LETFLOW_URL", "https://qa.example.org"}]
    assert {"NEXT_AFTER=7\n", 0} = run(["render", file], env)
    target = Path.join(out_dir, "SR-7.md")
    assert File.read!(target) =~ "=== Letflow problem report SR-7"
    File.write!(target, "kept")
    assert {_, 0} = run(["render", file], env)
    assert File.read!(target) == "kept"
  end

  test "S3 ack moves the cursor forward only", %{tmp_dir: dir} do
    cursor = Path.join(dir, "state/cursor")
    env = [{"REPORT_CURSOR_FILE", cursor}]
    assert {_, 0} = run(["ack", "5"], env)
    assert String.trim(File.read!(cursor)) == "5"
    assert {_, 0} = run(["ack", "9"], env)
    assert {_, 2} = run(["ack", "3"], env)
    assert {_, 2} = run(["ack", "x1"], env)
    assert {_, 2} = run(["ack"], env)
    assert String.trim(File.read!(cursor)) == "9"
  end

  test "S4 a token file with mode 644 gives exit 2; the source never echoes the token", %{
    tmp_dir: dir
  } do
    token = Path.join(dir, "token")
    File.write!(token, "secret-value\n")
    File.chmod!(token, 0o644)

    env = [{"REPORT_EXPORT_TOKEN_FILE", token}, {"LETFLOW_URL", "https://qa.example.org"}]
    assert {out, 2} = run(["pull"], env)
    assert out =~ "mode 600"
    refute out =~ "secret-value"

    source = File.read!(@script)
    refute source =~ ~r/set -x|set -o xtrace/
    refute source =~ ~r/echo .*\$TOKEN|echo .*\$\(cat "\$TOKEN_FILE"\)/
  end
end
