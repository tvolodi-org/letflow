defmodule Letflow.Scripts.SwiftrouteRosterAccountantTest do
  @moduledoc """
  ISS-1011 / Q-993 (GH #2280, process-audit PA-SWIFTROUTE-005 / -008, checklist D3) regression guard.

  The Driver Incident Report's `finance-estimate` task routes to `role-accountant`; before this fix no
  swiftroute actor held it and the timeout-scenario dispatcher `actor-swiftroute-tobias` sat under
  `unresolved:` with no access on record. The D3 question is: "is every role a swiftroute human task
  routes to held by some swiftroute actor in the roster?" -- asserted below for every human task of both
  swiftroute QA definitions (role and escalation_role), plus the roster shape and the seed script's
  ROLES / PERSONAS data. Pure file I/O, `async: true`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)
  @actors_path Path.join(@root, "test/fixtures/uat/actors.yaml")
  @script_path Path.join(@root, "scripts/seed_swiftroute_persona_actors.sh")
  @qa_defs [
    "test/fixtures/qa/swiftroute_process_definition.json",
    "test/fixtures/qa/swiftroute_incident_process_definition.json"
  ]

  defp roster, do: YamlElixir.read_from_file!(@actors_path)

  defp swiftroute_actors do
    roster()["actors"] |> Enum.filter(fn {_id, a} -> a["tenant"] == "swiftroute" end) |> Map.new()
  end

  # The PERSONAS entries ("actor|role,role") and ROLES entries of the seed script, from its source.
  defp script_personas do
    Regex.scan(~r/^\s*"(actor-swiftroute-[a-z]+)\|([^"]*)"\s*$/m, File.read!(@script_path))
    |> Map.new(fn [_, actor, roles] ->
      {actor, roles |> String.split(",", trim: true)}
    end)
  end

  defp script_roles do
    Regex.scan(~r/^\s*"(role-[a-z-]+)"\s*$/m, File.read!(@script_path))
    |> Enum.map(fn [_, r] -> r end)
  end

  defp human_task_roles(path) do
    @root
    |> Path.join(path)
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["graph", "nodes"])
    |> Enum.filter(&(&1["node_type"] == "HUMAN_TASK"))
    |> Enum.flat_map(fn n ->
      attrs = n["attributes"] || %{}
      [attrs["role"], attrs["escalation_role"]]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  test "actors.yaml has a swiftroute actor holding role-accountant" do
    holders =
      for {id, a} <- swiftroute_actors(), "role-accountant" in (a["routing_roles"] || []), do: id

    assert holders == ["actor-swiftroute-hans"]
  end

  test "hans and tobias are resolved roster entries, not unresolved, with recorded access" do
    actors = roster()["actors"]
    unresolved = roster()["unresolved"] || %{}

    for id <- ["actor-swiftroute-hans", "actor-swiftroute-tobias"] do
      assert Map.has_key?(actors, id), "#{id} must be under actors:"
      refute Map.has_key?(unresolved, id), "#{id} must not remain under unresolved:"
      assert actors[id]["tenant"] == "swiftroute"
      assert actors[id]["builtin_roles"] == ["TASK_WORKER"], "#{id}: least privilege"
      assert is_binary(actors[id]["note"]) and actors[id]["note"] != ""
    end

    # the dispatcher mirrors lena: no routing role (neither scenario nor org file gives him one)
    assert actors["actor-swiftroute-tobias"]["routing_roles"] == []
  end

  test "the seed script lists role-accountant and the hans / tobias personas" do
    assert "role-accountant" in script_roles()
    personas = script_personas()
    assert personas["actor-swiftroute-hans"] == ["role-accountant"]
    assert Map.has_key?(personas, "actor-swiftroute-tobias")
    assert personas["actor-swiftroute-tobias"] == []
  end

  test "the seed script's personas agree with the roster's swiftroute routing roles" do
    personas = script_personas()

    # The read-only auditor (GH #2363) is provisioned by infra, not by the seed script (GH #3047).
    # It must stay free of routing roles: TENANT_AUDITOR only.
    auditor = swiftroute_actors()["actor-swiftroute-auditor"]
    assert auditor["builtin_roles"] == ["TENANT_AUDITOR"]
    assert auditor["routing_roles"] == []

    for {id, a} <- Map.delete(swiftroute_actors(), "actor-swiftroute-auditor") do
      assert Map.has_key?(personas, id), "#{id} is in actors.yaml but not in the seed PERSONAS"
      assert Enum.sort(personas[id]) == Enum.sort(a["routing_roles"] || []), id
    end

    for {id, roles} <- personas, role <- roles do
      assert role in script_roles(), "#{id}: #{role} is not in the seed ROLES"
    end
  end

  test "D3: every role a swiftroute QA human task routes to is held by a swiftroute actor" do
    held =
      swiftroute_actors()
      |> Enum.flat_map(fn {_id, a} -> a["routing_roles"] || [] end)
      |> MapSet.new()

    assert "role-accountant" in human_task_roles(Enum.at(@qa_defs, 1)),
           "guard: the incident definition must route a task to role-accountant"

    for path <- @qa_defs, role <- human_task_roles(path) do
      assert MapSet.member?(held, role), "#{path}: #{role} is held by no swiftroute actor"
    end
  end
end
