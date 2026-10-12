defmodule Letflow.Scripts.MeridianDEscEscalationFixtureTest do
  @moduledoc """
  ISS-1013 / Q-995 (GH #2282) -- the BA ruling "D-ESC" (GH #2281) applied to the two QA Meridian
  definitions (Loan Origination v1.12, Regulatory Compliance Review v1.9) and to their simulation
  YAML copies: timer -> higher role -> fail closed.

  The engine contract this test leans on (`lib/letflow/design/req396-human-task-escalation-timer.md`
  section 4.1): when a HUMAN_TASK's `escalation_timer_duration` elapses the engine CANCELS the task
  and follows the node's FIRST unconditioned (default/fallback) outgoing edge -- conditioned edges
  are skipped. The engine does NOT check that `escalation_role` equals the role of the node that
  edge leads to, and CHK-21 only validates the pair's shape, so THIS test is the only place that
  ties them together. Hence the three structural facts asserted for every timer-pair node:

    1. it has exactly ONE default candidate edge (no condition / `is_default`), and that edge is
       the timeout edge (every normal-completion edge of such a node therefore carries the
       constant condition `true`, as `risk-evaluation`'s `e3` already did);
    2. the "timeout walk" (the timeout edge, then default edges through service tasks and gateways)
       ends at a HUMAN_TASK whose `role` equals the origin's `escalation_role` and differs from the
       origin's own `role`, or -- only for nodes in the explicit per-definition `direct` allowlist --
       at an allowed fail-closed END;
    3. the walk never visits an approve / release / pay / archive-as-signed-off node, and the
       escalation chain is finite (<= 3 human tasks, no cycle) and ends at a top-of-chain task
       (`escalation_role == role`) or an allowlisted direct fail-closed node.

  Every HUMAN_TASK carries the pair or an E6 waiver (`Waiver: <reason>` in its description; ONLY
  that prefix with a non-empty reason counts). Pure file I/O + `Graph` validation, no DB.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph

  @fixtures Path.expand("../../fixtures", __DIR__)
  @actors Path.join(@fixtures, "uat/actors.yaml")

  # Per definition: where it lives, the END nodes a stalled path may close at, the node ids no
  # timeout path may ever visit, and the nodes that fail closed DIRECTLY (no higher-role task).
  @defs [
    %{
      label: "loan (QA JSON)",
      kind: :json,
      path: Path.join(@fixtures, "qa/meridian_loan_origination_process_definition.json"),
      ends: ["end-declined", "end-disbursement-held"],
      forbidden: ["create-facility", "disburse-loan", "end-disbursed"],
      direct: [
        "credit-memo-escalation-review",
        "risk-assessment-escalation-review",
        "kyc-manual-review",
        "committee-vote-cro",
        "committee-vote-director",
        "committee-vote-ceo",
        "escalate-l2-approval-to-ceo",
        "escalate-l1-approval-to-cro",
        "escalate-disburse-loan-to-loan-ops-lead"
      ]
    },
    %{
      label: "regulatory (QA JSON)",
      kind: :json,
      path:
        Path.join(@fixtures, "qa/meridian_regulatory_compliance_review_process_definition.json"),
      ends: ["end-closed", "end-reopened"],
      forbidden: ["archive-review"],
      direct: ["risk-evaluation", "remediation-subprocess", "ceo-override"]
    },
    %{
      label: "loan (simulation YAML)",
      kind: :yaml,
      path: Path.join(@fixtures, "simulation/meridian/process_claim_intake.yaml"),
      ends: ["end-declined", "end-disbursement-held"],
      forbidden: ["create-facility", "disburse-loan", "end-disbursed"],
      direct: [
        "credit-memo-escalation-review",
        "risk-assessment-escalation-review",
        "kyc-manual-review",
        "committee-vote-cro",
        "committee-vote-director",
        "committee-vote-ceo",
        "escalate-l2-approval-to-ceo",
        "escalate-l1-approval-to-cro",
        "escalate-disburse-loan-to-loan-ops-lead"
      ]
    },
    %{
      label: "regulatory (simulation YAML)",
      kind: :yaml,
      path: Path.join(@fixtures, "simulation/meridian/process_policy_binding.yaml"),
      ends: ["end-closed", "end-reopened"],
      forbidden: ["archive-review"],
      direct: ["risk-evaluation", "remediation-subprocess", "ceo-override"]
    }
  ]

  defp load(%{kind: :json, path: path}), do: path |> File.read!() |> Jason.decode!()
  defp load(%{kind: :yaml, path: path}), do: YamlElixir.read_from_file!(path)

  defp nodes(d), do: d["graph"]["nodes"]
  defp node(d, id), do: Enum.find(nodes(d), &(&1["id"] == id))
  defp attrs(n), do: n["attributes"] || %{}
  defp edges_from(d, id), do: Enum.filter(d["graph"]["edges"], &(&1["source"] == id))
  defp human(d), do: Enum.filter(nodes(d), &(&1["node_type"] == "HUMAN_TASK"))
  defp paired(d), do: Enum.filter(human(d), &pair?/1)

  defp pair?(n),
    do:
      Map.has_key?(attrs(n), "escalation_timer_duration") and
        Map.has_key?(attrs(n), "escalation_role")

  # E6: ONLY a description that starts with "Waiver:" followed by a non-empty reason.
  # (Public-shaped helper so the mutation tests below can drive it directly.)
  defp waiver?(n) do
    case n["description"] || attrs(n)["description"] do
      "Waiver:" <> reason -> String.trim(reason) != ""
      _ -> false
    end
  end

  # Same partition the engine uses (Transition.really_conditioned?/1): an edge with no real,
  # non-empty condition, or explicitly is_default: true, is a default/fallback candidate.
  defp default_edge?(e),
    do: e["is_default"] == true or not (is_binary(e["condition"]) and e["condition"] != "")

  defp timeout_edges(d, id), do: d |> edges_from(id) |> Enum.filter(&default_edge?/1)

  # The timeout walk: from the node's timeout edge, default edges through everything that is not
  # a human task / END. Returns {:human, node, visited} | {:end, id, visited}.
  defp walk(d, origin_id) do
    [timeout | _] = timeout_edges(d, origin_id)
    do_walk(d, timeout["target"], [timeout["target"]])
  end

  defp do_walk(d, id, visited) do
    n = node(d, id)

    case n["node_type"] do
      "HUMAN_TASK" ->
        {:human, n, visited}

      "END" ->
        {:end, id, visited}

      _ ->
        next = next_edge(d, id)
        refute next["target"] in visited, "cycle through #{next["target"]}"
        do_walk(d, next["target"], visited ++ [next["target"]])
    end
  end

  # Non-human, non-END nodes (service tasks, gateways, joins): the default edge, else the only one.
  defp next_edge(d, id),
    do: hd(Enum.filter(edges_from(d, id), &default_edge?/1) ++ edges_from(d, id))

  # The whole chain from a timer-pair node: [origin | escalation tasks...] and the closing END.
  defp chain(d, origin_id, acc \\ []) do
    refute origin_id in acc, "escalation chain cycles through #{origin_id}"

    case walk(d, origin_id) do
      {:end, end_id, visited} ->
        {Enum.reverse([origin_id | acc]), end_id, visited}

      {:human, next, visited} ->
        {rest, end_id, more} = chain(d, next["id"], [origin_id | acc])
        {rest, end_id, visited ++ more}
    end
  end

  defp declared_roles do
    @actors
    |> YamlElixir.read_from_file!()
    |> Map.fetch!("actors")
    |> Map.values()
    |> Enum.flat_map(&(&1["routing_roles"] || []))
    |> MapSet.new()
  end

  for def_ <- @defs do
    describe "D-ESC on #{def_.label}" do
      @describetag def: def_

      test "every HUMAN_TASK carries the escalation pair or an E6 waiver, never both", %{
        def: def_
      } do
        d = load(def_)

        for n <- human(d) do
          assert pair?(n) != waiver?(n),
                 "#{n["id"]}: must carry the escalation_timer_duration + escalation_role pair XOR a 'Waiver: <reason>' description"
        end

        assert human(d) != []
      end

      test "every pair is well formed (valid ISO-8601 duration, non-blank role)", %{def: def_} do
        d = load(def_)

        for n <- paired(d) do
          assert {:ok, secs} = Graph.parse_iso8601_duration(attrs(n)["escalation_timer_duration"])
          assert secs > 0, "#{n["id"]} duration is zero"
          assert String.trim(attrs(n)["escalation_role"]) != ""
        end
      end

      test "a timer-pair node has exactly one default edge and it is the timeout edge", %{
        def: def_
      } do
        d = load(def_)

        for n <- paired(d) do
          assert [e] = timeout_edges(d, n["id"]),
                 "#{n["id"]}: default candidates must be exactly one"

          assert e["id"] =~ ~r/^(timeout-|fallback-)/,
                 "#{n["id"]}: the default edge #{e["id"]} is not a timeout/fallback edge"
        end
      end

      test "every timeout walk ends at a higher-role human task of the declared escalation_role, or fails closed",
           %{def: def_} do
        d = load(def_)

        for n <- paired(d) do
          case walk(d, n["id"]) do
            {:human, target, _visited} ->
              refute n["id"] in def_.direct,
                     "#{n["id"]} is allowlisted as direct but reaches a human task"

              assert attrs(target)["role"] == attrs(n)["escalation_role"],
                     "#{n["id"]}: timeout reaches #{target["id"]} (#{attrs(target)["role"]}) but escalation_role is #{attrs(n)["escalation_role"]}"

              assert attrs(target)["role"] != attrs(n)["role"],
                     "#{n["id"]}: escalation is not a higher role"

            {:end, end_id, _visited} ->
              assert n["id"] in def_.direct,
                     "#{n["id"]} fails closed directly but is not in the direct allowlist"

              assert end_id in def_.ends,
                     "#{n["id"]} stalls into #{end_id}, not an allowed fail-closed END"
          end
        end
      end

      test "no timeout path ever reaches an approve / release / pay / archive-as-signed-off node",
           %{def: def_} do
        d = load(def_)

        for n <- paired(d) do
          {_chain, _end, visited} = chain(d, n["id"])
          bad = Enum.filter(visited, &(&1 in def_.forbidden))
          assert bad == [], "#{n["id"]}: timeout path reaches #{inspect(bad)}"
        end
      end

      test "stalled escalation is finite and closes fail-closed with no third level", %{def: def_} do
        d = load(def_)

        for n <- paired(d) do
          {ids, end_id, _} = chain(d, n["id"])
          assert end_id in def_.ends, "#{n["id"]} chain ends at #{end_id}"
          assert length(ids) <= 3, "#{n["id"]} chain is #{inspect(ids)}"

          last = node(d, List.last(ids))

          assert attrs(last)["escalation_role"] == attrs(last)["role"] or
                   last["id"] in def_.direct,
                 "#{last["id"]} ends the chain but is neither top-of-chain nor direct fail-closed"
        end
      end
    end
  end

  describe "the shipped mapping is pinned (BA ruling GH #2281 Meridian mapping)" do
    setup do
      loan = load(Enum.at(@defs, 0))
      reg = load(Enum.at(@defs, 1))
      {:ok, loan: loan, reg: reg}
    end

    test "loan: timer durations, escalation roles and timeout targets", %{loan: d} do
      expected = %{
        "l1-approval" => {"P2D", "role-cro", "escalate-l1-approval-to-cro"},
        "escalate-l1-approval-to-cro" => {"P2D", "role-cro", "decline-application"},
        "l2-approval" => {"P2D", "role-ceo", "escalate-l2-approval-to-ceo"},
        "escalate-l2-approval-to-ceo" => {"P2D", "role-ceo", "decline-application"},
        "disburse-loan" =>
          {"P1D", "role-loan-ops-lead", "escalate-disburse-loan-to-loan-ops-lead"},
        "escalate-disburse-loan-to-loan-ops-lead" =>
          {"P1D", "role-loan-ops-lead", "disbursement-held-notice"},
        "credit-memo-review" => {"P2D", "role-credit-director", "credit-memo-timeout"},
        "risk-assessment" => {"P2D", "role-cro", "risk-assessment-timeout"},
        "credit-memo-escalation-review" => {"P2D", "role-credit-director", "assessment-join"},
        "risk-assessment-escalation-review" => {"P2D", "role-cro", "assessment-join"},
        "kyc-manual-review" => {"P2D", "role-cro", "kyc-timeout"}
      }

      for {id, {dur, role, target}} <- expected do
        a = attrs(node(d, id))
        assert {a["escalation_timer_duration"], a["escalation_role"]} == {dur, role}, id
        assert [%{"target" => ^target}] = timeout_edges(d, id), id
      end

      # the stalled CEO escalation declines; it can only create the facility on an explicit approve
      assert [%{"id" => "e21-escalated"}] =
               d
               |> edges_from("escalate-l2-approval-to-ceo")
               |> Enum.filter(&(&1["target"] == "create-facility"))

      # the stalled disbursement escalation holds the loan: notice, then an END that is not end-disbursed
      assert [%{"target" => "end-disbursement-held"}] = edges_from(d, "disbursement-held-notice")
      assert node(d, "end-disbursement-held")["node_type"] == "END"
    end

    test "loan: escalation tasks record the same decision variable and enum as the task they escalate (E2)",
         %{loan: d} do
      enum = fn id, var ->
        get_in(attrs(node(d, id)), ["form_schema", "properties", var, "enum"])
      end

      schema = fn var ->
        for(s <- d["variable_schemas"], s["variable_key"] == var, do: s["json_schema"]["enum"])
      end

      for {origin, escalation, var} <- [
            {"l2-approval", "escalate-l2-approval-to-ceo", "l2_decision"},
            {"credit-memo-review", "credit-memo-escalation-review", "credit_decision"},
            {"risk-assessment", "risk-assessment-escalation-review", "risk_rating"}
          ] do
        assert enum.(escalation, var) == enum.(origin, var)
        assert enum.(escalation, var) != nil
        # the variable_schemas enum (ISS-1027) still admits every value the form offers
        assert [allowed] = schema.(var)
        assert enum.(escalation, var) -- allowed == []
      end
    end

    test "regulatory: ceo-override is the top of the chain and times out straight to reopen-review; P21D/P30D unchanged",
         %{reg: d} do
      assert {"P3D", "role-ceo"} ==
               {attrs(node(d, "ceo-override"))["escalation_timer_duration"],
                attrs(node(d, "ceo-override"))["escalation_role"]}

      assert [%{"target" => "reopen-review"}] = timeout_edges(d, "ceo-override")
      assert attrs(node(d, "risk-evaluation"))["escalation_timer_duration"] == "P21D"
      assert attrs(node(d, "remediation-subprocess"))["escalation_timer_duration"] == "P30D"
      assert [%{"target" => "regulatory-auto-escalation"}] = timeout_edges(d, "risk-evaluation")
      assert [%{"target" => "cro-sign-off-timeout"}] = timeout_edges(d, "findings-sign-off")
    end

    test "every definition description states the D-ESC line", %{loan: loan, reg: reg} do
      for d <- [loan, reg] do
        assert d["description"] =~ "Escalation follows D-ESC: timer -> higher role -> fail closed"
      end
    end
  end

  describe "QA definitions: roles, validator, simulation parity" do
    test "every role and escalation_role of the two QA definitions is a declared persona routing role" do
      declared = declared_roles()

      for def_ <- Enum.take(@defs, 2), n <- human(load(def_)) do
        for role <- [attrs(n)["role"], attrs(n)["escalation_role"]], role != nil do
          assert role in declared, "#{n["id"]}: #{role} is not held by any actor in actors.yaml"
        end
      end
    end

    test "both QA definitions validate clean (graph, node attributes incl. CHK-21, edge conditions)" do
      for def_ <- Enum.take(@defs, 2) do
        assert {:ok, graph} = def_ |> load() |> Map.fetch!("graph") |> Graph.from_map()
        assert %{valid: true, violations: []} = Graph.validate_graph(graph)
        assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
        assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
      end
    end

    test "the simulation YAML copies carry the same escalation pairs as the QA JSON" do
      for {json, yaml} <- [
            {Enum.at(@defs, 0), Enum.at(@defs, 2)},
            {Enum.at(@defs, 1), Enum.at(@defs, 3)}
          ] do
        j = load(json)
        y = load(yaml)

        pairs = fn d ->
          for n <- human(d), into: %{} do
            {n["id"], {attrs(n)["escalation_timer_duration"], attrs(n)["escalation_role"]}}
          end
        end

        assert pairs.(j) == pairs.(y)
      end
    end
  end

  describe "the checks themselves have teeth (mutants must be red)" do
    test "waiver? accepts only 'Waiver: <non-empty reason>'" do
      assert waiver?(%{"description" => "Waiver: long-running remediation work"})
      assert waiver?(%{"attributes" => %{"description" => "Waiver: reason"}})
      refute waiver?(%{"description" => "Waiver:"})
      refute waiver?(%{"description" => "Waiver:   "})
      refute waiver?(%{"description" => "waiver: lower case"})
      refute waiver?(%{"description" => "Waiver without colon"})
      refute waiver?(%{"description" => "see Waiver: later"})
      refute waiver?(%{})
    end

    test "dropping a pair, or removing the 'true' on a normal edge, is detected" do
      d = load(Enum.at(@defs, 0))

      no_pair =
        update_in(d, ["graph", "nodes"], fn ns ->
          Enum.map(ns, fn
            %{"id" => "l2-approval"} = n ->
              put_in(
                n,
                ["attributes"],
                Map.drop(n["attributes"], ["escalation_timer_duration", "escalation_role"])
              )

            n ->
              n
          end)
        end)

      refute pair?(node(no_pair, "l2-approval"))
      refute waiver?(node(no_pair, "l2-approval"))

      # credit-memo-review's normal edge e4 loses its 'true': two default candidates -> the first
      # unconditioned edge would be e4 (assessment-join), skipping the escalation review.
      no_true =
        update_in(d, ["graph", "edges"], fn es ->
          Enum.map(es, fn
            %{"id" => "e4"} = e -> Map.delete(e, "condition")
            e -> e
          end)
        end)

      assert length(timeout_edges(no_true, "credit-memo-review")) == 2
      assert length(timeout_edges(d, "credit-memo-review")) == 1
    end

    test "retargeting the stalled escalation to create-facility, or the wrong escalation_role, is detected" do
      d = load(Enum.at(@defs, 0))
      assert {:end, "end-declined", clean} = walk(d, "escalate-l2-approval-to-ceo")
      refute "create-facility" in clean

      bad_target =
        update_in(d, ["graph", "edges"], fn es ->
          Enum.map(es, fn
            %{"id" => "timeout-escalate-l2-approval-to-ceo"} = e ->
              %{e | "target" => "create-facility"}

            e ->
              e
          end)
        end)

      assert {:human, _, visited} = walk(bad_target, "escalate-l2-approval-to-ceo")
      assert "create-facility" in visited

      wrong_role =
        update_in(d, ["graph", "nodes"], fn ns ->
          Enum.map(ns, fn
            %{"id" => "l2-approval"} = n ->
              put_in(n, ["attributes", "escalation_role"], "role-cro")

            n ->
              n
          end)
        end)

      assert {:human, target, _} = walk(wrong_role, "l2-approval")
      assert attrs(target)["role"] != attrs(node(wrong_role, "l2-approval"))["escalation_role"]
    end
  end
end
