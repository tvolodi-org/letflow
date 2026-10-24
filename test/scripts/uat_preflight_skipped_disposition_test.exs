defmodule Letflow.Scripts.UatPreflightSkippedDispositionTest do
  @moduledoc """
  REQ-533 (Refs GH #3098): a `scenario-env-limitations` sidecar with `disposition: skipped` makes
  `scripts/uat_preflight.sh` report the scenario `env_limitation SKIP`, list it under
  `== SKIPPED SCENARIOS ==`, and leave it out of the GAP counts and the RESULT line. A sidecar
  without the field keeps reporting GAP; skipped plus `applies_to_expected_outcomes` exits non-zero.

  Shells out to the real script against a stub HTTP server (200 everywhere) with a fixture corpus
  of two scenarios whose `pipeline_test` does not exist (a spec GAP each) and a fixture sidecar dir
  (`--env-limitations`). Needs a real `bash` and `python3` (`UAT_PF_BASH` on Windows).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @jwt "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl"
  @actor "actor-swiftroute-lena"

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  defp sidecar(tmp, name, body) do
    dir = Path.join(tmp, "limits")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), body)
  end

  defp sidecar_body(extra, env \\ "qa") do
    """
    scenario_id: t-skip
    applies_to_environments: [#{env}]
    classification: UNBUILT_FEATURE
    reason: >
      The runtime-agent subsystem is not built.
    recorded_by: ELIXIR-DEV
    recorded_at: "2026-10-24"
    issue_ref: ISS-0890
    #{extra}
    """
  end

  defp run_preflight(tmp) do
    base_url = start_stub()
    File.mkdir_p!(Path.join(tmp, "limits"))
    File.mkdir_p!(Path.join(tmp, "scenarios/swiftroute"))

    for id <- ["t-skip", "t-other"] do
      File.write!(Path.join(tmp, "scenarios/swiftroute/#{id}.yaml"), """
      id: #{id}
      company_id: swiftroute
      pipeline_test: web/tests/e2e/pipelines/does-not-exist-#{id}.pipeline.e2e.spec.ts
      actors:
        dispatcher: #{@actor}
      """)
    end

    cred = Path.join(tmp, "cred.sh")

    File.write!(cred, """
    #!/bin/bash
    if [ "$1" = "token" ]; then
      printf '%s\n' '#{@jwt}'
    fi
    """)

    args = [
      "scripts/uat_preflight.sh",
      "--base-url",
      base_url,
      "--environment",
      "qa",
      "--credential-source",
      cred,
      "--credential-protocol",
      "qa-uat-env",
      "--scenarios",
      Path.join(tmp, "scenarios"),
      "--env-limitations",
      Path.join(tmp, "limits"),
      "--sha",
      "deadbeef",
      "--idp-url",
      base_url,
      "--out",
      Path.join(tmp, "out.json")
    ]

    System.cmd(launcher(), args, stderr_to_stdout: true)
  end

  defp gap_line(out), do: Regex.run(~r/scenarios with >=1 GAP: \d+ of \d+/, out) |> hd()
  defp checks_line(out), do: Regex.run(~r/checks: OK=\d+ GAP=\d+ UNKNOWN=\d+/, out) |> hd()

  defp start_stub do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    pid = spawn_link(fn -> accept_loop(lsock) end)

    on_exit(fn ->
      :gen_tcp.close(lsock)
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn(fn -> serve(sock, "") end)
        accept_loop(lsock)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
      )

      :gen_tcp.close(sock)
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> serve(sock, acc <> data)
        {:error, _} -> :gen_tcp.close(sock)
      end
    end
  end

  test "K1: skipped sidecar gives SKIP, a section, and GAP counts without that scenario",
       %{tmp_dir: tmp} do
    {base, _} = run_preflight(tmp)
    assert base =~ "scenarios with >=1 GAP: 2 of 2"
    refute base =~ "SKIPPED SCENARIOS"

    sidecar(tmp, "t-skip.yaml", sidecar_body("disposition: skipped"))
    {out, _} = run_preflight(tmp)

    assert out =~ "== SKIPPED SCENARIOS =="
    assert out =~ "t-skip  classification=UNBUILT_FEATURE  issue_ref=ISS-0890"
    assert out =~ "reason: The runtime-agent subsystem is not built."
    assert out =~ ~r/t-skip\s+.*SKIP/
    assert gap_line(out) == "scenarios with >=1 GAP: 1 of 2"
    refute out =~ "[GAP] t-skip/"
    assert out =~ "[SKIPPED/GAP] t-skip/spec"
    assert out =~ "[GAP] t-other/spec"
    assert out =~ "RESULT: ENV_NOT_READY"
    refute checks_line(out) == checks_line(base)
  end

  test "K2: a sidecar without disposition still reports GAP", %{tmp_dir: tmp} do
    sidecar(tmp, "t-skip.yaml", sidecar_body(""))
    {out, _} = run_preflight(tmp)

    refute out =~ "SKIPPED SCENARIOS"
    assert out =~ "[GAP] t-skip/env_limitation: UNBUILT_FEATURE: The runtime-agent subsystem"
    assert out =~ "environment-structural (permanent; issue_ref=ISS-0890)"
  end

  test "K3: skipped with applies_to_expected_outcomes exits non-zero naming the file",
       %{tmp_dir: tmp} do
    sidecar(
      tmp,
      "t-skip.yaml",
      sidecar_body("disposition: skipped\napplies_to_expected_outcomes: [EO-001]")
    )

    {out, status} = run_preflight(tmp)
    assert status != 0
    assert out =~ "t-skip.yaml"
    assert out =~ "disposition skipped cannot be combined with applies_to_expected_outcomes"
    refute out =~ "UAT PREFLIGHT  environment"
  end

  test "K4: a skipped sidecar for another environment is ignored", %{tmp_dir: tmp} do
    {base, _} = run_preflight(tmp)
    sidecar(tmp, "t-skip.yaml", sidecar_body("disposition: skipped", "staging"))
    {out, _} = run_preflight(tmp)

    refute out =~ "SKIPPED SCENARIOS"
    assert gap_line(out) == gap_line(base)
    assert checks_line(out) == checks_line(base)
  end
end
