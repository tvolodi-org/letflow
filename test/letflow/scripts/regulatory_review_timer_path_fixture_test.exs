defmodule Letflow.Scripts.RegulatoryReviewTimerPathFixtureTest do
  @moduledoc """
  ISS-0932 / Q-915 regression guard (T1-T12 + in-memory mutants M1-M10 of
  `lib/letflow/design/q915-regulatory-review-21day-timer-path.md` section 7).

  The Meridian "Regulatory Compliance Review" definition must arm a P21D escalation
  timer on `risk-evaluation` whose single non-conditioned edge leads to
  `regulatory-auto-escalation`, while normal completion keeps going to
  `severity-routing` (edge `e3`, constant condition "true").

  Pure: no DB, no HTTP. Loads the QA JSON fixture, builds the real graph, and drives
  the pure `Transition.transition/3`. Each guard is a `check_*` function over a decoded
  document so the same logic is re-applied to mutated in-memory copies (M1-M10) to prove
  it fires. See `test/specs/ISS-0932.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.Token
  alias Letflow.Engine.Transition

  @json_fixture Path.expand(
                  "../../fixtures/qa/meridian_regulatory_compliance_review_process_definition.json",
                  __DIR__
                )
  @yaml_fixture Path.expand(
                  "../../fixtures/simulation/meridian/process_policy_binding.yaml",
                  __DIR__
                )

  @severities ["none", "low", "medium", "high", "critical"]

  # ---------------------------------------------------------------------------------
  # Helpers (no optional-argument defaults -- anti-patterns.md ISS-0069)
  # ---------------------------------------------------------------------------------

  defp json_doc, do: @json_fixture |> File.read!() |> Jason.decode!()

  defp yaml_doc do
    {:ok, doc} = YamlElixir.read_from_file(@yaml_fixture)
    doc
  end

  defp nodes(doc), do: doc["graph"]["nodes"]
  defp edges(doc), do: doc["graph"]["edges"]
  defp node(doc, id), do: Enum.find(nodes(doc), &(&1["id"] == id))
  defp edge(doc, id), do: Enum.find(edges(doc), &(&1["id"] == id))
  defp out_edges(doc, id), do: Enum.filter(edges(doc), &(&1["source"] == id))
  defp in_edges(doc, id), do: Enum.filter(edges(doc), &(&1["target"] == id))

  defp map_node(doc, id, fun),
    do:
      update_in(doc, ["graph", "nodes"], fn ns ->
        Enum.map(ns, fn n -> if n["id"] == id, do: fun.(n), else: n end)
      end)

  defp map_edge(doc, id, fun),
    do:
      update_in(doc, ["graph", "edges"], fn es ->
        Enum.map(es, fn e -> if e["id"] == id, do: fun.(e), else: e end)
      end)

  defp drop_edge(doc, id),
    do: update_in(doc, ["graph", "edges"], fn es -> Enum.reject(es, &(&1["id"] == id)) end)

  # "really conditioned" per Transition: non-default edge with a non-blank condition.
  defp conditioned?(e) do
    cond_str = e["condition"]
    e["is_default"] != true and is_binary(cond_str) and String.trim(cond_str) != ""
  end

  defp graph!(doc) do
    {:ok, graph} = Graph.from_map(doc["graph"])
    graph
  end

  defp state(variables, node_id) do
    %InstanceState{
      instance_id: "inst-q915",
      status: :active,
      tokens: [%Token{node_id: node_id, token_id: "tok-1"}],
      variables: variables,
      pending_task_nodes: [node_id]
    }
  end

  defp token_node(doc, event, variables) do
    case Transition.transition(graph!(doc), state(variables, "risk-evaluation"), {event, "tok-1"}) do
      {:ok, new_state, _events} -> {:ok, Enum.map(new_state.tokens, & &1.node_id)}
      other -> {:error, other}
    end
  end

  defp ok_if(true, _msg), do: :ok
  defp ok_if(false, msg), do: {:error, msg}

  defp legacy_node do
    %{
      "id" => "risk-evaluation-timeout",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{
        "endpoint" => "https://example.test/flag",
        "method" => "POST",
        "timeout_ms" => 1000
      }
    }
  end

  defp with_legacy_node(doc), do: update_in(doc, ["graph", "nodes"], &(&1 ++ [legacy_node()]))

  # ---------------------------------------------------------------------------------
  # Guards: each returns :ok | {:error, term}
  # ---------------------------------------------------------------------------------

  # ISS-0926 bumped the shipped fixture to "1.3" (body_template added to
  # regulatory-auto-escalation, new node remediation-unresolved-escalation
  # split out from e10's own inbound meaning -- see that fix's own design
  # doc §4.5). ISS-1018 / Q-1000 bumped it to "1.5" (fallback-ceo-override
  # now targets reopen-review instead of archive-review). ISS-1025 / Q-1007
  # bumped it to "1.6" (remediation-subprocess is now a HUMAN_TASK, not an
  # attribute-less SUB_PROCESS). ISS-1015 / Q-997 bumped it to "1.7" (every
  # HUMAN_TASK carries a form_schema).
  defp check_t1(doc), do: ok_if(doc["version"] == "1.10", {:version, doc["version"]})

  defp check_t2(doc),
    do:
      ok_if(not String.contains?(doc["description"], "timer boundary event"), :stale_description)

  defp check_t3(doc) do
    g = graph!(doc)

    results = [
      Graph.validate_graph(g),
      Graph.validate_node_attributes(g),
      Graph.validate_edge_conditions(g)
    ]

    ok_if(
      Enum.all?(results, &(&1.valid and &1.violations == [])),
      Enum.flat_map(results, & &1.violations)
    )
  end

  defp check_t4(doc) do
    a = (node(doc, "risk-evaluation") || %{})["attributes"] || %{}

    ok_if(
      a["escalation_timer_duration"] == "P21D" and a["escalation_role"] == "role-ceo" and
        a["role"] == "role-risk-manager",
      a
    )
  end

  defp check_t5(doc) do
    fallbacks = doc |> out_edges("risk-evaluation") |> Enum.reject(&conditioned?/1)

    ok_if(
      match?(
        [%{"id" => "timeout-risk-evaluation", "target" => "regulatory-auto-escalation"}],
        fallbacks
      ),
      fallbacks
    )
  end

  defp check_t6(doc) do
    e3 = edge(doc, "e3")
    ok_if(e3 != nil and e3["condition"] == "true" and e3["target"] == "severity-routing", e3)
  end

  defp check_t7(doc),
    do:
      ok_if(
        node(doc, "risk-evaluation-timeout") == nil and edge(doc, "e4") == nil,
        :legacy_timeout_node_or_e4
      )

  # ISS-0926 split the former shared node into two: regulatory-auto-escalation
  # now carries exactly one inbound edge (the 21-day SLA-breach timer path)
  # and a static body_template reporting reason sla_breach_30_days;
  # remediation-unresolved-escalation (check_t8b/1 below) carries the other
  # (e10, remediation_unresolved).
  defp check_t8(doc) do
    inbound = doc |> in_edges("regulatory-auto-escalation") |> Enum.map(& &1["id"]) |> Enum.sort()

    outbound =
      doc |> out_edges("regulatory-auto-escalation") |> Enum.map(&{&1["id"], &1["target"]})

    n = node(doc, "regulatory-auto-escalation") || %{}
    body_template = (n["attributes"] || %{})["body_template"]

    ok_if(
      inbound == ["timeout-risk-evaluation"] and outbound == [{"e5", "end-closed"}] and
        is_binary(body_template) and String.contains?(body_template, "sla_breach_30_days"),
      {inbound, outbound, n["attributes"]}
    )
  end

  # REQ-455: post-remediation-check gained an is_default edge (CHK-24) to this node,
  # so its inbound set is e10 plus that default; both mean "remediation unresolved".
  # ISS-1025 / Q-1007: the P30D deadline edge of the remediation human task is the third.
  defp check_t8b(doc) do
    inbound =
      doc
      |> in_edges("remediation-unresolved-escalation")
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    outbound =
      doc
      |> out_edges("remediation-unresolved-escalation")
      |> Enum.map(&{&1["id"], &1["target"]})

    n = node(doc, "remediation-unresolved-escalation") || %{}
    body_template = (n["attributes"] || %{})["body_template"]

    ok_if(
      inbound == ["e10", "post-remediation-check-default", "timeout-remediation-subprocess"] and
        outbound == [{"e18", "end-closed"}] and
        is_binary(body_template) and String.contains?(body_template, "remediation_unresolved"),
      {inbound, outbound, n["attributes"]}
    )
  end

  defp check_t9(doc) do
    results =
      for vars <- [%{}, %{"highest_severity" => "low"}],
          do: token_node(doc, :escalation_timer_fired, vars)

    ok_if(
      results == [{:ok, ["regulatory-auto-escalation"]}, {:ok, ["regulatory-auto-escalation"]}],
      results
    )
  end

  defp check_t10(doc) do
    results =
      for sev <- ["low", "critical"],
          do: token_node(doc, :complete_task, %{"highest_severity" => sev})

    ok_if(results == [{:ok, ["severity-routing"]}, {:ok, ["severity-routing"]}], results)
  end

  defp check_t11(doc) do
    result = token_node(doc, :complete_task, %{})
    ok_if(result == {:ok, ["severity-routing"]}, result)
  end

  defp check_t12(doc, yaml) do
    ids = fn d, key -> d["graph"][key] |> Enum.map(& &1["id"]) |> Enum.sort() end

    attrs = fn d ->
      Map.take(node(d, "risk-evaluation")["attributes"], [
        "role",
        "escalation_timer_duration",
        "escalation_role"
      ])
    end

    same =
      ids.(doc, "nodes") == ids.(yaml, "nodes") and ids.(doc, "edges") == ids.(yaml, "edges") and
        attrs.(doc) == attrs.(yaml) and
        edge(doc, "e3")["condition"] == edge(yaml, "e3")["condition"] and
        edge(doc, "timeout-risk-evaluation")["target"] ==
          edge(yaml, "timeout-risk-evaluation")["target"]

    ok_if(same, :json_yaml_drift)
  end

  # ---------------------------------------------------------------------------------
  # T1-T12 against the real fixture
  # ---------------------------------------------------------------------------------

  describe "ISS-0932 T1-T12: shipped fixture" do
    test "T1 version is 1.2 (seed script only replaces an ACTIVE definition when strictly newer)" do
      assert check_t1(json_doc()) == :ok
    end

    test "T2 description no longer claims a 'timer boundary event'" do
      assert check_t2(json_doc()) == :ok
    end

    test "T3 graph, node attributes and edge conditions all validate with zero violations" do
      assert check_t3(json_doc()) == :ok
    end

    test "T4 risk-evaluation arms a P21D escalation timer with escalation_role role-ceo" do
      assert check_t4(json_doc()) == :ok
    end

    test "T5 risk-evaluation has exactly one non-conditioned edge, to regulatory-auto-escalation" do
      assert check_t5(json_doc()) == :ok
    end

    test "T6 e3 carries the constant condition 'true' and targets severity-routing" do
      assert check_t6(json_doc()) == :ok
    end

    test "T7 the legacy risk-evaluation-timeout node and edge e4 are gone" do
      assert check_t7(json_doc()) == :ok
    end

    test "T8 regulatory-auto-escalation: one inbound edge (timeout-risk-evaluation), e5 -> end-closed, body_template reports sla_breach_30_days" do
      assert check_t8(json_doc()) == :ok
    end

    test "T8b remediation-unresolved-escalation: inbound e10 + defaults/deadline edge, e18 -> end-closed, body_template reports remediation_unresolved" do
      assert check_t8b(json_doc()) == :ok
    end

    test "T9 escalation_timer_fired at risk-evaluation lands on regulatory-auto-escalation" do
      assert check_t9(json_doc()) == :ok
    end

    test "T10 normal completion with a severity lands on severity-routing" do
      assert check_t10(json_doc()) == :ok
    end

    test "T11 normal completion with NO severity still lands on severity-routing (no silent BaFin filing)" do
      assert check_t11(json_doc()) == :ok
    end

    test "T12 process_policy_binding.yaml is in parity with the JSON fixture" do
      assert check_t12(json_doc(), yaml_doc()) == :ok
    end
  end

  # ---------------------------------------------------------------------------------
  # M1-M10: in-memory mutants -- each guard must go red
  # ---------------------------------------------------------------------------------

  describe "ISS-0932 mutants (in-memory copies; no repo file is edited)" do
    test "M1 no escalation attributes -> T4 red" do
      m =
        map_node(
          json_doc(),
          "risk-evaluation",
          &Map.put(&1, "attributes", %{"role" => "role-risk-manager"})
        )

      assert {:error, _} = check_t4(m)
    end

    test "M2 timeout edge back to the legacy node (+ e4) -> T5, T7, T9, T12 red" do
      m =
        json_doc()
        |> with_legacy_node()
        |> map_edge("timeout-risk-evaluation", &Map.put(&1, "target", "risk-evaluation-timeout"))
        |> update_in(["graph", "edges"], fn es ->
          es ++
            [
              %{
                "id" => "e4",
                "source" => "risk-evaluation-timeout",
                "target" => "severity-routing"
              }
            ]
        end)

      assert {:error, _} = check_t5(m)
      assert {:error, _} = check_t7(m)
      assert {:error, _} = check_t9(m)
      assert {:error, _} = check_t12(m, yaml_doc())
    end

    test "M3 e3 loses its condition -> T5, T6, T9 red" do
      m = map_edge(json_doc(), "e3", &Map.delete(&1, "condition"))
      assert {:error, _} = check_t5(m)
      assert {:error, _} = check_t6(m)
      assert {:error, _} = check_t9(m)
    end

    test "M4 e3 condition is an OR-chain over the severities -> T6, T11 red" do
      chain = Enum.map_join(@severities, " || ", &"variables.highest_severity == '#{&1}'")
      m = map_edge(json_doc(), "e3", &Map.put(&1, "condition", chain))
      assert {:error, _} = check_t6(m)
      assert {:error, _} = check_t11(m)
    end

    test "M5 P30D instead of P21D -> T4 red" do
      m =
        map_node(
          json_doc(),
          "risk-evaluation",
          &put_in(&1, ["attributes", "escalation_timer_duration"], "P30D")
        )

      assert {:error, _} = check_t4(m)
    end

    test "M6 legacy node restored unconnected -> T3, T7 red" do
      m = with_legacy_node(json_doc())
      assert {:error, _} = check_t3(m)
      assert {:error, _} = check_t7(m)
    end

    test "M7 edge e5 removed -> T8 red" do
      assert {:error, _} = check_t8(drop_edge(json_doc(), "e5"))
    end

    test "M8 escalation_role removed alone -> T3, T4 red" do
      m =
        map_node(json_doc(), "risk-evaluation", fn n ->
          update_in(n, ["attributes"], &Map.delete(&1, "escalation_role"))
        end)

      assert {:error, _} = check_t3(m)
      assert {:error, _} = check_t4(m)
    end

    test "M9 regulatory-auto-escalation's body_template reports the WRONG reason -> T8 red" do
      # ISS-0926: the node legitimately carries a body_template now (reason
      # sla_breach_30_days); this mutant proves check_t8/1 actually inspects
      # its *content*, not merely its presence -- a reason mix-up (e.g. the
      # remediation-unresolved-escalation's own reason bleeding onto the
      # wrong node) is exactly the regulatory-filing-correctness defect class
      # this split exists to prevent.
      m =
        map_node(
          json_doc(),
          "regulatory-auto-escalation",
          &put_in(
            &1,
            ["attributes", "body_template"],
            ~s({"reason":"remediation_unresolved","review_id":"{{variables.review_id}}"})
          )
        )

      assert {:error, _} = check_t8(m)
    end

    test "M9b remediation-unresolved-escalation's body_template reports the WRONG reason -> T8b red" do
      m =
        map_node(
          json_doc(),
          "remediation-unresolved-escalation",
          &put_in(
            &1,
            ["attributes", "body_template"],
            ~s({"reason":"sla_breach_30_days","review_id":"{{variables.review_id}}"})
          )
        )

      assert {:error, _} = check_t8b(m)
    end

    test "M10 JSON new but YAML reverted to the old shape -> T12 red" do
      old_yaml =
        map_edge(
          yaml_doc(),
          "timeout-risk-evaluation",
          &Map.put(&1, "target", "risk-evaluation-timeout")
        )

      assert {:error, _} = check_t12(json_doc(), old_yaml)
    end
  end

  describe "ISS-1018 / Q-1000: ceo-override fails toward scrutiny" do
    defp reachable_from(doc, start, variables),
      do: walk_edges(doc, [start], MapSet.new([start]), variables)

    defp walk_edges(_doc, [], seen, _variables), do: seen

    defp walk_edges(doc, [node | rest], seen, variables) do
      next =
        for edge <- out_edges(doc, node),
            is_nil(edge["condition"]) or
              Letflow.Engine.Expr.evaluate_condition(edge["condition"], variables),
            edge["target"] not in seen,
            do: edge["target"]

      next = Enum.uniq(next)
      walk_edges(doc, rest ++ next, Enum.into(next, seen), variables)
    end

    for doc_name <- [:json_doc, :yaml_doc] do
      test "fallback-ceo-override targets reopen-review, never archive-review (#{doc_name})" do
        doc = unquote(doc_name)()
        ceo_edges = out_edges(doc, "ceo-override")

        assert %{"target" => "reopen-review"} =
                 fallback = Enum.find(ceo_edges, &(&1["id"] == "fallback-ceo-override"))

        refute conditioned?(fallback)

        assert [%{"id" => "e14", "condition" => "variables.ceo_decision == 'sign_off'"}] =
                 Enum.filter(ceo_edges, &(&1["target"] == "archive-review"))
      end

      test "a missing or unrecognised ceo_decision never reaches archive-review (#{doc_name})" do
        for variables <- [
              %{},
              %{"ceo_decision" => nil},
              %{"ceo_decision" => "maybe"},
              %{"ceo_decision" => "SIGN_OFF"},
              %{"ceo_decision" => ""}
            ] do
          reached = reachable_from(unquote(doc_name)(), "ceo-override", variables)

          refute "archive-review" in reached,
                 "reached archive-review with #{inspect(variables)}"

          assert "reopen-review" in reached
          assert "end-reopened" in reached
        end
      end
    end

    test "the walk is not vacuous: an explicit ceo_decision 'sign_off' reaches archive-review" do
      assert "archive-review" in reachable_from(json_doc(), "ceo-override", %{
               "ceo_decision" => "sign_off"
             })
    end
  end
end
