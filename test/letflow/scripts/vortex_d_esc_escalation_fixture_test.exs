defmodule Letflow.Scripts.VortexDEscEscalationFixtureTest do
  @moduledoc """
  ISS-1002 / Q-984 (GH #2271) -- the BA ruling "D-ESC" (GH #2281) applied to the three QA Vortex
  definitions (Production Order Release v1.5, Supplier Quality Deviation v1.6, 8D Corrective
  Action v1.1) and to the two simulation YAML copies: timer -> higher role -> fail closed.

  The engine contract this test leans on (`lib/letflow/design/req396-human-task-escalation-timer.md`
  section 4.1): when a HUMAN_TASK's `escalation_timer_duration` elapses the engine CANCELS the task
  and follows the node's FIRST unconditioned (default/fallback) outgoing edge -- conditioned edges
  are skipped. The engine does NOT check that `escalation_role` equals the role of the node that
  edge leads to, and CHK-21 only validates the pair's shape, so THIS test is the only place that
  ties them together. Hence the structural facts asserted for every timer-pair node:

    1. it has exactly ONE default candidate edge (no condition / `is_default`), and that edge is
       the timeout edge (the normal-completion edge of such a node therefore carries the constant
       condition `true`);
    2. the "timeout walk" (the timeout edge, then default edges through service tasks, gateways and
       sub-processes) ends at a HUMAN_TASK whose `role` equals the origin's `escalation_role` and
       differs from the origin's own `role`, or -- only for nodes in the explicit per-definition
       `direct` allowlist -- at an allowed fail-closed END;
    3. the walk never visits a release / approve / assign / pay node, and the escalation chain is
       finite (<= 3 human tasks counting the origin, no cycle) and ends at a top-of-chain task
       (`escalation_role == role`) or an allowlisted direct fail-closed node.

  Every HUMAN_TASK carries the pair XOR an E6 waiver (`Waiver: <reason>` in its description; ONLY
  that prefix with a non-empty reason counts) XOR a non-cancelling reminder (`reminder_timer_duration`
  + `reminder_role`, REQ-494 / GH #2553 / GH #2325 AC3) for long-running tasks. Pure file I/O + `Graph` validation, no DB.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph

  @fixtures Path.expand("../../fixtures", __DIR__)
  @actors Path.join(@fixtures, "uat/actors.yaml")

  # Per definition: where it lives, the END nodes a stalled path may close at, the node ids no
  # timeout path may ever visit, and the nodes that fail closed DIRECTLY (no higher-role task).
  @order_direct ["escalate-to-ceo", "escalate-budget-approval-to-finance-director"]
  @order_forbidden ["assign-line", "notify-planner", "end-released"]
  @deviation_direct ["escalate-severity-classification-to-ceo"]
  @deviation_forbidden [
    "release-quarantine",
    "end-false-positive",
    "supplier-warning",
    "supplier-notification"
  ]

  @defs [
    %{
      label: "order release (QA JSON)",
      kind: :json,
      path: Path.join(@fixtures, "qa/vortex_production_order_release_process_definition.json"),
      ends: ["end-rejected"],
      forbidden: @order_forbidden,
      direct: @order_direct
    },
    %{
      label: "supplier deviation (QA JSON)",
      kind: :json,
      path: Path.join(@fixtures, "qa/vortex_supplier_quality_deviation_process_definition.json"),
      ends: ["end-closed"],
      forbidden: @deviation_forbidden,
      direct: @deviation_direct
    },
    %{
      label: "8D corrective action (QA JSON)",
      kind: :json,
      path: Path.join(@fixtures, "qa/vortex_8d_corrective_action_definition.json"),
      ends: [],
      forbidden: [],
      direct: []
    },
    %{
      label: "order release (simulation YAML)",
      kind: :yaml,
      path: Path.join(@fixtures, "simulation/vortex/process_quality_check.yaml"),
      ends: ["end-rejected"],
      forbidden: @order_forbidden,
      direct: @order_direct
    },
    %{
      label: "supplier deviation (simulation YAML)",
      kind: :yaml,
      path: Path.join(@fixtures, "simulation/vortex/process_work_order.yaml"),
      ends: ["end-closed"],
      forbidden: @deviation_forbidden,
      direct: @deviation_direct
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
  defp waiver?(n) do
    case n["description"] || attrs(n)["description"] do
      "Waiver:" <> reason -> String.trim(reason) != ""
      _ -> false
    end
  end

  # REQ-494: the alternative to a waiver for long-running tasks -- a well-formed reminder pair.
  defp reminder?(n) do
    a = attrs(n)

    with d when is_binary(d) <- a["reminder_timer_duration"],
         {:ok, secs} when secs > 0 <- Graph.parse_iso8601_duration(d),
         r when is_binary(r) <- a["reminder_role"] do
      String.trim(r) != ""
    else
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

  # Non-human, non-END nodes (service tasks, gateways, sub-processes): the default edge, else the
  # only one.
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

      test "every HUMAN_TASK carries the escalation pair, an E6 waiver or a reminder, exactly one",
           %{
             def: def_
           } do
        d = load(def_)

        for n <- human(d) do
          assert Enum.count([pair?(n), waiver?(n), reminder?(n)], & &1) == 1,
                 "#{n["id"]}: must carry exactly one of the escalation_timer_duration + escalation_role pair, a 'Waiver: <reason>' description, or a reminder_timer_duration + reminder_role pair"
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

      test "no timeout path ever reaches a release / approve / assign node", %{def: def_} do
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

  describe "the shipped mapping is pinned (BA ruling GH #2281 Vortex mapping)" do
    setup do
      {:ok,
       order: load(Enum.at(@defs, 0)), dev: load(Enum.at(@defs, 1)), d8: load(Enum.at(@defs, 2))}
    end

    test "order release: durations, escalation roles and timeout targets", %{order: d} do
      expected = %{
        "capacity-review" => {"PT4H", "role-ceo", "escalate-to-ceo"},
        "escalate-to-ceo" => {"PT4H", "role-ceo", "auto-reject-order"},
        "budget-approval" =>
          {"P2D", "role-finance-director", "escalate-budget-approval-to-finance-director"},
        "escalate-budget-approval-to-finance-director" =>
          {"P2D", "role-finance-director", "auto-reject-order"}
      }

      for {id, {dur, role, target}} <- expected do
        a = attrs(node(d, id))
        assert {a["escalation_timer_duration"], a["escalation_role"]} == {dur, role}, id
        assert [%{"target" => ^target}] = timeout_edges(d, id), id
      end

      assert attrs(node(d, "capacity-review"))["role"] == "role-production-manager"
      assert attrs(node(d, "budget-approval"))["role"] == "role-controller"

      assert attrs(node(d, "escalate-budget-approval-to-finance-director"))["role"] ==
               "role-finance-director"

      # the stalled escalations reject; neither the CEO level nor the stall can assign a line
      assert [%{"target" => "end-rejected"}] = edges_from(d, "auto-reject-order")
    end

    test "order release: escalation tasks take the same decision as the task they escalate (E2)",
         %{order: d} do
      conditions = fn id ->
        d
        |> edges_from(id)
        |> Enum.map(& &1["condition"])
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
      end

      assert conditions.("escalate-to-ceo") == conditions.("capacity-review")

      assert conditions.("escalate-budget-approval-to-finance-director") ==
               conditions.("budget-approval")

      assert conditions.("budget-approval") != []

      # an explicit approve by the CEO level lands exactly where the original's approve does
      target_of = fn id, cond ->
        for e <- edges_from(d, id), e["condition"] == cond, do: e["target"]
      end

      assert target_of.(
               "escalate-budget-approval-to-finance-director",
               "variables.budget_decision == 'approve'"
             ) ==
               target_of.("budget-approval", "variables.budget_decision == 'approve'")

      assert target_of.(
               "escalate-budget-approval-to-finance-director",
               "variables.budget_decision == 'reject'"
             ) ==
               ["auto-reject-order"]
    end

    test "supplier deviation: severity-classification escalates to role-ceo, a stalled escalation sets severity critical and goes to the 8D",
         %{dev: d} do
      a = attrs(node(d, "severity-classification"))

      assert {a["role"], a["escalation_timer_duration"], a["escalation_role"]} ==
               {"role-quality-manager", "PT4H", "role-ceo"}

      assert [%{"target" => "escalate-severity-classification-to-ceo"}] =
               timeout_edges(d, "severity-classification")

      assert [%{"target" => "default-to-critical"}] =
               timeout_edges(d, "escalate-severity-classification-to-ceo")

      # the stalled path sets severity=critical EXPLICITLY (ISS-1003) and reaches the 8D sub-process
      endpoint = attrs(node(d, "default-to-critical"))["endpoint"]
      assert URI.decode_query(URI.parse(endpoint).query) == %{"severity" => "critical"}
      assert {:end, "end-closed", visited} = walk(d, "escalate-severity-classification-to-ceo")
      assert "corrective-action-subprocess" in visited

      # both classification levels continue to the false-positive check on normal completion
      for id <- ["severity-classification", "escalate-severity-classification-to-ceo"] do
        assert [%{"target" => "false-positive-check", "condition" => "true"}] =
                 d |> edges_from(id) |> Enum.reject(&default_edge?/1)
      end
    end

    test "8D corrective action: the human task carries the P14D reminder, no waiver, no timer pair",
         %{d8: d} do
      assert [n] = human(d)
      assert n["id"] == "corrective-action-8d"
      assert attrs(n)["reminder_timer_duration"] == "P14D"
      assert attrs(n)["reminder_role"] == "role-procurement-manager"
      assert reminder?(n)
      refute waiver?(n)
      refute pair?(n)
      refute attrs(n)["description"] =~ "Waiver"
      assert d["version"] == "1.3"
    end

    test "every definition description states the D-ESC line", %{order: o, dev: v, d8: e} do
      for d <- [o, v, e] do
        assert d["description"] =~ "Escalation follows D-ESC: timer -> higher role -> fail closed"
      end
    end
  end

  describe "QA definitions: roles, validator, simulation parity" do
    test "every role and escalation_role of the three QA definitions is a declared persona routing role" do
      declared = declared_roles()

      for def_ <- Enum.take(@defs, 3), n <- human(load(def_)) do
        for role <- [attrs(n)["role"], attrs(n)["escalation_role"], attrs(n)["reminder_role"]],
            role != nil do
          assert role in declared, "#{n["id"]}: #{role} is not held by any actor in actors.yaml"
        end
      end
    end

    test "all three QA definitions validate clean (graph, node attributes incl. CHK-21, edge conditions)" do
      for def_ <- Enum.take(@defs, 3) do
        assert {:ok, graph} = def_ |> load() |> Map.fetch!("graph") |> Graph.from_map()
        assert %{valid: true, violations: []} = Graph.validate_graph(graph)
        assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
        assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
      end
    end

    test "the simulation YAML copies carry the same escalation pairs as the QA JSON" do
      for {json, yaml} <- [
            {Enum.at(@defs, 0), Enum.at(@defs, 3)},
            {Enum.at(@defs, 1), Enum.at(@defs, 4)}
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

    test "reminder? accepts only a valid positive duration with a non-blank role (GH #2325 AC3)" do
      n = fn a -> %{"attributes" => a} end
      assert reminder?(n.(%{"reminder_timer_duration" => "P14D", "reminder_role" => "r"}))
      refute reminder?(n.(%{"reminder_timer_duration" => "P14D"}))
      refute reminder?(n.(%{"reminder_role" => "r"}))
      refute reminder?(n.(%{"reminder_timer_duration" => "P14D", "reminder_role" => " "}))
      refute reminder?(n.(%{"reminder_timer_duration" => "bogus", "reminder_role" => "r"}))
      refute reminder?(n.(%{"reminder_timer_duration" => "PT0S", "reminder_role" => "r"}))
    end

    test "dropping a pair, or removing the 'true' on a normal edge, is detected" do
      d = load(Enum.at(@defs, 1))

      no_pair =
        update_in(d, ["graph", "nodes"], fn ns ->
          Enum.map(ns, fn
            %{"id" => "severity-classification"} = n ->
              put_in(
                n,
                ["attributes"],
                Map.drop(n["attributes"], ["escalation_timer_duration", "escalation_role"])
              )

            n ->
              n
          end)
        end)

      refute pair?(node(no_pair, "severity-classification"))
      refute waiver?(node(no_pair, "severity-classification"))

      # e2 loses its 'true': two default candidates -> the engine's FIRST unconditioned edge on a
      # timer fire would be e2 (false-positive-check), skipping the escalation.
      no_true =
        update_in(d, ["graph", "edges"], fn es ->
          Enum.map(es, fn
            %{"id" => "e2"} = e -> Map.delete(e, "condition")
            e -> e
          end)
        end)

      assert length(timeout_edges(no_true, "severity-classification")) == 2
      assert length(timeout_edges(d, "severity-classification")) == 1
    end

    test "retargeting a stalled escalation to a release path, or the wrong escalation_role, is detected" do
      d = load(Enum.at(@defs, 0))

      assert {:end, "end-rejected", clean} =
               walk(d, "escalate-budget-approval-to-finance-director")

      refute "assign-line" in clean

      bad_target =
        update_in(d, ["graph", "edges"], fn es ->
          Enum.map(es, fn
            %{"id" => "timeout-escalate-budget-approval-to-finance-director"} = e ->
              %{e | "target" => "assign-line"}

            e ->
              e
          end)
        end)

      assert {:end, "end-released", visited} =
               walk(bad_target, "escalate-budget-approval-to-finance-director")

      assert "assign-line" in visited

      wrong_role =
        update_in(d, ["graph", "nodes"], fn ns ->
          Enum.map(ns, fn
            %{"id" => "budget-approval"} = n ->
              put_in(n, ["attributes", "escalation_role"], "role-controller")

            n ->
              n
          end)
        end)

      assert {:human, target, _} = walk(wrong_role, "budget-approval")

      assert attrs(target)["role"] !=
               attrs(node(wrong_role, "budget-approval"))["escalation_role"]
    end
  end
end
