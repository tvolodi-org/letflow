defmodule Letflow.Scripts.VortexRosterCeoTest do
  @moduledoc """
  ISS-1006 / Q-988 (GH #2275, process-audit PA-VORTEX-006, checklist D3) regression guard.

  The vortex process definitions escalate human tasks to `role-ceo` (escalate-to-ceo,
  escalate-budget-approval-to-finance-director (role-finance-director since REQ-471), escalate-severity-classification-to-ceo); the roster entry and seed
  persona for the CEO, `actor-vortex-dirk`, landed in b65110b5 without a guard. The D3 question is: "is
  every role a vortex human task routes to held by some vortex actor in the roster?" -- asserted below
  for every vortex QA process definition (role and escalation_role), plus the roster shape and the seed
  script's ROLES / PERSONAS data. Pure file I/O, `async: true`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)
  @actors_path Path.join(@root, "test/fixtures/uat/actors.yaml")
  @script_path Path.join(@root, "scripts/seed_vortex_persona_actors.sh")

  defp roster, do: YamlElixir.read_from_file!(@actors_path)

  defp vortex_actors do
    roster()["actors"] |> Enum.filter(fn {_id, a} -> a["tenant"] == "vortex" end) |> Map.new()
  end

  # The PERSONAS entries ("actor|role,role") and ROLES entries of the seed script, from its source.
  defp script_personas do
    Regex.scan(~r/^\s*"(actor-vortex-[a-z]+)\|([^"]*)"\s*$/m, File.read!(@script_path))
    |> Map.new(fn [_, actor, roles] ->
      {actor, roles |> String.split(",", trim: true)}
    end)
  end

  defp script_persona_lines do
    Regex.scan(~r/^\s*"actor-vortex-[a-z]+\|[^"]*"\s*$/m, File.read!(@script_path))
    |> Enum.map(fn [line] -> line end)
  end

  defp script_roles do
    Regex.scan(~r/^\s*"(role-[a-z-]+)"\s*$/m, File.read!(@script_path))
    |> Enum.map(fn [_, r] -> r end)
  end

  # Every vortex QA fixture that is a process definition (has graph.nodes); entity / records files skipped.
  defp process_definition_paths do
    @root
    |> Path.join("test/fixtures/qa/vortex_*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.filter(fn path ->
      path |> File.read!() |> Jason.decode!() |> get_in(["graph", "nodes"]) |> is_list()
    end)
  end

  defp human_task_roles(path) do
    path
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

  test "actors.yaml has a vortex actor holding role-ceo" do
    holders =
      for {id, a} <- vortex_actors(), "role-ceo" in (a["routing_roles"] || []), do: id

    assert holders == ["actor-vortex-dirk"]
  end

  test "REQ-471: exactly one vortex actor holds role-finance-director, seeded by one PERSONAS line" do
    holders =
      for {id, a} <- vortex_actors(),
          "role-finance-director" in (a["routing_roles"] || []),
          do: id

    assert holders == ["actor-vortex-greta"]
    assert "role-finance-director" in script_roles()

    persona_lines = script_persona_lines()

    assert Enum.count(persona_lines, &String.contains?(&1, "role-finance-director")) == 1
    assert script_personas()["actor-vortex-greta"] == ["role-finance-director"]

    assert Enum.count(persona_lines, &String.contains?(&1, "role-ceo")) == 1,
           "no second role-ceo persona"
  end

  test "dirk is a resolved roster entry, not unresolved, with recorded access" do
    actors = roster()["actors"]
    unresolved = roster()["unresolved"] || %{}
    id = "actor-vortex-dirk"

    assert Map.has_key?(actors, id), "#{id} must be under actors:"
    refute Map.has_key?(unresolved, id), "#{id} must not remain under unresolved:"
    assert actors[id]["tenant"] == "vortex"
    assert actors[id]["builtin_roles"] == ["TASK_WORKER"], "#{id}: least privilege"
    assert is_binary(actors[id]["note"]) and actors[id]["note"] != ""
  end

  test "the seed script lists role-ceo and the dirk persona" do
    assert "role-ceo" in script_roles()
    assert script_personas()["actor-vortex-dirk"] == ["role-ceo"]
  end

  test "the seed script's personas agree with the roster's vortex routing roles" do
    personas = script_personas()

    for {id, a} <- vortex_actors() do
      assert Map.has_key?(personas, id), "#{id} is in actors.yaml but not in the seed PERSONAS"
      assert Enum.sort(personas[id]) == Enum.sort(a["routing_roles"] || []), id
    end

    for {id, roles} <- personas, role <- roles do
      assert role in script_roles(), "#{id}: #{role} is not in the seed ROLES"
    end
  end

  test "D3: every role a vortex QA human task routes to is held by a vortex actor" do
    held =
      vortex_actors()
      |> Enum.flat_map(fn {_id, a} -> a["routing_roles"] || [] end)
      |> MapSet.new()

    paths = process_definition_paths()

    assert Enum.map(paths, &Path.basename/1) == [
             "vortex_8d_corrective_action_definition.json",
             "vortex_production_order_release_process_definition.json",
             "vortex_supplier_quality_deviation_process_definition.json"
           ],
           "guard: the glob must find all three vortex process definitions"

    walked = paths |> Enum.flat_map(&human_task_roles/1) |> MapSet.new()

    assert walked != MapSet.new(), "guard: no routed roles walked"

    for role <-
          ~w(role-ceo role-finance-director role-production-manager role-controller role-quality-manager role-procurement-manager) do
      assert MapSet.member?(walked, role),
             "guard: #{role} is not routed to by any vortex definition"
    end

    seed_roles = script_roles()

    for path <- paths, role <- human_task_roles(path) do
      assert MapSet.member?(held, role), "#{path}: #{role} is held by no vortex actor"
      assert role in seed_roles, "#{path}: #{role} is not in the seed ROLES"
    end
  end
end
