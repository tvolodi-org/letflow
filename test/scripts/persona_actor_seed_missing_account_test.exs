defmodule Letflow.Scripts.PersonaActorSeedMissingAccountTest do
  @moduledoc """
  ISS-0932 (Q-932): a persona with no Keycloak account must not abort the seed
  before any membership is added. Runs the real vortex seed script against a
  stub `curl` on PATH (no network, no DB): `actor-vortex-dirk` has no account,
  every other persona does. Expected: warning names dirk, the other personas'
  memberships are still POSTed, and the script exits non-zero at the end.
  """
  use ExUnit.Case, async: true

  @script "scripts/seed_vortex_persona_actors.sh"

  @curl_stub ~S"""
  #!/usr/bin/env bash
  method=GET; url=""; wfmt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -w) wfmt="$2"; shift 2 ;;
      -H|-o|--data-ascii) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  echo "$method $url" >> "$STUB_LOG"
  case "$method $url" in
    "GET "*"/identity/roles") echo '{"items":[{"name":"TASK_WORKER","group_id":"g-tw"}]}' ;;
    "GET "*"/identity/groups") echo '{"items":[]}' ;;
    "POST "*"/identity/groups") echo '{"id":"g-new"}' ;;
    "POST "*"/identity/roles") echo '{"id":"r-new"}' ;;
    "GET "*"/identity/users?search=actor-vortex-dirk") echo '{"items":[]}' ;;
    "GET "*"/identity/users?search="*)
      name="${url##*search=}"; echo "{\"items\":[{\"username\":\"$name\",\"id\":\"u-$name\"}]}" ;;
    "POST "*"/members") [[ -n "$wfmt" ]] && printf 201 ;;
  esac
  """

  defp bash, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  test "missing persona is skipped with a warning, others are seeded, exit is non-zero" do
    if is_nil(bash()) or is_nil(System.find_executable("jq")) do
      IO.puts("skipping: bash or jq not available")
    else
      dir = Path.join(System.tmp_dir!(), "iss0932-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      stub = Path.join(dir, "curl")
      File.write!(stub, @curl_stub)
      File.chmod!(stub, 0o755)
      log = Path.join(dir, "calls.log")

      {out, status} =
        System.cmd(bash(), [@script],
          env: [
            {"PATH", dir <> path_sep() <> System.get_env("PATH")},
            {"QA_AUTH_TOKEN", "tok"},
            {"QA_URL", "http://stub"},
            {"STUB_LOG", log}
          ],
          stderr_to_stdout: true
        )

      assert status != 0
      assert out =~ "actor-vortex-dirk has no account"
      assert out =~ "skipped: actor-vortex-dirk"

      # GH 2345: the message says what to do, not only that Part A is missing.
      assert out =~ "first authenticated request"
      assert out =~ "sign in as actor-vortex-dirk"
      assert out =~ "GET http://stub/api/v1/me/memberships"

      assert out =~
               "QA_URL=http://stub QA_AUTH_TOKEN=<token> bash scripts/seed_vortex_persona_actors.sh"

      assert out =~ "already exist answer 200"

      calls = File.read!(log)

      member_posts =
        calls
        |> String.split("\n")
        |> Enum.filter(&(String.contains?(&1, "POST") and &1 =~ "/members"))

      # Derived from the seed script's own PERSONAS table: every persona except the one
      # without an account gets TASK_WORKER (implicit) plus one membership per held role.
      assert length(member_posts) == expected_member_posts("actor-vortex-dirk")
    end
  end

  defp expected_member_posts(missing_user) do
    lines = @script |> File.read!() |> String.split(~r{\r?\n})

    [_open | rest] = Enum.drop_while(lines, &(&1 != "PERSONAS=("))

    rest
    |> Enum.take_while(&(&1 != ")"))
    |> Enum.map(fn line ->
      [_, entry] = Regex.run(~r/^\s*"([^"]*)"\s*$/, line)
      entry
    end)
    |> Enum.map(&String.split(&1, "|", parts: 2))
    |> Enum.reject(fn [user, _roles] -> user == missing_user end)
    |> Enum.map(fn [_user, roles] -> 1 + length(String.split(roles, ",", trim: true)) end)
    |> Enum.sum()
  end

  defp path_sep, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")
end
