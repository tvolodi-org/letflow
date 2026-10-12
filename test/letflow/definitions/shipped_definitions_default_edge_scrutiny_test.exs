defmodule Letflow.Definitions.ShippedDefinitionsDefaultEdgeScrutinyTest do
  @moduledoc """
  ISS-0998 / Q-980 drift test: a decision's DEFAULT edge ("nothing above matched") must
  never lead to the same place as its "clear"-style branch when the gateway also has a
  manual-review branch -- an unknown or absent value would otherwise be treated as
  cleared and skip the review (the `e9-default` bug in the QA Meridian loan fixture:
  `kyc-routing` default -> `assessment-join`, same as `kyc_status == 'clear'`, skipping
  `kyc-manual-review`). The default must fail toward MORE scrutiny.

  The rule (deliberately conservative -- it only fires on this exact shape), per
  EXCLUSIVE_GATEWAY node with a default edge:

    * review targets = targets of its non-default edges whose target node is a
      HUMAN_TASK whose id contains "review";
    * clear targets  = targets of its non-default edges whose condition compares a
      variable `== 'clear' | 'cleared' | 'approved' | 'pass' | 'passed' | 'ok'`,
      excluding any review target;
    * VIOLATION iff review targets are non-empty AND the default edge's target is one
      of the clear targets.

  Known blind spots (deliberate, to avoid false positives): a review node whose id lacks "review",
  or a clear-style condition phrased outside the regex above, is not detected here; the Meridian
  fixture test pins the kyc-routing shape by exact id/target/condition instead.

  ## ISS-1001 / Q-983 second rule: a default never leads to an irreversible action

  The `fallback-l2-approval` bug (Meridian loan, `l2-approval` -> `create-facility` with no
  condition: a missing/unrecognised/timed-out `l2_decision` created the loan = approval by
  default). Principle: defaults route toward MORE scrutiny and never toward the irreversible
  (approving / creating / paying out) branch. Per node `N` (any node type), an outgoing edge
  `E` is a *default-style edge* iff

    * `E.is_default == true`, OR
    * `E` has NO `condition` AND `N` has at least one OTHER outgoing edge WITH a condition
      (an unconditioned edge beside conditioned siblings is what the engine takes when none of
      them holds -- the `fallback-*` edges of the QA fixtures; a `timeout-*` edge counts only if its
      node also has a conditioned sibling, so the loan `timeout-*` paths via `assessment-join` are NOT covered).

  `E` is a VIOLATION iff it is default-style and its target node's id matches
  `@irreversible_target` (id starts with `create-`, `disburse-`, `release-`, `payout-`,
  `transfer-`, `execute-`, `activate-`, `provision-`, `refund-`, `issue-` or `archive-` (the
  last added by ISS-1018 for `archive-review`, which closes a review as signed off), or is
  exactly one of those words) -- ANY node type, so a SERVICE_TASK that creates/disburses and a HUMAN_TASK
  that disburses (`disburse-loan`) are both covered.

  ## ISS-1018 / Q-1000 third rule: a default never shares the target of an approve/close branch

  The `fallback-ceo-override` bug (Meridian regulatory review: `ceo-override` -> `archive-review`
  with no condition, the same target as `ceo_decision == 'sign_off'`: a missing/unrecognised
  decision closed the review without sign-off). A default-style edge (same definition as above)
  is a VIOLATION iff its target equals the target of a SIBLING conditioned edge whose condition
  compares a variable `== 'approve' | 'approved' | 'sign_off' | 'signed_off' | 'accept' |
  'accepted' | 'close' | 'closed'` (`@approving_condition`). Independent of the target's id, so it
  also catches approving defaults into nodes the id list above does not know. Blind spot: an
  approving condition phrased outside that regex (`>=`, `in`, `!=`) is not seen. Exception
  (BA-accepted, ISS-1001): a target that is a HUMAN_TASK is not a violation -- a default into a
  further human task is escalation to more scrutiny (`fallback-l1-approval` ->
  `escalate-l1-approval-to-cro`, a further HUMAN_TASK; Q-1051 / GH #2395 retargeted it from
  `l2-approval`, which shares its target with the `l1_decision == 'approve'` branch by design).

  Blind spots of the second rule (deliberate): an irreversible action whose id lacks those prefixes (e.g. `book-loan`,
  `ceo-approval`) is not detected -- approval HUMAN_TASKs (`*-approval`) are intentionally NOT in
  the list, because a default into a human approval task is escalation (more scrutiny), not the
  irreversible act itself; the action is judged by id only, not by the node's endpoint/attributes; a
  default reaching an irreversible node only INDIRECTLY (default -> X -> create-facility) is not
  followed (the direct edge is what ISS-1001 and its issue acceptance criteria name; the Meridian
  fixture test additionally graph-walks `l2-approval` with the real condition evaluator).

  Discovery is by structure over the same set as `ShippedDefinitionsValidationTest`
  (`priv/**/*.json`, `test/fixtures/qa/*.json`, `test/fixtures/simulation/**/process_*.yaml`).
  Pure file I/O, `async: true`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @root Path.expand("../../..", __DIR__)
  @clear_condition ~r/==\s*'(clear|cleared|approved|pass|passed|ok)'/i
  @irreversible_target ~r/^(create|disburse|release|payout|transfer|execute|activate|provision|refund|issue|archive)([-_].*)?$/

  @approving_condition ~r/==\s*'(approve|approved|sign_off|signed_off|accept|accepted|close|closed)'/i

  # Every entry MUST name the queue task that removes it; add none silently (ORCH rule). Entries
  # are exactly {definition label, edge id, target id}. Empty: the vortex Q-982 finding is a
  # different shape (a capacity-rejected order reaches `end-released`) and is not flagged here.
  @allowlist []

  # Returns [{gateway_id, default_edge_id, clear_target}] for each violating gateway.
  defp default_edge_violations(%{"nodes" => nodes, "edges" => edges}) do
    nodes_by_id = Map.new(nodes, &{&1["id"], &1})

    for %{"node_type" => "EXCLUSIVE_GATEWAY", "id" => gw} <- nodes,
        outgoing = Enum.filter(edges, &(&1["source"] == gw)),
        [default | _] <- [Enum.filter(outgoing, &(&1["is_default"] == true))],
        conditional = Enum.reject(outgoing, &(&1["is_default"] == true)),
        review_targets = review_targets(conditional, nodes_by_id),
        review_targets != [],
        clear_targets = clear_targets(conditional, review_targets),
        default["target"] in clear_targets do
      {gw, default["id"], default["target"]}
    end
  end

  # ISS-1001 rule: returns [{node_id, edge_id, target_id}] for default-style edges into an
  # irreversible-action node (see moduledoc).
  defp irreversible_default_violations(%{"nodes" => nodes, "edges" => edges}) do
    node_ids = MapSet.new(nodes, & &1["id"])

    for %{"id" => source} <- nodes,
        outgoing = Enum.filter(edges, &(&1["source"] == source)),
        edge <- outgoing,
        default_style?(edge, outgoing),
        edge["target"] in node_ids,
        edge["target"] =~ @irreversible_target do
      {source, edge["id"], edge["target"]}
    end
  end

  # ISS-1018 rule: [{node_id, edge_id, target_id}] for default-style edges whose target is
  # also the target of a sibling edge conditioned on an approve/sign-off/close value.
  defp approving_default_violations(%{"nodes" => nodes, "edges" => edges}) do
    human_tasks =
      for %{"node_type" => "HUMAN_TASK", "id" => id} <- nodes, into: MapSet.new(), do: id

    for %{"id" => source} <- nodes,
        outgoing = Enum.filter(edges, &(&1["source"] == source)),
        edge <- outgoing,
        default_style?(edge, outgoing),
        edge["target"] not in human_tasks,
        edge["target"] in approving_targets(edge, outgoing) do
      {source, edge["id"], edge["target"]}
    end
  end

  defp approving_targets(default_edge, outgoing) do
    for sibling <- outgoing,
        sibling["id"] != default_edge["id"],
        conditioned?(sibling),
        sibling["condition"] =~ @approving_condition,
        do: sibling["target"]
  end

  defp default_style?(edge, outgoing) do
    edge["is_default"] == true or
      (not conditioned?(edge) and
         Enum.any?(outgoing, &(&1["id"] != edge["id"] and conditioned?(&1))))
  end

  defp conditioned?(edge),
    do: is_binary(edge["condition"]) and String.trim(edge["condition"]) != ""

  defp review_targets(conditional, nodes_by_id) do
    conditional
    |> Enum.map(& &1["target"])
    |> Enum.filter(fn t ->
      node = nodes_by_id[t]
      node != nil and node["node_type"] == "HUMAN_TASK" and String.contains?(t, "review")
    end)
    |> Enum.uniq()
  end

  defp clear_targets(conditional, review_targets) do
    conditional
    |> Enum.filter(&(is_binary(&1["condition"]) and &1["condition"] =~ @clear_condition))
    |> Enum.map(& &1["target"])
    |> Enum.reject(&(&1 in review_targets))
    |> Enum.uniq()
  end

  defp discover do
    json_files =
      Path.wildcard(Path.join(@root, "priv/**/*.json")) ++
        Path.wildcard(Path.join(@root, "test/fixtures/qa/*.json"))

    yaml_files = Path.wildcard(Path.join(@root, "test/fixtures/simulation/**/process_*.yaml"))

    decoded =
      Enum.map(json_files, &{&1, &1 |> File.read!() |> Jason.decode!()}) ++
        Enum.map(yaml_files, &{&1, YamlElixir.read_from_file!(&1)})

    Enum.flat_map(decoded, fn {path, doc} ->
      rel = Path.relative_to(path, @root)

      case doc do
        %{"definitions" => defs} when is_list(defs) ->
          for {entry, i} <- Enum.with_index(defs),
              graph?(entry),
              do: {"#{rel}[#{i}]", entry["graph"]}

        doc when is_map(doc) ->
          if graph?(doc), do: [{rel, doc["graph"]}], else: []

        _ ->
          []
      end
    end)
  end

  defp graph?(%{"graph" => %{"nodes" => n, "edges" => e}}) when is_list(n) and is_list(e),
    do: true

  defp graph?(_), do: false

  defp gateway_graph(default_target) do
    %{
      "nodes" => [
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
        %{"id" => "kyc-manual-review", "node_type" => "HUMAN_TASK"}
      ],
      "edges" => [
        %{
          "id" => "a",
          "source" => "gw",
          "target" => "join",
          "condition" => "variables.s == 'clear'"
        },
        %{
          "id" => "b",
          "source" => "gw",
          "target" => "kyc-manual-review",
          "condition" => "variables.s == 'hit'"
        },
        %{"id" => "d", "source" => "gw", "target" => default_target, "is_default" => true}
      ]
    }
  end

  describe "the rule itself (synthetic graphs)" do
    test "default to the same target as the clear branch is a violation (the e9-default shape)" do
      assert [{"gw", "d", "join"}] = default_edge_violations(gateway_graph("join"))
    end

    test "default to the manual-review branch is clean" do
      assert [] = default_edge_violations(gateway_graph("kyc-manual-review"))
    end

    test "a gateway with no manual-review branch is not constrained (rule is conservative)" do
      graph = gateway_graph("join")

      graph =
        update_in(graph["edges"], fn edges -> Enum.reject(edges, &(&1["id"] == "b")) end)

      assert [] = default_edge_violations(graph)
    end
  end

  describe "every shipped definition" do
    test "discovery finds the known definitions" do
      assert length(discover()) >= 12
    end

    test "no gateway's default edge leads to its 'clear' branch while a manual-review branch exists" do
      violations =
        for {label, graph} <- discover(),
            v <- default_edge_violations(graph),
            do: {label, v}

      assert violations == [],
             "default edge routes like the clear branch (skips manual review):\n" <>
               inspect(violations, pretty: true)
    end
  end

  describe "ISS-1001 rule itself (synthetic graphs)" do
    defp irreversible_graph(edge_overrides) do
      %{
        "nodes" => [
          %{"id" => "task", "node_type" => "HUMAN_TASK"},
          %{"id" => "create-facility", "node_type" => "SERVICE_TASK"},
          %{"id" => "disburse-loan", "node_type" => "HUMAN_TASK"},
          %{"id" => "decline-application", "node_type" => "SERVICE_TASK"},
          %{"id" => "next-approval", "node_type" => "HUMAN_TASK"}
        ],
        "edges" =>
          [
            %{
              "id" => "ok",
              "source" => "task",
              "target" => "create-facility",
              "condition" => "variables.d == 'approve'"
            }
          ] ++ edge_overrides
      }
    end

    test "an unconditioned edge beside conditioned siblings into create-facility is a violation (the fallback-l2-approval shape)" do
      graph =
        irreversible_graph([%{"id" => "fb", "source" => "task", "target" => "create-facility"}])

      assert [{"task", "fb", "create-facility"}] = irreversible_default_violations(graph)
    end

    test "an is_default edge into disburse-loan is a violation" do
      graph =
        irreversible_graph([
          %{"id" => "dflt", "source" => "task", "target" => "disburse-loan", "is_default" => true}
        ])

      assert [{"task", "dflt", "disburse-loan"}] = irreversible_default_violations(graph)
    end

    test "a default edge to decline-application or to an approval human task is clean" do
      graph =
        irreversible_graph([
          %{"id" => "fb", "source" => "task", "target" => "decline-application"},
          %{"id" => "dflt", "source" => "task", "target" => "next-approval", "is_default" => true}
        ])

      assert [] = irreversible_default_violations(graph)
    end

    test "a sole unconditioned edge (no conditioned siblings) into create-facility is not a default-style edge" do
      graph = %{
        "nodes" => [
          %{"id" => "a", "node_type" => "SERVICE_TASK"},
          %{"id" => "create-facility", "node_type" => "SERVICE_TASK"}
        ],
        "edges" => [%{"id" => "e", "source" => "a", "target" => "create-facility"}]
      }

      assert [] = irreversible_default_violations(graph)
    end
  end

  describe "ISS-1018 rule itself (synthetic graphs)" do
    defp approving_graph(default_target) do
      %{
        "nodes" => [
          %{"id" => "ceo-override", "node_type" => "HUMAN_TASK"},
          %{"id" => "close-it", "node_type" => "SERVICE_TASK"},
          %{"id" => "reopen-it", "node_type" => "SERVICE_TASK"}
        ],
        "edges" => [
          %{
            "id" => "a",
            "source" => "ceo-override",
            "target" => "close-it",
            "condition" => "variables.ceo_decision == 'sign_off'"
          },
          %{
            "id" => "b",
            "source" => "ceo-override",
            "target" => "reopen-it",
            "condition" => "variables.ceo_decision == 'reject_and_reopen'"
          },
          %{"id" => "fb", "source" => "ceo-override", "target" => default_target}
        ]
      }
    end

    test "a fallback to the same target as the sign_off branch is a violation, even for an id the irreversible list does not know" do
      assert [{"ceo-override", "fb", "close-it"}] =
               approving_default_violations(approving_graph("close-it"))
    end

    test "a fallback to a further human task (escalation) is clean even if an approve branch shares it" do
      graph = approving_graph("reopen-it")

      graph =
        graph
        |> update_in(
          ["nodes"],
          &[
            %{"id" => "close-it", "node_type" => "HUMAN_TASK"}
            | Enum.reject(&1, fn n -> n["id"] == "close-it" end)
          ]
        )
        |> update_in(
          ["edges"],
          &(&1 ++ [%{"id" => "fb2", "source" => "ceo-override", "target" => "close-it"}])
        )

      assert [] = approving_default_violations(graph)
    end

    test "a fallback to the reject/reopen branch is clean" do
      assert [] = approving_default_violations(approving_graph("reopen-it"))
    end
  end

  describe "ISS-1018: every shipped definition" do
    test "no default-style edge shares its target with an approve/sign-off/close branch" do
      violations =
        for {label, graph} <- discover(),
            {node, edge, target} <- approving_default_violations(graph),
            do: {label, node, edge, target}

      assert violations == [],
             "a default / unconditioned fallback edge leads to the same target as an " <>
               "approving branch (approval by default):\n" <> inspect(violations, pretty: true)
    end
  end

  describe "ISS-1001: every shipped definition" do
    test "no default-style edge leads to an irreversible action node (create-/disburse-/release-/...)" do
      violations =
        for {label, graph} <- discover(),
            {node, edge, target} <- irreversible_default_violations(graph),
            {label, edge, target} not in @allowlist,
            do: {label, node, edge, target}

      assert violations == [],
             "a default / unconditioned fallback edge leads to an irreversible action " <>
               "(approval by default); defaults must route toward MORE scrutiny:
" <>
               inspect(violations, pretty: true)
    end
  end
end
