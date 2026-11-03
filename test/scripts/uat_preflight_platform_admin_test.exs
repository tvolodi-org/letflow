defmodule Letflow.Scripts.UatPreflightPlatformAdminTest do
  @moduledoc """
  ISS-0997 regression: under the `qa-uat-env` credential protocol `scripts/uat_preflight.sh`
  must resolve `actor-platform-admin` to the seeded `admin-user` account (the roster used
  to be built from scenario actor ids only, so `admin-user` was never found: "no valid
  PLATFORM_ADMIN token" and "no seeded user: actor-platform-admin"). The `qa-login`
  protocol (roster from the source's own listing) must behave as before.

  Shells out to the real script with a fake credential source; same harness conventions
  as `uat_preflight_bare_jwt_test.exs` (needs bash + python; set `UAT_PF_BASH` to git-bash
  on Windows). Spec: test/specs/ISS-0997.md.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  @moduletag :tmp_dir

  @jwt "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl"

  defp launcher, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

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

  # Scenario with only an `actor-platform-admin` actor. `cred_body` is the fake credential
  # source script body. Returns the script's combined output.
  defp run_preflight(tmp, protocol, cred_body, actor \\ "actor-platform-admin") do
    File.mkdir_p!(Path.join(tmp, "scenarios/swiftroute"))

    File.write!(Path.join(tmp, "scenarios/swiftroute/t.yaml"), """
    id: t
    company_id: swiftroute
    actors:
      admin: #{actor}
    """)

    cred = Path.join(tmp, "cred.sh")
    File.write!(cred, "#!/bin/bash\n" <> cred_body)
    base = start_stub()

    args = [
      "scripts/uat_preflight.sh",
      "--base-url",
      base,
      "--environment",
      "qa",
      "--credential-source",
      cred,
      "--credential-protocol",
      protocol,
      "--scenarios",
      Path.join(tmp, "scenarios"),
      "--sha",
      "deadbeef",
      "--idp-url",
      base,
      "--out",
      Path.join(tmp, "out.json")
    ]

    {out, _} = System.cmd(launcher(), args, stderr_to_stdout: true)

    assert out =~ "UAT PREFLIGHT  environment=qa",
           "preflight script did not reach its report (launcher=#{inspect(launcher())}). " <>
             "First 500 chars: #{String.slice(out, 0, 500)}. Set UAT_PF_BASH to git-bash."

    out
  end

  test "qa-uat-env: actor-platform-admin resolves to admin-user and an admin token is found",
       %{tmp_dir: tmp} do
    calls = Path.join(tmp, "calls.log")

    out =
      run_preflight(tmp, "qa-uat-env", """
      echo "$@" >> '#{calls}'
      if [ "$1" = "token" ] && [ "$2" = "admin-user" ]; then
        echo "noise on stderr" >&2
        printf '%s\n' '#{@jwt}'
      fi
      """)

    refute out =~ "no seeded user: actor-platform-admin"
    refute out =~ "no valid PLATFORM_ADMIN token"
    refute out =~ "login failed"
    assert out =~ "credential validity   : actor-platform-admin@"
    assert out =~ "=OK"
    assert File.read!(calls) =~ "token admin-user"
    refute out =~ @jwt
  end

  test "qa-uat-env: a corpus with no login actors still errors (empty-roster semantics kept)",
       %{tmp_dir: tmp} do
    File.mkdir_p!(Path.join(tmp, "scenarios/swiftroute"))

    File.write!(
      Path.join(tmp, "scenarios/swiftroute/t.yaml"),
      "id: t\ncompany_id: swiftroute\nactors:\n  s: actor-system-x\n"
    )

    cred = Path.join(tmp, "cred.sh")
    File.write!(cred, "#!/bin/bash\nexit 0\n")
    base = start_stub()

    {out, _} =
      System.cmd(
        launcher(),
        ~w(scripts/uat_preflight.sh --base-url #{base} --environment qa --credential-source #{cred}
           --credential-protocol qa-uat-env --scenarios #{Path.join(tmp, "scenarios")} --sha deadbeef
           --idp-url #{base} --out #{Path.join(tmp, "out.json")}),
        stderr_to_stdout: true
      )

    assert out =~ "no login actors declared by the scenario corpus"
  end

  test "qa-login: an actor-<x>-admin without its own account does NOT fall back to admin-user",
       %{tmp_dir: tmp} do
    # The prefix fallback would map nm = "admin" onto admin-user (a PLATFORM_ADMIN account):
    # a silent privilege substitution. It must report "no seeded user" instead.
    out =
      run_preflight(
        tmp,
        "qa-login",
        """
        if [ -z "$1" ]; then
          echo "Seeded users:"
          echo "  admin-user  password: x"
        fi
        """,
        "actor-foo-admin"
      )

    assert out =~ "no seeded user: actor-foo-admin"
    refute out =~ "login failed"
  end

  test "qa-login: roster comes from the source listing only (unchanged)", %{tmp_dir: tmp} do
    # Listing has no admin-user: the old behaviour (GAP: no seeded user) must remain.
    out =
      run_preflight(tmp, "qa-login", """
      if [ -z "$1" ]; then
        echo "Seeded users:"
        echo "  lena-dispatcher  password: x"
      fi
      """)

    assert out =~ "no seeded user: actor-platform-admin"
    refute out =~ "admin-user"
  end
end
