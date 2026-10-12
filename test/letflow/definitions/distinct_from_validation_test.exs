defmodule Letflow.Definitions.DistinctFromValidationTest do
  @moduledoc """
  Pure unit tests for REQ-464's graph checks 1-3 (REQ-459 design sections 1.2 and 1.5), both run
  by `Graph.validate_node_attributes/1`. See `test/specs/REQ-464.md`.

    * check 1 (CHK-26 shape): `:invalid_distinct_from`, `:distinct_from_on_non_human_task`,
      `:distinct_from_self_reference`
    * check 2 (CHK-26 existence): `:distinct_from_unknown_node`, `:distinct_from_not_human_task`
    * check 3 (CHK-27 position): `:distinct_from_downstream_only`

  Every "minimal violating definition" asserts the WHOLE violation list of
  `validate_node_attributes/1`, so a second unrelated violation (or a second code) fails the test.

  `async: true`, no I/O, no clock, no randomness. No helper has a default argument (ISS-0069).
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph

  @new_codes [
    :invalid_distinct_from,
    :distinct_from_on_non_human_task,
    :distinct_from_self_reference,
    :distinct_from_unknown_node,
    :distinct_from_not_human_task,
    :distinct_from_downstream_only
  ]

  # --- builders -------------------------------------------------------------------------

  defp node(id, type), do: %{"id" => id, "node_type" => type}
  defp node(id, type, attrs), do: %{"id" => id, "node_type" => type, "attributes" => attrs}

  defp human(id), do: node(id, "HUMAN_TASK", %{"role" => "role-" <> id})

  defp df(id, listed),
    do: node(id, "HUMAN_TASK", %{"role" => "role-" <> id, "distinct_from" => listed})

  defp service(id), do: node(id, "SERVICE_TASK", service_attrs())

  defp service_df(id, listed),
    do: node(id, "SERVICE_TASK", Map.put(service_attrs(), "distinct_from", listed))

  defp service_attrs, do: %{"endpoint" => "https://x.test", "timeout_ms" => 1000}

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp cond_edge(id, source, target),
    do: %{
      "id" => id,
      "source" => source,
      "target" => target,
      "condition" => "variables.k == \"a\""
    }

  defp default_edge(id, source, target),
    do: %{"id" => id, "source" => source, "target" => target, "is_default" => true}

  defp build!(nodes, edges) do
    assert {:ok, graph} = Graph.from_map(%{"nodes" => nodes, "edges" => edges})
    graph
  end

  # start -> task_nodes (in order) -> end
  defp chain(task_nodes) do
    ids = ["start"] ++ Enum.map(task_nodes, & &1["id"]) ++ ["end"]

    edges =
      ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {[s, t], i} -> edge("c#{i}", s, t) end)

    build!([node("start", "START")] ++ task_nodes ++ [node("end", "END")], edges)
  end

  # start -> split -> branch_nodes (in parallel) -> join -> end
  defp fork(branch_nodes) do
    ids = Enum.map(branch_nodes, & &1["id"])

    build!(
      [node("start", "START"), node("split", "PARALLEL_GATEWAY")] ++
        branch_nodes ++ [node("join", "PARALLEL_GATEWAY"), node("end", "END")],
      [edge("e0", "start", "split")] ++
        Enum.map(ids, &edge("s-#{&1}", "split", &1)) ++
        Enum.map(ids, &edge("j-#{&1}", &1, "join")) ++
        [edge("e9", "join", "end")]
    )
  end

  # start -> gw -> (cond) x -> end-x | (default) y -> end-y : mutually exclusive branches
  defp exclusive(x, y) do
    build!(
      [
        node("start", "START"),
        node("gw", "EXCLUSIVE_GATEWAY"),
        x,
        y,
        node("end-x", "END"),
        node("end-y", "END")
      ],
      [
        edge("e0", "start", "gw"),
        cond_edge("e1", "gw", x["id"]),
        default_edge("e2", "gw", y["id"]),
        edge("e3", x["id"], "end-x"),
        edge("e4", y["id"], "end-y")
      ]
    )
  end

  # start -> a -> b -> gw -> (cond) a | (default) end : a and b have a path both ways
  defp loop(a, b) do
    build!(
      [node("start", "START"), a, b, node("gw", "EXCLUSIVE_GATEWAY"), node("end", "END")],
      [
        edge("e0", "start", a["id"]),
        edge("e1", a["id"], b["id"]),
        edge("e2", b["id"], "gw"),
        cond_edge("e3", "gw", a["id"]),
        default_edge("e4", "gw", "end")
      ]
    )
  end

  # start -> main -> end, plus orphan nodes / edges not reachable from start
  defp with_orphans(main, orphan_nodes, orphan_edges) do
    build!(
      [node("start", "START"), main, node("end", "END")] ++ orphan_nodes,
      [edge("e0", "start", main["id"]), edge("e1", main["id"], "end")] ++ orphan_edges
    )
  end

  defp violations(graph), do: Graph.validate_node_attributes(graph).violations
  defp codes(graph), do: Enum.map(violations(graph), & &1.code)

  # Exactly one violation: the given code, naming the node id and (when given) the listed id.
  defp assert_single(graph, code, node_id, listed) do
    assert [violation] = violations(graph)
    assert violation.code == code
    assert violation.message =~ "'#{node_id}'"
    if listed, do: assert(violation.message =~ "'#{listed}'")
    violation
  end

  # =======================================================================================
  # Check 1 -- CHK-26 shape
  # =======================================================================================

  describe "check 1 -- :invalid_distinct_from" do
    test "a non-list value is ONE violation naming the node, whatever the value type" do
      for bad <- ["review-a", 5, true, %{"review-a" => 1}] do
        graph = chain([human("review-a"), df("review-b", bad)])
        assert [violation] = violations(graph), "value #{inspect(bad)}"
        assert violation.code == :invalid_distinct_from
        assert violation.message =~ "'review-b'"
      end
    end

    test "a non-string entry is one violation per bad entry, naming the node and the entry" do
      graph = chain([human("review-a"), df("review-b", [5, ["x"], nil])])
      violations = violations(graph)

      assert Enum.map(violations, & &1.code) == List.duplicate(:invalid_distinct_from, 3)
      assert Enum.all?(violations, &(&1.message =~ "'review-b'"))
      assert Enum.any?(violations, &(&1.message =~ "5"))
    end

    test "an empty-string and a whitespace-only entry are each a violation" do
      for bad <- ["", "   "] do
        graph = chain([human("review-a"), df("review-b", [bad])])
        assert codes(graph) == [:invalid_distinct_from], "entry #{inspect(bad)}"
      end
    end

    test "a duplicate id is ONE violation naming the node and the id; three copies are still one" do
      twice = chain([human("review-a"), df("review-b", ["review-a", "review-a"])])
      violation = assert_single(twice, :invalid_distinct_from, "review-b", "review-a")
      assert violation.message =~ "duplicate"

      thrice = chain([human("review-a"), df("review-b", ["review-a", "review-a", "review-a"])])
      assert codes(thrice) == [:invalid_distinct_from]
    end

    test "valid neighbour: a well-formed list, [], null and an absent attribute are all clean" do
      assert violations(chain([human("review-a"), df("review-b", ["review-a"])])) == []
      assert violations(chain([human("review-a"), df("review-b", [])])) == []
      assert violations(chain([human("review-a"), df("review-b", nil)])) == []
      assert violations(chain([human("review-a"), human("review-b")])) == []
    end
  end

  describe "check 1 -- :distinct_from_on_non_human_task" do
    test "a SERVICE_TASK carrying distinct_from is the non-human code, naming the node" do
      graph = chain([human("review-a"), service_df("svc", ["review-a"])])
      assert_single(graph, :distinct_from_on_non_human_task, "svc", nil)
    end

    test "an EXCLUSIVE_GATEWAY and a START carrying distinct_from are the non-human code" do
      gw =
        build!(
          [
            node("start", "START"),
            human("review-a"),
            node("gw", "EXCLUSIVE_GATEWAY", %{"distinct_from" => ["review-a"]}),
            node("end-a", "END"),
            node("end-b", "END")
          ],
          [
            edge("e0", "start", "review-a"),
            edge("e1", "review-a", "gw"),
            cond_edge("e2", "gw", "end-a"),
            default_edge("e3", "gw", "end-b")
          ]
        )

      assert_single(gw, :distinct_from_on_non_human_task, "gw", nil)

      start =
        build!(
          [
            node("start", "START", %{"distinct_from" => ["review-a"]}),
            human("review-a"),
            node("end", "END")
          ],
          [edge("e0", "start", "review-a"), edge("e1", "review-a", "end")]
        )

      assert_single(start, :distinct_from_on_non_human_task, "start", nil)
    end

    test "a malformed value on a non-human node reports only the non-human code" do
      graph = chain([human("review-a"), service_df("svc", "nonsense")])
      assert codes(graph) == [:distinct_from_on_non_human_task]
    end

    test "valid neighbour: a SERVICE_TASK with distinct_from null or absent is clean" do
      assert violations(chain([human("review-a"), service_df("svc", nil)])) == []
      assert violations(chain([human("review-a"), service("svc")])) == []
    end
  end

  describe "check 1 -- :distinct_from_self_reference" do
    test "a node naming itself is exactly one :distinct_from_self_reference naming the node" do
      graph = chain([df("review-a", ["review-a"])])
      assert_single(graph, :distinct_from_self_reference, "review-a", nil)
    end

    test "self among other valid entries is still one violation; the others stay clean" do
      graph = chain([human("review-a"), df("review-b", ["review-a", "review-b"])])
      assert codes(graph) == [:distinct_from_self_reference]
    end

    test "valid neighbour: naming a different node is clean" do
      assert violations(chain([human("review-a"), df("review-b", ["review-a"])])) == []
    end
  end

  # =======================================================================================
  # Check 2 -- CHK-26 existence
  # =======================================================================================

  describe "check 2 -- :distinct_from_unknown_node" do
    test "a non-existent id is one violation naming the node and the missing id" do
      graph = chain([human("review-a"), df("review-b", ["ghost"])])
      assert_single(graph, :distinct_from_unknown_node, "review-b", "ghost")
    end

    test "each missing id is its own violation; an existing id beside it adds nothing" do
      graph = chain([human("review-a"), df("review-b", ["review-a", "ghost-1", "ghost-2"])])
      violations = violations(graph)

      assert Enum.map(violations, & &1.code) ==
               [:distinct_from_unknown_node, :distinct_from_unknown_node]

      assert Enum.any?(violations, &(&1.message =~ "ghost-1"))
      assert Enum.any?(violations, &(&1.message =~ "ghost-2"))
    end

    test "valid neighbour: every listed id exists" do
      assert violations(chain([human("review-a"), df("review-b", ["review-a"])])) == []
    end
  end

  describe "check 2 -- :distinct_from_not_human_task" do
    test "a service-task id is one violation naming the node and the id" do
      graph = chain([human("review-a"), service("svc"), df("review-b", ["svc"])])
      assert_single(graph, :distinct_from_not_human_task, "review-b", "svc")
    end

    test "a gateway, START and END id are each :distinct_from_not_human_task" do
      for target <- ["split", "start", "end"] do
        graph = fork([human("review-a"), df("review-b", [target])])
        assert codes(graph) == [:distinct_from_not_human_task], "target #{target}"
      end
    end

    test "a duplicated unknown id is one duplicate violation plus ONE unknown violation" do
      graph = chain([human("review-a"), df("review-b", ["ghost", "ghost"])])
      assert Enum.sort(codes(graph)) == [:distinct_from_unknown_node, :invalid_distinct_from]
    end

    test "valid neighbour: a HUMAN_TASK id passes even with a service task between" do
      graph = chain([human("review-a"), service("svc"), df("review-b", ["review-a"])])
      assert violations(graph) == []
    end
  end

  # =======================================================================================
  # Check 3 -- CHK-27 position (design section 1.5 relation table)
  # =======================================================================================

  describe "check 3 -- :distinct_from_downstream_only" do
    test "a node naming a node reachable only AFTER it is one violation naming both" do
      graph = chain([df("l1-approval", ["l2-approval"]), human("l2-approval")])

      violation =
        assert_single(graph, :distinct_from_downstream_only, "l1-approval", "l2-approval")

      assert violation.message =~ "reachable only after"
    end

    test "transitive successors are downstream too (a -> x -> b: a naming b)" do
      graph = chain([df("a", ["b"]), service("x"), human("b")])
      assert_single(graph, :distinct_from_downstream_only, "a", "b")
    end

    test "valid neighbour: the successor naming its predecessor passes (l2 names l1)" do
      graph = chain([human("l1-approval"), df("l2-approval", ["l1-approval"])])
      assert violations(graph) == []
    end

    test "both naming each other on one path: only the earlier one violates, once" do
      graph = chain([df("l1-approval", ["l2-approval"]), df("l2-approval", ["l1-approval"])])
      assert_single(graph, :distinct_from_downstream_only, "l1-approval", "l2-approval")
    end

    test "one violation per downstream listed node" do
      graph = chain([df("a", ["b", "c"]), human("b"), human("c")])
      assert codes(graph) == [:distinct_from_downstream_only, :distinct_from_downstream_only]
    end

    test "an unknown listed id is not also position-checked (check 2's code only)" do
      graph = chain([df("a", ["ghost"]), human("b")])
      assert codes(graph) == [:distinct_from_unknown_node]
    end
  end

  describe "check 3 -- positions that pass" do
    test "three parallel nodes after a fork, each naming the other two: no violation" do
      ids = ["p1", "p2", "p3"]
      graph = fork(Enum.map(ids, &df(&1, ids -- [&1])))
      assert violations(graph) == []
    end

    test "a listed node earlier on the same path passes, also with a gateway between" do
      assert violations(chain([human("a"), df("b", ["a"])])) == []

      graph = chain([human("a"), node("gw", "PARALLEL_GATEWAY"), df("b", ["a"])])
      assert violations(graph) == []
    end

    test "mutually exclusive branches (no path either way): each may name the other" do
      graph = exclusive(df("x", ["y"]), df("y", ["x"]))
      assert violations(graph) == []
    end

    test "a rework loop (path both ways): each may name the other" do
      graph = loop(df("a", ["b"]), df("b", ["a"]))
      assert violations(graph) == []
    end

    test "a node after a join may name the nodes on the parallel branches (they precede it)" do
      graph =
        build!(
          [
            node("start", "START"),
            node("split", "PARALLEL_GATEWAY"),
            human("p1"),
            human("p2"),
            node("join", "PARALLEL_GATEWAY"),
            df("after", ["p1", "p2"]),
            node("end", "END")
          ],
          [
            edge("e0", "start", "split"),
            edge("e1", "split", "p1"),
            edge("e2", "split", "p2"),
            edge("e3", "p1", "join"),
            edge("e4", "p2", "join"),
            edge("e5", "join", "after"),
            edge("e6", "after", "end")
          ]
        )

      assert violations(graph) == []
    end

    test "a branch node naming a node AFTER the join is downstream-only" do
      graph =
        build!(
          [
            node("start", "START"),
            node("split", "PARALLEL_GATEWAY"),
            df("p1", ["after"]),
            human("p2"),
            node("join", "PARALLEL_GATEWAY"),
            human("after"),
            node("end", "END")
          ],
          [
            edge("e0", "start", "split"),
            edge("e1", "split", "p1"),
            edge("e2", "split", "p2"),
            edge("e3", "p1", "join"),
            edge("e4", "p2", "join"),
            edge("e5", "join", "after"),
            edge("e6", "after", "end")
          ]
        )

      assert_single(graph, :distinct_from_downstream_only, "p1", "after")
    end
  end

  describe "check 3 -- nodes unreachable from START" do
    test "an orphan naming a node with no path between them passes" do
      graph = with_orphans(human("main"), [df("orphan", ["main"])], [])
      assert violations(graph) == []
    end

    test "a node naming an orphan with no path between them passes" do
      graph = with_orphans(df("main", ["orphan"]), [human("orphan")], [])
      assert violations(graph) == []
    end

    test "pinned: an orphan with a path to a listed node that cannot reach back IS downstream-only" do
      # orphan -> main; main cannot reach orphan. Reachability is measured from the listing
      # node itself (not from START), so the orphan 'precedes' main in the graph sense and
      # naming main is reported. CHK-22 reports the orphan itself separately.
      graph =
        with_orphans(human("main"), [df("orphan", ["main"])], [edge("e2", "orphan", "main")])

      assert_single(graph, :distinct_from_downstream_only, "orphan", "main")
    end

    test "pinned, reverse: main naming an orphan that has a path INTO main passes" do
      graph =
        with_orphans(df("main", ["orphan"]), [human("orphan")], [edge("e2", "orphan", "main")])

      assert violations(graph) == []
    end
  end

  # =======================================================================================
  # Cross-cutting
  # =======================================================================================

  describe "the six reserved codes only" do
    test "each negative definition yields exactly its reserved atom, and together they cover all six" do
      cases = [
        {:invalid_distinct_from, chain([human("a"), df("b", "a")])},
        {:distinct_from_self_reference, chain([df("a", ["a"])])},
        {:distinct_from_unknown_node, chain([human("a"), df("b", ["ghost"])])},
        {:distinct_from_not_human_task, chain([human("a"), service("s"), df("b", ["s"])])},
        {:invalid_distinct_from, chain([human("a"), df("b", ["a", "a"])])},
        {:distinct_from_downstream_only, chain([df("a", ["b"]), human("b")])},
        {:distinct_from_on_non_human_task, chain([human("a"), service_df("s", ["a"])])}
      ]

      for {expected, graph} <- cases do
        assert codes(graph) == [expected]
      end

      assert cases |> Enum.map(&elem(&1, 0)) |> MapSet.new() == MapSet.new(@new_codes)
    end

    test "a definition with no distinct_from anywhere yields none of the new codes" do
      graph = fork([human("p1"), human("p2")])
      assert Enum.filter(codes(graph), &(&1 in @new_codes)) == []
    end

    test "a HUMAN_TASK with nil attributes never raises and yields no distinct_from code" do
      graph = chain([node("a", "HUMAN_TASK"), df("b", ["a"])])
      assert Enum.filter(codes(graph), &(&1 in @new_codes)) == []
    end
  end
end
