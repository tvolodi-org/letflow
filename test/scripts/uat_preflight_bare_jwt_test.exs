defmodule Letflow.Scripts.UatPreflightBareJwtTest do
  @moduledoc """
  ISS-0936 regression: `scripts/uat_preflight.sh`'s `qa-uat-env` credential protocol
  must accept a BARE JWT line (what ai-dala-infra's `qa-uat-env.sh token <user>`
  really prints) as well as the labelled `Token: <jwt>` form, while ignoring noise
  lines (warnings, hostnames, banners) and never echoing the token.

  Shells out to the real script (no re-implementation of the parser). Needs a real
  `bash` and `python3`; on Windows set `UAT_PF_BASH` to git-bash (the default `bash`
  there is the WSL stub). Design: lib/letflow/design/iss0936-uat-preflight-bare-jwt.md
  section 6. Spec: test/specs/ISS-0936.md.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  # NOTE: test names feed the tmp_dir path, which the script echoes in its report;
  # keep them free of the forbidden substrings (NO_PASSWORD / BAD_CRED) asserted below.
  @moduletag :tmp_dir

  # Fake JWT: 49 chars (20 + 1 + 15 + 1 + 12), passes the script's >= 40 floor.
  @jwt "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl"
  @first_segment "eyJhbGciOiJSUzI1NiJ9"
  @actor "actor-swiftroute-lena"
  @dead_url "http://127.0.0.1:9"

  # ---------------------------------------------------------------- helpers

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  # Runs the real script against a fake qa-uat-env credential source whose stdout for
  # `token <user>` is `lines` (one per line, CRLF-terminated when `crlf: true`).
  # Returns {combined_output, out_json_text}.
  defp run_preflight(tmp, opts) do
    lines = Keyword.fetch!(opts, :lines)
    base_url = Keyword.fetch!(opts, :base_url)
    crlf = Keyword.fetch!(opts, :crlf)

    File.mkdir_p!(Path.join(tmp, "scenarios/swiftroute"))

    File.write!(Path.join(tmp, "scenarios/swiftroute/t.yaml"), """
    id: t
    company_id: swiftroute
    actors:
      dispatcher: #{@actor}
    """)

    term = if crlf, do: "\r\n", else: "\n"

    printfs =
      Enum.map_join(lines, "\n", fn l -> "  printf '%s#{term}' '#{l}'" end)

    cred = Path.join(tmp, "cred.sh")

    File.write!(cred, """
    #!/bin/bash
    if [ "$1" = "token" ]; then
      echo "noise on stderr" >&2
    #{printfs}
    fi
    """)

    out_json = Path.join(tmp, "out.json")

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
      "--sha",
      "deadbeef",
      "--idp-url",
      base_url,
      "--out",
      out_json
    ]

    {out, _status} = System.cmd(launcher(), args, stderr_to_stdout: true)

    assert out =~ "UAT PREFLIGHT  environment=qa",
           "preflight script did not reach its report (launcher=#{inspect(launcher())}). " <>
             "First 500 chars of output: #{String.slice(out, 0, 500)}. " <>
             "Set UAT_PF_BASH to a real bash (git-bash on Windows)."

    {out, if(File.exists?(out_json), do: File.read!(out_json), else: "")}
  end

  defp run_dead(tmp, lines, crlf),
    do: run_preflight(tmp, lines: lines, base_url: @dead_url, crlf: crlf)

  # Stub HTTP server answering every GET with 200 `{}`; returns its base URL.
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
        spawn(fn -> serve(sock) end)
        accept_loop(lsock)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock) do
    _ = read_request(sock, "")

    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
    )

    :gen_tcp.close(sock)
  end

  defp read_request(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> read_request(sock, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  # ------------------------------------------------------------------ tests

  test "T1: bare JWT after a noise line is accepted and reaches verification",
       %{tmp_dir: tmp} do
    {out, _} = run_dead(tmp, ["WARN something", @jwt], false)
    assert out =~ "login failed: #{@actor}(BAD_CRED)"
    assert out =~ "#{@actor}@swiftroute=BAD_CRED"
    refute out =~ "NO_PASSWORD"
  end

  test "T2: labelled `Token: <jwt>` form still works", %{tmp_dir: tmp} do
    {out, _} = run_dead(tmp, ["Token: " <> @jwt], false)
    assert out =~ "#{@actor}@swiftroute=BAD_CRED"
    refute out =~ "NO_PASSWORD"
  end

  test "T3: noise-only stdout yields no credential and no login attempt", %{tmp_dir: tmp} do
    {out, _} = run_dead(tmp, ["WARN something", "Logged in as lena.x.y"], false)
    assert out =~ "login failed: #{@actor}(NO_PASSWORD)"
    assert out =~ "credential validity   : none checked"
    refute out =~ "BAD_CRED"
  end

  test "T4: dotted non-JWT lines (hostnames, short lookalike) are not mistaken for a JWT",
       %{tmp_dir: tmp} do
    # The last two each defeat exactly one of the two guards: a >= 40 char hostname
    # (no `eyJ` prefix) and a short `eyJ`-prefixed three-segment string (< 40 chars).
    for host <- [
          "auth.qa.bizdala.com",
          "qa.bizdala.com",
          "auth-service-qa-environment.bizdala-platform.com",
          "eyJh.a.b"
        ] do
      {out, _} = run_dead(tmp, [host], false)
      assert out =~ "login failed: #{@actor}(NO_PASSWORD)", "host #{host}"
      refute out =~ "BAD_CRED", "host #{host}"
    end
  end

  test "T5: a CRLF-terminated bare JWT is accepted", %{tmp_dir: tmp} do
    {out, _} = run_dead(tmp, [@jwt], true)
    assert out =~ "#{@actor}@swiftroute=BAD_CRED"
    refute out =~ "NO_PASSWORD"
  end

  test "T5b: a bare JWT surrounded by spaces is accepted (whitespace stripped)", %{tmp_dir: tmp} do
    {out, _} = run_dead(tmp, ["  " <> @jwt <> "  "], false)
    assert out =~ "#{@actor}@swiftroute=BAD_CRED"
    refute out =~ "NO_PASSWORD"
  end

  test "T6: the token is never echoed to output or the --out JSON", %{tmp_dir: tmp} do
    {out, json} = run_dead(tmp, ["WARN something", @jwt], false)
    # Guard against a vacuous pass: the token really was consumed.
    assert out =~ "#{@actor}@swiftroute=BAD_CRED"
    assert json != ""
    refute out =~ @jwt
    refute out =~ @first_segment
    refute json =~ @jwt
    refute json =~ @first_segment
  end

  test "T7: a bare JWT is verified end to end against a stub API (OK)", %{tmp_dir: tmp} do
    base = start_stub()
    {out, _} = run_preflight(tmp, lines: [@jwt], base_url: base, crlf: false)
    # ISS-0997: the admin-user login now also appears in this list, so match the actor entry only.
    assert out =~ "#{@actor}@swiftroute=OK"
    refute out =~ "login failed"
    refute out =~ "NO_PASSWORD"
    refute out =~ "BAD_CRED"
  end
end
