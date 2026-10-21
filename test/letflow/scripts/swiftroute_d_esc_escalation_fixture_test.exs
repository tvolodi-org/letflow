defmodule Letflow.Scripts.SwiftrouteDEscEscalationFixtureTest do
  @moduledoc """
  ISS-1007 / Q-989 (GH #2276) -- the BA ruling "D-ESC" (GH #2281) applied to the SwiftRoute
  definitions: "Shipment Approval" (QA JSON v1.5 + its simulation YAML copy) and "Driver Incident
  Report" (QA JSON v1.1 + its simulation YAML copy; the QA fixture and seed were added by
  ISS-1022 / Q-1004, GH #2294).
  Timer -> higher role -> fail closed.

  The engine contract this test leans on (`lib/letflow/design/req396-human-task-escalation-timer.md`
  section 4.1): when a HUMAN_TASK's `escalation_timer_duration` elapses the engine CANCELS the task
  and follows the node's FIRST unconditioned (default/fallback) outgoing edge -- conditioned edges
  are skipped. The engine does NOT check that `escalation_role` equals the role of the node that
  edge leads to, and CHK-21 only validates the pair's shape, so THIS test is the only place that
  ties them together. Hence the structural facts asserted for every timer-pair node:

    1. it has exactly ONE default candidate edge (no condition / `is_default`), and that edge is
       the timeout edge (the normal-completion edge of such a node therefore carries the constant
       condition `true` when it has no real decision condition);
    2. the "timeout walk" (the timeout edge, then default edges through service tasks, gateways)
       ends at a HUMAN_TASK whose `role` equals the origin's `escalation_role` and differs from the
       origin's own `role`, or -- only for nodes in the explicit per-definition `direct` allowlist
       (the top of the chain, E4) -- at an allowed fail-closed END;
    3. the walk never visits a release / approve / pay node, and the escalation chain is finite
       (<= 3 human tasks counting the origin, no cycle) and ends at a top-of-chain task
       (`escalation_role == role`) or an allowlisted direct fail-closed node.

  Every HUMAN_TASK carries the pair XOR an E6 waiver (`Waiver: <reason>` in its description; ONLY
  that prefix with a non-empty reason counts). Pure file I/O + `Graph` validation, no DB.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Definitions.Graph

  @fixtures Path.expand("../../fixtures", __DIR__)
  @actors Path.join(@fixtures, "uat/actors.yaml")

  # Per definition: where it lives, the END nodes a stalled path may close at, the node ids no
  # timeout path may ever visit, and the nodes that fail closed DIRECTLY (no higher-role task).
  @approval_direct ["ceo-approval"]
  @approval_forbidden ["release-shipment", "end-approved"]
  @incident_direct ["escalate-ops-assessment-to-ceo", "escalate-finance-estimate-to-ceo"]
  # the incident has no approve/release/pay outcome; a stalled branch must pass through its notice
  # (pinned in the mapping test below)
  @incident_forbidden []

  @defs [
    %{
      label: "shipment approval (QA JSON)",
      kind: :json,
      path: Path.join(@fixtures, "qa/swiftroute_process_definition.json"),
      ends: ["end-rejected"],
      forbidden: @approval_forbidden,
      direct: @approval_direct
    },
    %{
      label: "shipment approval (simulation YAML)",
      kind: :yaml,
      path: Path.join(@fixtures, "simulation/swiftroute/process_route_approval.yaml"),
      ends: ["end-rejected"],
      forbidden: @approval_forbidden,
      direct: @approval_direct
    },
    %{
      label: "driver incident report (QA JSON)",
      kind: :json,
      path: Path.join(@fixtures, "qa/swiftroute_incident_process_definition.json"),
      ends: ["end"],
      forbidden: @incident_forbidden,
      direct: @incident_direct
    },
    %{
      label: "driver incident report (simulation YAML)",
      kind: :yaml,
      path: Path.join(@fixtures, "simulation/swiftroute/process_shipment_dispatch.yaml"),
      ends: ["end"],
      forbidden: @incident_forbidden,
      direct: @incident_direct
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

  # Non-human, non-END nodes (service tasks, gateways): the default edge, else the only one.
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

      test "no timeout path ever reaches a release / approve / pay node", %{def: def_} do
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

  describe "the shipped mapping is pinned (BA ruling GH #2281 SwiftRoute mapping)" do
    setup do
      {:ok, approval: load(Enum.at(@defs, 0)), incident: load(Enum.at(@defs, 2))}
    end

    test "shipment approval: durations, roles, escalation roles and timeout targets", %{
      approval: d
    } do
      expected = %{
        # ops-review keeps its existing E7 exception PT2H and escalates to the CEO task
        "ops-review" => {"role-ops-manager", "PT2H", "role-ceo", "ceo-approval"},
        # top of chain (E4): the timeout goes straight to the fail-closed auto-reject
        "ceo-approval" => {"role-ceo", "PT4H", "role-ceo", "auto-reject"}
      }

      assert length(human(d)) == map_size(expected)

      for {id, {role, dur, esc_role, target}} <- expected do
        a = attrs(node(d, id))

        assert {a["role"], a["escalation_timer_duration"], a["escalation_role"]} ==
                 {role, dur, esc_role},
               id

        assert [%{"target" => ^target}] = timeout_edges(d, id), id
      end

      # the stalled CEO level rejects: auto-reject only leads to end-rejected, never a release
      assert [%{"target" => "end-rejected"}] = edges_from(d, "auto-reject")
      assert attrs(node(d, "ceo-approval"))["description"] =~ "stalled = fail closed"

      # the CEO's own decision edges are untouched by the timer pair (ISS-1027 enum)
      assert d
             |> edges_from("ceo-approval")
             |> Enum.reject(&default_edge?/1)
             |> Enum.map(&{&1["condition"], &1["target"]})
             |> Enum.sort() == [
               {"variables.ceo_decision == 'approve'", "release-shipment"},
               {"variables.ceo_decision == 'reject'", "auto-reject"}
             ]
    end

    test "driver incident: both tasks escalate to a role-ceo task and a stalled escalation lands on its notice",
         %{incident: d} do
      expected = %{
        "ops-assessment" =>
          {"role-ops-manager", "P1D", "role-ceo", "escalate-ops-assessment-to-ceo",
           "ops-auto-close"},
        "finance-estimate" =>
          {"role-accountant", "P1D", "role-ceo", "escalate-finance-estimate-to-ceo",
           "finance-auto-close"}
      }

      for {id, {role, dur, esc_role, esc_id, notice}} <- expected do
        a = attrs(node(d, id))

        assert {a["role"], a["escalation_timer_duration"], a["escalation_role"]} ==
                 {role, dur, esc_role},
               id

        assert [%{"target" => ^esc_id}] = timeout_edges(d, id), id

        # the CEO level: own timer, fail closed at the notice
        esc = attrs(node(d, esc_id))
        assert {esc["role"], esc["escalation_timer_duration"]} == {"role-ceo", dur}, esc_id
        assert [%{"target" => ^notice}] = timeout_edges(d, esc_id), esc_id

        # the stalled branch passes through the notice before it rejoins the flow
        assert {:end, "end", visited} = walk(d, esc_id)
        assert hd(visited) == notice
        assert "parallel-join" in visited
      end

      assert length(human(d)) == 4
    end

    test "driver incident: escalation tasks complete exactly like the task they escalate (E2)", %{
      incident: d
    } do
      # both levels' normal completion is the constant-true edge into the AND join; without the
      # `true` the first unconditioned edge on a timer fire would be the completion edge itself
      for {origin, esc} <- [
            {"ops-assessment", "escalate-ops-assessment-to-ceo"},
            {"finance-estimate", "escalate-finance-estimate-to-ceo"}
          ],
          id <- [origin, esc] do
        assert [%{"target" => "parallel-join", "condition" => "true"}] =
                 d |> edges_from(id) |> Enum.reject(&default_edge?/1),
               id
      end
    end

    test "every definition description states the D-ESC line", %{approval: a, incident: i} do
      for d <- [a, i, load(Enum.at(@defs, 1))] do
        assert d["description"] =~ "Escalation follows D-ESC: timer -> higher role -> fail closed"
      end
    end

    test "the QA Shipment Approval fixture is v1.7", %{approval: d} do
      assert d["version"] == "1.7"
    end
  end

  describe "QA definition: roles, validator, simulation parity" do
    test "every role and escalation_role of the shipment approval is a declared persona routing role" do
      declared = declared_roles()

      for n <- human(load(Enum.at(@defs, 0))),
          role <- [attrs(n)["role"], attrs(n)["escalation_role"]] do
        assert role in declared, "#{n["id"]}: #{role} is not held by any actor in actors.yaml"
      end
    end

    test "all three definitions validate clean (graph, node attributes incl. CHK-21, edge conditions)" do
      for def_ <- @defs do
        assert {:ok, graph} = def_ |> load() |> Map.fetch!("graph") |> Graph.from_map()
        assert %{valid: true, violations: []} = Graph.validate_graph(graph)
        assert %{valid: true, violations: []} = Graph.validate_node_attributes(graph)
        assert %{valid: true, violations: []} = Graph.validate_edge_conditions(graph)
      end
    end

    test "the simulation YAML copy carries the same escalation pairs as the QA JSON" do
      pairs = fn d ->
        for n <- human(d), into: %{} do
          {n["id"], {attrs(n)["escalation_timer_duration"], attrs(n)["escalation_role"]}}
        end
      end

      assert pairs.(load(Enum.at(@defs, 0))) == pairs.(load(Enum.at(@defs, 1)))
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

    test "dropping a pair, or removing the 'true' on a completion edge, is detected" do
      d = load(Enum.at(@defs, 2))

      no_pair =
        update_in(d, ["graph", "nodes"], fn ns ->
          Enum.map(ns, fn
            %{"id" => "ops-assessment"} = n ->
              put_in(
                n,
                ["attributes"],
                Map.drop(n["attributes"], ["escalation_timer_duration", "escalation_role"])
              )

            n ->
              n
          end)
        end)

      refute pair?(node(no_pair, "ops-assessment"))
      refute waiver?(node(no_pair, "ops-assessment"))

      # e6 loses its 'true': two default candidates -> the engine's FIRST unconditioned edge on a
      # timer fire would be e6 (parallel-join), skipping the escalation entirely.
      no_true =
        update_in(d, ["graph", "edges"], fn es ->
          Enum.map(es, fn
            %{"id" => "e6"} = e -> Map.delete(e, "condition")
            e -> e
          end)
        end)

      assert length(timeout_edges(no_true, "ops-assessment")) == 2
      assert length(timeout_edges(d, "ops-assessment")) == 1
    end

    test "retargeting a stalled escalation to a release path, or the wrong escalation_role, is detected" do
      d = load(Enum.at(@defs, 0))
      assert {:end, "end-rejected", clean} = walk(d, "ceo-approval")
      refute "release-shipment" in clean

      bad_target =
        update_in(d, ["graph", "edges"], fn es ->
          Enum.map(es, fn
            %{"id" => "timeout-ceo-approval"} = e -> %{e | "target" => "release-shipment"}
            e -> e
          end)
        end)

      assert {:end, "end-approved", visited} = walk(bad_target, "ceo-approval")
      assert "release-shipment" in visited

      wrong_role =
        update_in(d, ["graph", "nodes"], fn ns ->
          Enum.map(ns, fn
            %{"id" => "ops-review"} = n ->
              put_in(n, ["attributes", "escalation_role"], "role-ops-manager")

            n ->
              n
          end)
        end)

      assert {:human, target, _} = walk(wrong_role, "ops-review")

      assert attrs(target)["role"] !=
               attrs(node(wrong_role, "ops-review"))["escalation_role"]
    end
  end
end
