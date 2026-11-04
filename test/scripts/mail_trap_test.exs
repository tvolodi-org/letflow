defmodule Letflow.Scripts.MailTrapTest do
  @moduledoc """
  T-1254 (D-088): `scripts/mail_trap.sh` reads UAT mail through the QA mail trap API. Run for real
  with a fake `curl` (`CURL` env), so no network is touched. Needs bash and python3.
  """
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :tmp_dir

  @script Path.expand("../../scripts/mail_trap.sh", __DIR__)
  @addr "invitee@uat.letflow.internal"

  defp fake_curl(dir) do
    path = Path.join(dir, "fake_curl.sh")

    File.write!(path, ~S"""
    #!/usr/bin/env bash
    echo "$*" >> "$FAKE_LOG"
    case "$*" in
      *"-X DELETE"*) printf '%s' '{}' ;;
      *"/api/v1/search"*) printf '%s' "$FAKE_SEARCH" ;;
      *"/api/v1/message/"*) printf '%s' "$FAKE_MESSAGE" ;;
      *) exit 7 ;;
    esac
    """)

    "bash " <> path
  end

  defp run(dir, args, env \\ %{}) do
    log = Path.join(dir, "requests.log")

    base = %{
      "CURL" => fake_curl(dir),
      "FAKE_LOG" => log,
      "FAKE_SEARCH" => ~s({"messages":[{"ID":"m1"}]}),
      "FAKE_MESSAGE" =>
        ~s({"Subject":"Reset password","Text":"See https://example.org/help then\\nhttps://auth.qa/realms/x/login-actions/action-token?key=abc&client_id=web\\n"})
    }

    {out, status} =
      System.cmd("bash", [@script | args],
        env: Map.to_list(Map.merge(base, env)),
        stderr_to_stdout: true
      )

    {out, status, if(File.exists?(log), do: File.read!(log), else: "")}
  end

  test "purge deletes all messages", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, ["purge"])
    assert status == 0
    assert out =~ "purged"
    assert requests =~ "-X DELETE"
    assert requests =~ "/api/v1/messages"
  end

  test "wait prints the action link, preferring it over other links", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, ["wait", @addr, "5"])
    assert status == 0

    assert String.trim(out) ==
             "https://auth.qa/realms/x/login-actions/action-token?key=abc&client_id=web"

    assert requests =~ "to:#{@addr}"
  end

  test "subject prints the subject", %{tmp_dir: dir} do
    {out, 0, _} = run(dir, ["subject", @addr, "5"])
    assert String.trim(out) == "Reset password"
  end

  test "times out with exit 1 when no mail arrives", %{tmp_dir: dir} do
    {out, status, _} = run(dir, ["wait", @addr, "0"], %{"FAKE_SEARCH" => ~s({"messages":[]})})
    assert status == 1
    assert out =~ "no mail to #{@addr}"
  end

  test "mail without a link exits 1", %{tmp_dir: dir} do
    {_, status, _} =
      run(dir, ["wait", @addr, "5"], %{"FAKE_MESSAGE" => ~s({"Subject":"x","Text":"no link"})})

    assert status == 1
  end

  test "refuses an address outside the trap domain before any request", %{tmp_dir: dir} do
    {out, status, requests} = run(dir, ["wait", "someone@gmail.com", "5"])
    assert status == 2
    assert out =~ "refused address"
    assert requests == ""
  end

  test "unreachable trap exits 3", %{tmp_dir: dir} do
    {_, status, _} = run(dir, ["purge"], %{"CURL" => "false"})
    assert status == 3
  end
end
