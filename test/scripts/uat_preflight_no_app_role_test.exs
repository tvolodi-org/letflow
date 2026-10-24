defmodule Letflow.Scripts.UatPreflightNoAppRoleTest do
  @moduledoc """
  GH #3112: in `scripts/uat_preflight.sh`, a `qa-uat-env` token whose `GET /api/v1/me/modules`
  answers 403 (token accepted, no app role resolved) is NO_APP_ROLE owned by the tenant's role
  bindings, not BAD_CRED owned by the Keycloak users; 401 stays BAD_CRED, 200 stays OK.

  Shells out to the real script against a stub HTTP server answering every GET with a scripted
  status. Needs a real `bash` and `python3` (`UAT_PF_BASH` on Windows, see the bare-JWT test).
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @jwt "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl"
  @actor "actor-swiftroute-lena"

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  defp run_preflight(tmp, status) do
    base_url = start_stub(status)
    File.mkdir_p!(Path.join(tmp, "scenarios/swiftroute"))

    File.write!(Path.join(tmp, "scenarios/swiftroute/t.yaml"), """
    id: t
    company_id: swiftroute
    actors:
      dispatcher: #{@actor}
    """)

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
      "--sha",
      "deadbeef",
      "--idp-url",
      base_url,
      "--out",
      Path.join(tmp, "out.json")
    ]

    {out, _} = System.cmd(launcher(), args, stderr_to_stdout: true)

    assert out =~ "UAT PREFLIGHT  environment=qa",
           "preflight did not reach its report: #{String.slice(out, 0, 500)}"

    out
  end

  defp start_stub(status) do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    pid = spawn_link(fn -> accept_loop(lsock, status) end)

    on_exit(fn ->
      :gen_tcp.close(lsock)
      Process.unlink(pid)
      Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_loop(lsock, status) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn(fn -> serve(sock, status, "") end)
        accept_loop(lsock, status)

      {:error, _} ->
        :ok
    end
  end

  defp serve(sock, status, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      :gen_tcp.send(
        sock,
        "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
      )

      :gen_tcp.close(sock)
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> serve(sock, status, acc <> data)
        {:error, _} -> :gen_tcp.close(sock)
      end
    end
  end

  test "N1: 403 on me/modules is NO_APP_ROLE, owned by role bindings", %{tmp_dir: tmp} do
    out = run_preflight(tmp, 403)
    assert out =~ "#{@actor}@swiftroute=NO_APP_ROLE"
    assert out =~ "authenticated, but Letflow resolves no role for this user in tenant swiftroute"
    assert out =~ "platform-role bindings (RoleBackfill)"
    assert out =~ "owner: letflow (tenant role bindings"
    refute out =~ "BAD_CRED"
    refute out =~ "Keycloak users"
    assert out =~ "RESULT: ENV_NOT_READY"
  end

  test "N2: 401 on me/modules stays BAD_CRED", %{tmp_dir: tmp} do
    out = run_preflight(tmp, 401)
    assert out =~ "#{@actor}@swiftroute=BAD_CRED"
    assert out =~ "login failed: #{@actor}(BAD_CRED)"
    assert out =~ "Keycloak users"
    refute out =~ "NO_APP_ROLE"
    assert out =~ "RESULT: ENV_NOT_READY"
  end

  test "N3: 200 on me/modules logs in, no failure states", %{tmp_dir: tmp} do
    out = run_preflight(tmp, 200)
    assert out =~ "#{@actor}@swiftroute=OK"
    refute out =~ "NO_APP_ROLE"
    refute out =~ "BAD_CRED"
  end
end
