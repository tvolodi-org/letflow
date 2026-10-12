defmodule Letflow.Scripts.MeridianRegulatoryRemediationFixtureTest do
  @moduledoc """
  ISS-1025 / Q-1007 (GH #2300) -- the QA Meridian "Regulatory Compliance Review" fixture (v1.6)
  must not hand a critical finding to an attribute-less SUB_PROCESS.

  v1.5 defect: `remediation-subprocess` was `{"node_type": "SUB_PROCESS"}` with no
  `definition_name`, so nobody remediated anything, nothing ever set `remediation_status`, and
  edge `e9` (`remediation_status == 'resolved'` -> `findings-sign-off`) was unreachable: every
  critical finding ended with a `remediation_unresolved` notice to the regulator.

  v1.6 (option (b) of the issue): `remediation-subprocess` (id kept stable) is a HUMAN_TASK for
  `role-compliance-officer` that is completed with output variable `remediation_status` =
  `resolved` | `unresolved`. Normal completion follows `e8` (constant condition `true`, like
  `e3`); a P30D deadline (`escalation_timer_duration`) follows the single non-conditioned edge
  `timeout-remediation-subprocess` straight to `remediation-unresolved-escalation`. Only an exact
  `'resolved'` reaches `findings-sign-off`.

  Pure: no DB, no HTTP. Drives the real `Letflow.Engine.Transition` and the real
  `Letflow.Engine.Expr` evaluator over the shipped JSON, and re-applies each `check_*` guard to
  in-memory mutants to prove it fires.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.{Expr, InstanceState, Token, Transition}

  @qa_dir Path.expand("../../fixtures/qa", __DIR__)
  @fixture Path.join(@qa_dir, "meridian_regulatory_compliance_review_process_definition.json")
  @yaml_fixture Path.expand(
                  "../../fixtures/simulation/meridian/process_policy_binding.yaml",
                  __DIR__
                )

  defp doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp yaml_doc do
    {:ok, d} = YamlElixir.read_from_file(@yaml_fixture)
    d
  end

  defp nodes(d), do: d["graph"]["nodes"]
  defp edges(d), do: d["graph"]["edges"]
  defp node(d, id), do: Enum.find(nodes(d), &(&1["id"] == id))
  defp edges_from(d, id), do: Enum.filter(edges(d), &(&1["source"] == id))

  defp graph!(d) do
    assert {:ok, graph} = Graph.from_map(d["graph"])
    graph
  end

  defp ok_if(true, _), do: :ok
  defp ok_if(false, msg), do: {:error, msg}

  # every QA fixture that is a process definition: [{file, name, document}]
  defp qa_definitions do
    for path <- Path.wildcard(Path.join(@qa_dir, "*.json")),
        d = path |> File.read!() |> Jason.decode!(),
        is_map(d),
        match?(%{"graph" => %{"nodes" => n, "edges" => e}} when is_list(n) and is_list(e), d),
        do: {Path.basename(path), d["name"], d}
  end

  # ---------------------------------------------------------------------------------
  # Guards: each returns :ok | {:error, term}
  # ---------------------------------------------------------------------------------

  # AC2: a SUB_PROCESS node must name a child (attributes.definition_name) that is a shipped
  # QA fixture; `shipped_names` is the set of QA fixture definition names.
  defp check_sub_processes(d, shipped_names) do
    bad =
      for n <- nodes(d),
          n["node_type"] == "SUB_PROCESS",
          name <- [(n["attributes"] || %{})["definition_name"]],
          not (is_binary(name) and String.trim(name) != "" and name in shipped_names),
          do: {n["id"], name}

    ok_if(bad == [], bad)
  end

  defp check_remediation_task(d) do
    n = node(d, "remediation-subprocess") || %{}
    a = n["attributes"] || %{}

    ok_if(
      n["node_type"] == "HUMAN_TASK" and a["role"] == "role-compliance-officer" and
        is_binary(a["escalation_timer_duration"]) and a["escalation_role"] == "role-ceo",
      n
    )
  end

  # e8 is the constant-true completion edge; the only non-conditioned edge is the deadline
  # edge to the unresolved escalation (never to findings-sign-off).
  defp check_deadline_edge(d) do
    out = edges_from(d, "remediation-subprocess")

    unconditioned =
      Enum.reject(out, fn e ->
        e["is_default"] != true and is_binary(e["condition"]) and
          String.trim(e["condition"]) != ""
      end)

    e8 = Enum.find(out, &(&1["id"] == "e8"))

    ok_if(
      match?(
        [
          %{
            "id" => "timeout-remediation-subprocess",
            "target" => "remediation-unresolved-escalation"
          }
        ],
        unconditioned
      ) and e8 != nil and e8["condition"] == "true" and e8["target"] == "post-remediation-check",
      out
    )
  end

  defp check_version(d), do: ok_if(d["version"] == "1.10", {:version, d["version"]})

  defp edge_shape(d) do
    d
    |> edges()
    |> Enum.map(
      &{&1["id"], &1["source"], &1["target"], &1["condition"], &1["is_default"] == true}
    )
    |> Enum.sort()
  end

  defp check_yaml_parity(d, y) do
    same =
      Enum.sort(Enum.map(nodes(d), &{&1["id"], &1["node_type"]})) ==
        Enum.sort(Enum.map(nodes(y), &{&1["id"], &1["node_type"]})) and
        node(d, "remediation-subprocess")["attributes"] ==
          node(y, "remediation-subprocess")["attributes"] and
        edge_shape(d) == edge_shape(y)

    ok_if(same, :json_yaml_drift)
  end

  # ---------------------------------------------------------------------------------
  # Fixture shape
  # ---------------------------------------------------------------------------------

  describe "fixture shape (AC1, AC2, AC4)" do
    test "version is 1.7 (1.6 forced the QA re-seed of the remediation human task; ISS-1015 added the forms)" do
      assert check_version(doc()) == :ok
    end

    test "regulatory fixture: no SUB_PROCESS without a resolvable definition_name" do
      names = for {_f, name, _d} <- qa_definitions(), do: name
      assert check_sub_processes(doc(), names) == :ok
    end

    test "every shipped QA definition: each SUB_PROCESS names a definition that is itself a shipped QA fixture" do
      defs = qa_definitions()
      names = for {_f, name, _d} <- defs, do: name
      assert length(defs) >= 5

      for {file, _name, d} <- defs do
        assert check_sub_processes(d, names) == :ok, "#{file}"
      end
    end

    test "the guard is not vacuous: the Vortex 8D parent really has a named SUB_PROCESS" do
      defs = qa_definitions()
      names = for {_f, name, _d} <- defs, do: name

      {_f, _n, vortex} =
        Enum.find(defs, fn {f, _, _} ->
          f == "vortex_supplier_quality_deviation_process_definition.json"
        end)

      assert Enum.any?(nodes(vortex), &(&1["node_type"] == "SUB_PROCESS"))
      assert check_sub_processes(vortex, names) == :ok
    end

    test "remediation-subprocess is a HUMAN_TASK for role-compliance-officer with a P30D deadline escalating to role-ceo" do
      assert check_remediation_task(doc()) == :ok

      assert node(doc(), "remediation-subprocess")["attributes"]["escalation_timer_duration"] ==
               "P30D"
    end

    test "the remediation role is one this fixture already used (no new role)" do
      d = doc()

      other_roles =
        for n <- nodes(d),
            n["id"] != "remediation-subprocess",
            r = (n["attributes"] || %{})["role"],
            do: r

      assert node(d, "remediation-subprocess")["attributes"]["role"] in other_roles
    end

    test "e8 is the constant-true completion edge and the deadline edge goes only to remediation-unresolved-escalation" do
      assert check_deadline_edge(doc()) == :ok
    end

    test "graph, node attributes and edge conditions validate with zero violations" do
      g = graph!(doc())

      for r <- [
            Graph.validate_graph(g),
            Graph.validate_node_attributes(g),
            Graph.validate_edge_conditions(g),
            Graph.validate_flow(g)
          ] do
        assert r.violations == []
      end
    end

    test "process_policy_binding.yaml mirrors the JSON fixture" do
      assert check_yaml_parity(doc(), yaml_doc()) == :ok
    end
  end

  # ---------------------------------------------------------------------------------
  # Real engine: Transition + Expr
  # ---------------------------------------------------------------------------------

  defp state(node_id, variables) do
    %InstanceState{
      instance_id: "inst-iss1025",
      status: :active,
      tokens: [%Token{node_id: node_id, token_id: "t1"}],
      variables: variables,
      pending_task_nodes: [node_id]
    }
  end

  defp step(graph, node_id, variables, event) do
    assert {:ok, %InstanceState{tokens: [%Token{node_id: next}]}, _} =
             Transition.transition(graph, state(node_id, variables), {event, "t1"})

    next
  end

  # Complete the remediation human task, then let the gateway route.
  defp remediate(variables) do
    graph = graph!(doc())

    assert "post-remediation-check" ==
             step(graph, "remediation-subprocess", variables, :complete_task)

    step(graph, "post-remediation-check", variables, :advance_token)
  end

  describe "real Transition (AC3)" do
    test "remediation_status 'resolved' reaches findings-sign-off through e9" do
      assert "findings-sign-off" == remediate(%{"remediation_status" => "resolved"})
    end

    test "'unresolved', missing, null, empty or unrecognised never reaches findings-sign-off" do
      for v <- [
            %{"remediation_status" => "unresolved"},
            %{},
            %{"remediation_status" => nil},
            %{"remediation_status" => ""},
            %{"remediation_status" => "RESOLVED"},
            %{"remediation_status" => "resolved "},
            %{"remediation_status" => "maybe"}
          ] do
        assert "remediation-unresolved-escalation" == remediate(v), inspect(v)
      end
    end

    test "no answer within the deadline (escalation timer fired) lands on remediation-unresolved-escalation, even if a stale 'resolved' is set" do
      graph = graph!(doc())

      for v <- [%{}, %{"remediation_status" => "resolved"}] do
        assert "remediation-unresolved-escalation" ==
                 step(graph, "remediation-subprocess", v, :escalation_timer_fired)
      end
    end

    test "a critical finding routes into the remediation human task, not around it" do
      graph = graph!(doc())

      for sev <- ["critical", "weird", nil] do
        v = %{"highest_severity" => sev}

        assert "remediation-subprocess" == step(graph, "severity-routing", v, :advance_token),
               inspect(sev)
      end

      assert "findings-sign-off" ==
               step(graph, "severity-routing", %{"highest_severity" => "low"}, :advance_token)
    end
  end

  describe "graph walk with the real evaluator (over-approximating: unconditioned edges always followed)" do
    defp reachable(start, variables), do: walk([start], MapSet.new([start]), variables)

    defp walk([], seen, _), do: seen

    defp walk([n | rest], seen, variables) do
      next =
        for e <- edges_from(doc(), n),
            is_nil(e["condition"]) or Expr.evaluate_condition(e["condition"], variables),
            e["target"] not in seen,
            uniq: true,
            do: e["target"]

      walk(rest ++ next, Enum.into(next, seen), variables)
    end

    test "non-vacuous: resolved reaches findings-sign-off, archive-review and end-closed" do
      reached =
        reachable("remediation-subprocess", %{
          "remediation_status" => "resolved",
          "cro_decision" => "sign_off"
        })

      assert "findings-sign-off" in reached
      assert "archive-review" in reached
    end

    test "from remediation-subprocess, unresolved / missing never reaches findings-sign-off or archive-review" do
      for v <- [%{"remediation_status" => "unresolved"}, %{}, %{"remediation_status" => "maybe"}] do
        reached = reachable("remediation-subprocess", Map.put(v, "cro_decision", "sign_off"))
        refute "findings-sign-off" in reached, inspect(v)
        refute "archive-review" in reached, inspect(v)
        assert "remediation-unresolved-escalation" in reached
        assert "end-closed" in reached
      end
    end

    test "from severity-routing, a critical (or unknown) finding with no remediation answer never reaches findings-sign-off" do
      for sev <- ["critical", "unknown"] do
        reached = reachable("severity-routing", %{"highest_severity" => sev})
        refute "findings-sign-off" in reached, sev
        assert "remediation-unresolved-escalation" in reached
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Mutants (in-memory; no repo file is edited)
  # ---------------------------------------------------------------------------------

  describe "mutants" do
    defp names, do: for({_f, n, _d} <- qa_definitions(), do: n)

    defp put_node(d, id, fun),
      do:
        update_in(d, ["graph", "nodes"], fn ns ->
          Enum.map(ns, &if(&1["id"] == id, do: fun.(&1), else: &1))
        end)

    test "M1 v1.5 shape (attribute-less SUB_PROCESS) -> sub-process, task and parity guards red" do
      m =
        put_node(doc(), "remediation-subprocess", fn _ ->
          %{"id" => "remediation-subprocess", "node_type" => "SUB_PROCESS"}
        end)

      assert {:error, _} = check_sub_processes(m, names())
      assert {:error, _} = check_remediation_task(m)
      assert {:error, _} = check_yaml_parity(m, yaml_doc())
    end

    test "M2 SUB_PROCESS naming a definition that is not shipped -> red" do
      m =
        put_node(doc(), "remediation-subprocess", fn n ->
          n
          |> Map.put("node_type", "SUB_PROCESS")
          |> Map.put("attributes", %{"definition_name" => "Compliance Remediation"})
        end)

      assert {:error, _} = check_sub_processes(m, names())
    end

    test "M3 blank definition_name -> red" do
      m =
        put_node(
          doc(),
          "remediation-subprocess",
          &Map.merge(&1, %{
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"definition_name" => " "}
          })
        )

      assert {:error, _} = check_sub_processes(m, names())
    end

    test "M4 deadline edge re-pointed at findings-sign-off -> red" do
      m =
        update_in(doc(), ["graph", "edges"], fn es ->
          Enum.map(
            es,
            &if(&1["id"] == "timeout-remediation-subprocess",
              do: Map.put(&1, "target", "findings-sign-off"),
              else: &1
            )
          )
        end)

      assert {:error, _} = check_deadline_edge(m)
    end

    test "M5 timeout edge removed -> red" do
      m =
        update_in(doc(), ["graph", "edges"], fn es ->
          Enum.reject(es, &(&1["id"] == "timeout-remediation-subprocess"))
        end)

      assert {:error, _} = check_deadline_edge(m)
    end

    test "M6 role changed or deadline removed -> red" do
      assert {:error, _} =
               check_remediation_task(
                 put_node(
                   doc(),
                   "remediation-subprocess",
                   &put_in(&1, ["attributes", "role"], "role-cro")
                 )
               )

      assert {:error, _} =
               check_remediation_task(
                 put_node(
                   doc(),
                   "remediation-subprocess",
                   &update_in(&1, ["attributes"], fn a ->
                     Map.delete(a, "escalation_timer_duration")
                   end)
                 )
               )
    end

    test "M8 yaml mirror edge conditions drift (e8 loses 'true', e9 loosened) -> parity red" do
      for {id, fun} <- [
            {"e8", &Map.delete(&1, "condition")},
            {"e9", &Map.put(&1, "condition", "variables.remediation_status != 'unresolved'")}
          ] do
        y =
          update_in(yaml_doc(), ["graph", "edges"], fn es ->
            Enum.map(es, &if(&1["id"] == id, do: fun.(&1), else: &1))
          end)

        assert {:error, _} = check_yaml_parity(doc(), y), id
      end
    end

    test "M9 seed script header names the fixture version" do
      script = Path.expand("../../../scripts/seed_meridian_definition.sh", __DIR__)
      assert File.read!(script) =~ ~s(Regulatory Compliance Review" v#{doc()["version"]} )
    end

    test "M7 version not bumped -> red" do
      assert {:error, _} = check_version(Map.put(doc(), "version", "1.6"))
    end
  end
end
