defmodule Letflow.Scripts.CheckRealmRolesTest do
  @moduledoc """
  `scripts/check_realm_roles.py` fails when a realm export lacks a required realm role
  (T-1862: STOREKEEPER was missing in the bpm-default template). File-only: no Keycloak.
  Also pins the script's role list against `Authorization.roles/0`, so a new built-in role
  forces a decision (required, optional or platform-only) here and in the runbook.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Api.Authorization

  @script Path.expand("../../scripts/check_realm_roles.py", __DIR__)
  @runbook Path.expand("../../docs/runbooks/onboarding-new-tenant-realm.md", __DIR__)
  @demo_dir Path.expand("../../docs/runbooks/demo-realm", __DIR__)

  @tenant_required ~w(TENANT_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER CANDIDATE TENANT_AUDITOR STOREKEEPER)
  @optional ~w(AGENT_RUNNER)
  @platform_only ~w(PLATFORM_ADMIN)

  defp run(args), do: System.cmd("python3", ["-I", "-B", @script | args], stderr_to_stdout: true)

  defp realm_file(names) do
    path =
      Path.join(System.tmp_dir!(), "t1862_realm_#{System.unique_integer([:positive])}.json")

    json = Jason.encode!(%{"roles" => %{"realm" => Enum.map(names, &%{"name" => &1})}})
    File.write!(path, json)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "the committed demo realm fixtures carry every required role" do
    assert Path.wildcard(Path.join(@demo_dir, "*.json")) != []
    {out, code} = run([])
    assert code == 0, out
  end

  test "a realm without STOREKEEPER fails and names it" do
    path = realm_file(@tenant_required -- ["STOREKEEPER"])
    {out, code} = run([path])
    assert code == 1
    assert out =~ "missing realm roles: STOREKEEPER"
  end

  test "a complete tenant realm passes, AGENT_RUNNER is optional" do
    {out, code} = run([realm_file(@tenant_required)])
    assert code == 0, out
  end

  test "--platform also requires PLATFORM_ADMIN" do
    path = realm_file(@tenant_required)
    {out, code} = run(["--platform", path])
    assert code == 1
    assert out =~ "PLATFORM_ADMIN"
    {_, 0} = run(["--platform", realm_file(@tenant_required ++ @platform_only)])
  end

  test "an unreadable export is refused with exit 2" do
    {_out, code} = run([realm_file([]) <> ".nope"])
    assert code == 2
  end

  test "every built-in role is classified, and the runbook names each one" do
    classified = @tenant_required ++ @optional ++ @platform_only
    builtin = Authorization.roles() |> Enum.map(&Atom.to_string/1)
    assert Enum.sort(classified) == Enum.sort(builtin)

    runbook = File.read!(@runbook)
    for role <- builtin, do: assert(runbook =~ role, "runbook does not name #{role}")
    assert runbook =~ "Realm roles a tenant realm must carry"
  end
end
