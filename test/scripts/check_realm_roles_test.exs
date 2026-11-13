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

  @required ~w(AGENT_RUNNER CANDIDATE PLATFORM_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR STOREKEEPER TASK_WORKER TENANT_ADMIN TENANT_AUDITOR)
  @template Path.expand("../../priv/keycloak/realms/bpm-default.json", __DIR__)

  defp run(args), do: System.cmd("python3", ["-I", "-B", @script | args], stderr_to_stdout: true)

  defp realm_names(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["roles", "realm"])
    |> Enum.map(& &1["name"])
  end

  defp realm_file(names) do
    path =
      Path.join(System.tmp_dir!(), "t1862_realm_#{System.unique_integer([:positive])}.json")

    json = Jason.encode!(%{"roles" => %{"realm" => Enum.map(names, &%{"name" => &1})}})
    File.write!(path, json)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "the committed fixtures (template and demo realms) carry all nine roles" do
    assert Path.wildcard(Path.join(@demo_dir, "*.json")) != []
    {out, code} = run([])
    assert code == 0, out
    assert out =~ "bpm-default.json: ok"
    assert out =~ "demo-platform.json: ok"
  end

  test "the template fixture without STOREKEEPER fails" do
    copy = realm_file(realm_names(@template) -- ["STOREKEEPER"])
    {out, code} = run([copy])
    assert code == 1
    assert out =~ "missing realm roles: STOREKEEPER"
    assert realm_names(@template) |> Enum.sort() == Enum.sort(@required)
  end

  test "a realm without STOREKEEPER fails and names it" do
    {out, code} = run([realm_file(@required -- ["STOREKEEPER"])])
    assert code == 1
    assert out =~ "missing realm roles: STOREKEEPER"
  end

  test "PLATFORM_ADMIN and AGENT_RUNNER are required too" do
    {out, code} = run([realm_file(@required -- ["PLATFORM_ADMIN", "AGENT_RUNNER"])])
    assert code == 1
    assert out =~ "AGENT_RUNNER, PLATFORM_ADMIN" or out =~ "PLATFORM_ADMIN"
    {_, 0} = run([realm_file(@required)])
  end

  test "an unreadable export is refused with exit 2" do
    {_out, code} = run([realm_file([]) <> ".nope"])
    assert code == 2
  end

  test "the required list is the built-in role set, and the runbook names each" do
    builtin = Authorization.roles() |> Enum.map(&Atom.to_string/1)
    assert Enum.sort(@required) == Enum.sort(builtin)

    runbook = File.read!(@runbook)
    for role <- builtin, do: assert(runbook =~ role, "runbook does not name #{role}")
    assert runbook =~ "Realm roles a tenant realm must carry"
  end
end
