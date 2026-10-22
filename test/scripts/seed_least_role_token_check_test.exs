defmodule Letflow.Scripts.SeedLeastRoleTokenCheckTest do
  @moduledoc """
  REQ-454: each seed script checks, before its first write, that QA_AUTH_TOKEN holds the
  permissions its calls need (GET /api/v1/me/access, REQ-449). A token without one exits 1
  naming that permission and changes nothing: the only call logged is the access check.

  Runs the real scripts against a stub `curl` on PATH (no network, no DB). The stub answers
  GET .../me/access with the permissions in STUB_ACCESS and every other call with an empty
  body, and logs "METHOD URL" per call.
  """
  use ExUnit.Case, async: true

  @curl_stub ~S"""
  #!/usr/bin/env bash
  method=GET; url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -H|-o|-w|-d|--data-binary|--data-ascii) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  echo "$method $url" >> "$STUB_LOG"
  case "$method $url" in
    "GET "*"/api/v1/me/access") printf '%s' "$STUB_ACCESS" ;;
    *) printf '{"items":[]}' ;;
  esac
  """

  @designer_only ~s({"permissions":["DefinitionsRead","DefinitionsWrite"]})
  @task_worker_only ~s({"permissions":["InstancesStart","TasksRead","TasksComplete"]})

  defp bash, do: System.get_env("UAT_PF_BASH") || System.find_executable("bash")

  defp tools_available?, do: bash() != nil and System.find_executable("jq") != nil

  # Runs `script` with a stub curl; returns {output, exit status, logged calls}.
  defp run(script, access, extra_env \\ []) do
    dir = Path.join(System.tmp_dir!(), "req454-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    stub = Path.join(dir, "curl")
    File.write!(stub, @curl_stub)
    File.chmod!(stub, 0o755)
    log = Path.join(dir, "calls.log")

    {out, status} =
      System.cmd(bash(), [script],
        env:
          [
            {"PATH", dir <> path_sep() <> System.get_env("PATH")},
            {"QA_AUTH_TOKEN", "tok"},
            {"QA_URL", "http://stub"},
            {"STUB_LOG", log},
            {"STUB_ACCESS", access}
          ] ++ extra_env,
        stderr_to_stdout: true
      )

    calls = if File.exists?(log), do: File.read!(log), else: ""
    {out, status, calls}
  end

  defp path_sep, do: if(match?({:win32, _}, :os.type()), do: ";", else: ":")

  defp only_access_check?(calls) do
    lines = String.split(calls, "\n", trim: true)
    lines != [] and Enum.all?(lines, &(&1 == "GET http://stub/api/v1/me/access"))
  end

  test "persona seed without UsersGroupsRolesManage exits 1 naming it, before any write" do
    if tools_available?() do
      {out, status, calls} =
        run("scripts/seed_meridian_persona_actors.sh", @designer_only)

      assert status == 1

      assert out =~
               "QA_AUTH_TOKEN lacks the UsersGroupsRolesManage permission (least role: TENANT_ADMIN)"

      assert out =~ "Nothing was changed"
      assert only_access_check?(calls), calls
    end
  end

  test "persona seed names RolesManage when only the group permission is held" do
    if tools_available?() do
      {out, status, calls} =
        run(
          "scripts/seed_vortex_persona_actors.sh",
          ~s({"permissions":["UsersGroupsRolesManage"]})
        )

      assert status == 1
      assert out =~ "QA_AUTH_TOKEN lacks the RolesManage permission"
      assert only_access_check?(calls), calls
    end
  end

  test "persona seed with TENANT_ADMIN permissions passes the check and starts its work" do
    if tools_available?() do
      {out, _status, calls} =
        run(
          "scripts/seed_swiftroute_persona_actors.sh",
          ~s({"permissions":["RolesManage","UsersGroupsRolesManage"]})
        )

      refute out =~ "lacks"
      assert out =~ "--- Step 1: Resolve TASK_WORKER group ---"
      assert calls =~ "GET http://stub/api/v1/identity/roles"
    end
  end

  test "definition deploy with a TASK_WORKER token exits 1 naming DefinitionsRead, no write" do
    if tools_available?() do
      {out, status, calls} =
        run("scripts/seed_meridian_definition.sh", @task_worker_only)

      assert status == 1

      assert out =~
               "QA_AUTH_TOKEN lacks the DefinitionsRead permission (least role: PROCESS_DESIGNER)"

      refute calls =~ ~r/^POST /m
      assert only_access_check?(calls), calls
    end
  end

  test "definition deploy names DefinitionsWrite when the token can only read" do
    if tools_available?() do
      {out, status, calls} =
        run(
          "scripts/seed_vortex_definition.sh",
          ~s({"permissions":["DefinitionsRead"]})
        )

      assert status == 1

      assert out =~
               "QA_AUTH_TOKEN lacks the DefinitionsWrite permission (least role: PROCESS_DESIGNER)"

      refute calls =~ ~r/^POST /m
    end
  end

  test "vortex entity seed names the missing entity permission before any write" do
    if tools_available?() do
      {out, status, calls} =
        run(
          "scripts/seed_vortex_entities.sh",
          ~s({"permissions":["EntitiesDefinitionsWrite","UsersGroupsRolesManage","EntitiesRestrictionsManage"]}),
          [{"SEED_ACTOR_USERNAME", "seeder-svc"}]
        )

      assert status == 1

      assert out =~
               "QA_AUTH_TOKEN lacks the EntitiesRecordsImport permission (least role: TENANT_ADMIN)"

      refute calls =~ ~r/^POST /m
      assert only_access_check?(calls), calls
    end
  end
end
