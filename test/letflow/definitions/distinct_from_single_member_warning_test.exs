defmodule Letflow.Definitions.DistinctFromSingleMemberWarningTest do
  @moduledoc """
  DB-backed tests for REQ-464 check 4 (the `distinct_from_single_member_role:` WARNING), REQ-459
  design section 1.2 / OQ-2. See `test/specs/REQ-464.md`.

    * `RoleBinding.single_member_pairs/1` (pure), `format_single_member_warning/2`
    * `RoleBinding.member_counts/2` (one prefix-scoped counts-only read) and
      `single_member_warnings_for_definitions/2` (query discipline)
    * `Definitions.validate_definition_graph/2`, `ValidationWarnings.for_definitions/2`,
      `SolutionPack.install/3`, `Definitions.activate/2`

  `Letflow.DataCase` (real Postgres), `async: false` (tenant provisioning), one provisioned tenant
  per test, unique names via `System.unique_integer/1`, no clock, no unseeded randomness. No
  helper has a default argument (ISS-0069).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.RoleBinding
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Definitions.ValidationWarnings
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.SodSupport, as: S
  alias Letflow.TenantFixture

  @prefix "distinct_from_single_member_role:"

  defp unique(prefix), do: S.unique(prefix)
  defp tenant!(slug), do: TenantFixture.provisioned_tenant!(slug_prefix: slug)

  # --- graph builders (maps) --------------------------------------------------------------

  defp task(id, role, extra),
    do: %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => Map.merge(%{"role" => role}, extra)
    }

  defp chain_edges(ids) do
    ["start"]
    |> Kernel.++(ids)
    |> Kernel.++(["end"])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.map(fn {[s, t], i} -> %{"id" => "c#{i}", "source" => s, "target" => t} end)
  end

  # start -> first-review -> second-review -> end; the second names the first.
  defp seq_graph(role_1, role_2, second_extra) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        task("first-review", role_1, %{}),
        task(
          "second-review",
          role_2,
          Map.merge(%{"distinct_from" => ["first-review"]}, second_extra)
        ),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => chain_edges(["first-review", "second-review"])
    }
  end

  # start -> split -> p1, p2, p3 (each naming the other two, all on `role`) -> join -> end
  defp parallel_graph(role) do
    ids = ["p1", "p2", "p3"]

    %{
      "nodes" =>
        [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "split", "node_type" => "PARALLEL_GATEWAY"}
        ] ++
          Enum.map(ids, &task(&1, role, %{"distinct_from" => ids -- [&1]})) ++
          [
            %{"id" => "join", "node_type" => "PARALLEL_GATEWAY"},
            %{"id" => "end", "node_type" => "END"}
          ],
      "edges" =>
        [%{"id" => "e0", "source" => "start", "target" => "split"}] ++
          Enum.map(ids, &%{"id" => "s-#{&1}", "source" => "split", "target" => &1}) ++
          Enum.map(ids, &%{"id" => "j-#{&1}", "source" => &1, "target" => "join"}) ++
          [%{"id" => "e9", "source" => "join", "target" => "end"}]
    }
  end

  # start -> a -> b -> gw -> (cond) a | (default) end : a and b share a path both ways
  defp loop_graph(role) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        task("loop-a", role, %{"distinct_from" => ["loop-b"]}),
        task("loop-b", role, %{"distinct_from" => ["loop-a"]}),
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e0", "source" => "start", "target" => "loop-a"},
        %{"id" => "e1", "source" => "loop-a", "target" => "loop-b"},
        %{"id" => "e2", "source" => "loop-b", "target" => "gw"},
        %{
          "id" => "e3",
          "source" => "gw",
          "target" => "loop-a",
          "condition" => "variables.again == \"yes\""
        },
        %{"id" => "e4", "source" => "gw", "target" => "end", "is_default" => true}
      ]
    }
  end

  defp parsed!(graph_map) do
    assert {:ok, graph} = Graph.from_map(graph_map)
    graph
  end

  defp create!(schema, graph) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique("req464-def"),
                 version: "1.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema
             )

    definition
  end

  defp validate!(schema, definition) do
    assert {:ok, result} = Definitions.validate_definition_graph(definition.id, prefix: schema)
    result
  end

  defp lines(warnings), do: Enum.filter(warnings, &String.starts_with?(&1, @prefix))

  # A role bound to a fresh group with `n` fresh active users; returns the users.
  defp role_with_members!(schema, role, n) do
    users = for i <- 1..n//1, do: S.insert_user!(schema, "member#{i}")
    :ok = S.grant_role!(schema, role, Enum.map(users, & &1.id))
    users
  end

  defp deactivate!(schema, user) do
    user |> Ecto.Changeset.change(%{status: :inactive}) |> Repo.update!(prefix: schema)
  end

  # Counts the Ecto queries issued by the calling process inside `fun`: `{result, count}`.
  defp count_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = "req464-count-" <> inspect(ref)

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {ref, :query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end

  # =======================================================================================
  # Pure half: single_member_pairs/1, format_single_member_warning/2
  # =======================================================================================

  describe "RoleBinding.single_member_pairs/1" do
    test "a node and a listed node on the same role is ONE pair, node ids sorted" do
      graph = parsed!(seq_graph("shared-role", "shared-role", %{}))

      assert RoleBinding.single_member_pairs(graph) ==
               [%{role_name: "shared-role", node_ids: ["first-review", "second-review"]}]
    end

    test "each node naming the other is still ONE pair (unordered, ids sorted)" do
      graph = parsed!(loop_graph("shared-role"))

      assert RoleBinding.single_member_pairs(graph) ==
               [%{role_name: "shared-role", node_ids: ["loop-a", "loop-b"]}]
    end

    test "three parallel nodes naming each other are three pairs, sorted by ids; preceding, parallel and loop pairs all count" do
      assert [
               %{node_ids: ["p1", "p2"]},
               %{node_ids: ["p1", "p3"]},
               %{node_ids: ["p2", "p3"]}
             ] = RoleBinding.single_member_pairs(parsed!(parallel_graph("shared-role")))

      assert [_] = RoleBinding.single_member_pairs(parsed!(seq_graph("r", "r", %{})))
      assert [_] = RoleBinding.single_member_pairs(parsed!(loop_graph("r")))
    end

    test "different roles yield no pair" do
      assert RoleBinding.single_member_pairs(parsed!(seq_graph("role-x", "role-y", %{}))) == []
    end

    test "escalation_role equal but role different yields no pair" do
      graph =
        parsed!(
          seq_graph("role-x", "role-y", %{
            "escalation_role" => "role-x",
            "escalation_timer_duration" => "PT2H"
          })
        )

      assert RoleBinding.single_member_pairs(graph) == []
    end

    test "a node with no distinct_from yields no pair even when roles are equal" do
      graph =
        parsed!(%{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            task("a", "r", %{}),
            task("b", "r", %{}),
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => chain_edges(["a", "b"])
        })

      assert RoleBinding.single_member_pairs(graph) == []
    end

    test "total on malformed input: blank or non-string role, self, non-list and unknown ids never raise or pair" do
      graph =
        parsed!(%{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            task("a", "   ", %{"distinct_from" => ["b"]}),
            task("b", "   ", %{"distinct_from" => ["a", "a", "ghost", 5, "b"]}),
            task("c", 7, %{"distinct_from" => "a"}),
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => chain_edges(["a", "b", "c"])
        })

      assert RoleBinding.single_member_pairs(graph) == []
    end

    test "a service task naming a human task of the same role is not a pair" do
      graph =
        parsed!(%{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            task("a", "r", %{}),
            %{
              "id" => "svc",
              "node_type" => "SERVICE_TASK",
              "attributes" => %{
                "endpoint" => "https://x.test",
                "timeout_ms" => 1000,
                "role" => "r",
                "distinct_from" => ["a"]
              }
            },
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => chain_edges(["a", "svc"])
        })

      assert RoleBinding.single_member_pairs(graph) == []
    end
  end

  describe "RoleBinding.format_single_member_warning/2" do
    test "wire text: reserved prefix, role, definition name and both node ids" do
      assert RoleBinding.format_single_member_warning("kyc", %{
               role_name: "role-x",
               node_ids: ["n1", "n2"]
             }) ==
               "distinct_from_single_member_role: role-x (definition 'kyc', nodes: n1, n2)"
    end
  end

  # =======================================================================================
  # member_counts/2 -- the one new query
  # =======================================================================================

  describe "RoleBinding.member_counts/2" do
    test "returns exactly the member count per named role; counts only (no user data in the result)" do
      tenant = tenant!("req464-counts")
      one = unique("role-one")
      three = unique("role-three")
      [only] = role_with_members!(tenant.schema_name, one, 1)
      _ = role_with_members!(tenant.schema_name, three, 3)

      counts = RoleBinding.member_counts([one, three, "role-unbound"], prefix: tenant.schema_name)

      assert counts == %{one => 1, three => 3}
      refute inspect(counts) =~ only.id
      refute inspect(counts) =~ only.email
    end

    test "a bound role with zero members and an unbound role are both absent from the map" do
      tenant = tenant!("req464-counts-zero")
      empty = unique("role-empty")
      :ok = S.grant_role!(tenant.schema_name, empty, [])

      assert RoleBinding.member_counts([empty, "role-unbound"], prefix: tenant.schema_name) == %{}
    end

    test "an inactive user still counts (OQ-2: users.status is not consulted)" do
      tenant = tenant!("req464-counts-inactive")
      role = unique("role-mixed")
      [active, inactive] = role_with_members!(tenant.schema_name, role, 2)
      assert active.status == :active
      deactivate!(tenant.schema_name, inactive)

      assert RoleBinding.member_counts([role], prefix: tenant.schema_name) == %{role => 2}
    end

    test "members of a DIFFERENT group do not count towards the role" do
      tenant = tenant!("req464-counts-other-group")
      role = unique("role-mine")
      other = unique("role-other")
      _ = role_with_members!(tenant.schema_name, role, 1)
      _ = role_with_members!(tenant.schema_name, other, 4)

      assert RoleBinding.member_counts([role], prefix: tenant.schema_name) == %{role => 1}
    end

    test "is prefix-scoped: another tenant's membership of the same role name is not visible (INV-1)" do
      tenant_a = tenant!("req464-counts-a")
      tenant_b = tenant!("req464-counts-b")
      role = unique("role-shared-name")
      _ = role_with_members!(tenant_a.schema_name, role, 1)
      _ = role_with_members!(tenant_b.schema_name, role, 3)

      assert RoleBinding.member_counts([role], prefix: tenant_a.schema_name) == %{role => 1}
      assert RoleBinding.member_counts([role], prefix: tenant_b.schema_name) == %{role => 3}
    end

    test "an empty role list runs no query and returns %{}" do
      tenant = tenant!("req464-counts-empty")

      assert {%{}, 0} =
               count_queries(fn -> RoleBinding.member_counts([], prefix: tenant.schema_name) end)
    end

    test "one call is exactly one query for any number of roles" do
      tenant = tenant!("req464-counts-one-query")
      roles = for i <- 1..3, do: unique("role-q#{i}")
      for role <- roles, do: role_with_members!(tenant.schema_name, role, 1)

      assert {counts, 1} =
               count_queries(fn ->
                 RoleBinding.member_counts(roles, prefix: tenant.schema_name)
               end)

      assert map_size(counts) == 3
    end

    test "the prefix option is required (no implicit default tenant)" do
      assert_raise KeyError, fn -> RoleBinding.member_counts(["r"], []) end
    end
  end

  describe "RoleBinding.single_member_warnings_for_definitions/2 query discipline" do
    test "no definition with a candidate pair: zero queries and []" do
      tenant = tenant!("req464-qd-none")

      defs = [
        {"d1", parsed!(seq_graph("role-x", "role-y", %{}))},
        {"d2", parsed!(seq_graph("role-x", "role-y", %{}))}
      ]

      assert {[], 0} =
               count_queries(fn ->
                 RoleBinding.single_member_warnings_for_definitions(defs,
                   prefix: tenant.schema_name
                 )
               end)

      assert {[], 0} =
               count_queries(fn ->
                 RoleBinding.single_member_warnings_for_definitions([],
                   prefix: tenant.schema_name
                 )
               end)
    end

    test "several pairs across several definitions: exactly ONE query in total" do
      tenant = tenant!("req464-qd-many")
      role_a = unique("role-a")
      role_b = unique("role-b")
      _ = role_with_members!(tenant.schema_name, role_a, 1)
      _ = role_with_members!(tenant.schema_name, role_b, 1)

      defs = [
        {"d1", parsed!(parallel_graph(role_a))},
        {"d2", parsed!(seq_graph(role_b, role_b, %{}))}
      ]

      assert {warnings, 1} =
               count_queries(fn ->
                 RoleBinding.single_member_warnings_for_definitions(defs,
                   prefix: tenant.schema_name
                 )
               end)

      # d1: 3 pairs, d2: 1 pair; definitions in input order
      assert length(warnings) == 4
      assert Enum.take(warnings, 3) |> Enum.all?(&(&1 =~ "definition 'd1'"))
      assert List.last(warnings) =~ "definition 'd2'"
    end

    test "a definition WITHOUT pairs beside one WITH pairs adds no query and no warning" do
      tenant = tenant!("req464-qd-mixed")
      role = unique("role-m")
      _ = role_with_members!(tenant.schema_name, role, 1)

      defs = [
        {"plain", parsed!(seq_graph("role-x", "role-y", %{}))},
        {"paired", parsed!(seq_graph(role, role, %{}))}
      ]

      assert {[warning], 1} =
               count_queries(fn ->
                 RoleBinding.single_member_warnings_for_definitions(defs,
                   prefix: tenant.schema_name
                 )
               end)

      assert warning =~ "definition 'paired'"
    end
  end

  # =======================================================================================
  # Check 4 through the validate surface
  # =======================================================================================

  describe "check 4 -- Definitions.validate_definition_graph/2" do
    test "one member: a WARNING naming both nodes, the role and the definition; still valid, status unchanged" do
      tenant = tenant!("req464-one")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      result = validate!(tenant.schema_name, definition)

      assert result.valid == true
      assert result.violations == []
      assert [line] = lines(result.warnings)
      assert String.starts_with?(line, @prefix)
      assert line =~ role
      assert line =~ "first-review"
      assert line =~ "second-review"
      assert line =~ definition.name

      assert {:ok, reloaded} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert reloaded.status == definition.status
      assert reloaded.status == :draft
    end

    test "two members: no distinct_from warning" do
      tenant = tenant!("req464-two")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 2)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert %{valid: true, warnings: warnings} = validate!(tenant.schema_name, definition)
      assert lines(warnings) == []
    end

    test "zero members (role bound, group empty): no distinct_from warning and no unbound_task_role either" do
      tenant = tenant!("req464-zero")
      role = unique("shared-role")
      :ok = S.grant_role!(tenant.schema_name, role, [])
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert %{valid: true, warnings: warnings} = validate!(tenant.schema_name, definition)
      assert warnings == []
    end

    test "unbound role (no tenant_role row): only unbound_task_role:, never the single-member line" do
      tenant = tenant!("req464-unbound")
      role = unique("shared-role-unbound")
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert %{valid: true, warnings: warnings} = validate!(tenant.schema_name, definition)
      assert lines(warnings) == []
      assert [unbound] = warnings
      assert String.starts_with?(unbound, "unbound_task_role:")
    end

    test "different roles, one member each: no warning" do
      tenant = tenant!("req464-diff")
      role_1 = unique("role-first")
      role_2 = unique("role-second")
      _ = role_with_members!(tenant.schema_name, role_1, 1)
      _ = role_with_members!(tenant.schema_name, role_2, 1)
      definition = create!(tenant.schema_name, seq_graph(role_1, role_2, %{}))

      assert %{warnings: warnings} = validate!(tenant.schema_name, definition)
      assert lines(warnings) == []
    end

    test "equal escalation_role but different role: no warning (only attributes[\"role\"] counts)" do
      tenant = tenant!("req464-esc")
      role_1 = unique("role-first")
      role_2 = unique("role-second")
      _ = role_with_members!(tenant.schema_name, role_1, 1)
      _ = role_with_members!(tenant.schema_name, role_2, 1)

      definition =
        create!(
          tenant.schema_name,
          seq_graph(role_1, role_2, %{
            "escalation_role" => role_1,
            "escalation_timer_duration" => "PT2H"
          })
        )

      assert %{warnings: warnings} = validate!(tenant.schema_name, definition)
      assert lines(warnings) == []
    end

    test "nodes naming each other (rework loop) yield ONE warning, not two" do
      tenant = tenant!("req464-loop")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)
      definition = create!(tenant.schema_name, loop_graph(role))

      assert %{valid: true, warnings: warnings} = validate!(tenant.schema_name, definition)
      assert [line] = lines(warnings)
      assert line =~ "loop-a, loop-b"
    end

    test "parallel nodes (three, each naming the other two) yield one warning per unordered pair" do
      tenant = tenant!("req464-parallel")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)
      definition = create!(tenant.schema_name, parallel_graph(role))

      assert %{valid: true, warnings: warnings} = validate!(tenant.schema_name, definition)
      found = lines(warnings)
      assert length(found) == 3
      assert Enum.any?(found, &(&1 =~ "nodes: p1, p2"))
      assert Enum.any?(found, &(&1 =~ "nodes: p1, p3"))
      assert Enum.any?(found, &(&1 =~ "nodes: p2, p3"))
    end

    test "a preceding pair (second names first) warns too" do
      tenant = tenant!("req464-prec")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert [_] = lines(validate!(tenant.schema_name, definition).warnings)
    end

    test "inactive members still count: one active + one inactive is 2 members -> NOT warned" do
      tenant = tenant!("req464-inactive-two")
      role = unique("shared-role")
      [_active, inactive] = role_with_members!(tenant.schema_name, role, 2)
      deactivate!(tenant.schema_name, inactive)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert lines(validate!(tenant.schema_name, definition).warnings) == []
    end

    test "a single INACTIVE member is still one member -> warned" do
      tenant = tenant!("req464-inactive-one")
      role = unique("shared-role")
      [only] = role_with_members!(tenant.schema_name, role, 1)
      deactivate!(tenant.schema_name, only)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert [_] = lines(validate!(tenant.schema_name, definition).warnings)
    end

    test "tenant isolation: the same role name has one member in tenant A (warned) and two in B (not warned)" do
      tenant_a = tenant!("req464-iso-a")
      tenant_b = tenant!("req464-iso-b")
      role = unique("shared-role")
      _ = role_with_members!(tenant_a.schema_name, role, 1)
      _ = role_with_members!(tenant_b.schema_name, role, 2)
      def_a = create!(tenant_a.schema_name, seq_graph(role, role, %{}))
      def_b = create!(tenant_b.schema_name, seq_graph(role, role, %{}))

      assert [_] = lines(validate!(tenant_a.schema_name, def_a).warnings)
      assert lines(validate!(tenant_b.schema_name, def_b).warnings) == []
    end

    test "the warning text carries no user id, name, username or email" do
      tenant = tenant!("req464-leak")
      role = unique("shared-role")
      [member] = role_with_members!(tenant.schema_name, role, 1)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert [line] = lines(validate!(tenant.schema_name, definition).warnings)

      for secret <- [member.id, member.email, member.username, member.display_name] do
        refute line =~ secret
      end

      assert %User{} = member
    end

    test "valid neighbour: a definition without distinct_from is never warned even on a one-member role" do
      tenant = tenant!("req464-nodf")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)

      graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          task("a", role, %{}),
          task("b", role, %{}),
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => chain_edges(["a", "b"])
      }

      definition = create!(tenant.schema_name, graph)
      assert validate!(tenant.schema_name, definition).warnings == []
    end
  end

  describe "ValidationWarnings.for_definitions/2" do
    test "the single-member lines come LAST (after unbound_task_role: and decision_key_not_required:); every element is a string" do
      tenant = tenant!("req464-order")
      shared = unique("shared-role")
      unbound = unique("role-unbound")
      _ = role_with_members!(tenant.schema_name, shared, 1)

      definitions = [
        {"d-single", parsed!(seq_graph(shared, shared, %{}))},
        {"d-unbound", parsed!(seq_graph(unbound, unbound, %{}))}
      ]

      warnings = ValidationWarnings.for_definitions(definitions, prefix: tenant.schema_name)

      assert Enum.all?(warnings, &is_binary/1)
      assert [unbound_line, single_line] = warnings
      assert String.starts_with?(unbound_line, "unbound_task_role:")
      assert String.starts_with?(single_line, @prefix)
    end
  end

  # =======================================================================================
  # Pack install and activate
  # =======================================================================================

  describe "SolutionPack.install/3" do
    defp cleanup_installs!(tenant_id) do
      on_exit(fn ->
        Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))
        Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      end)
    end

    defp pack_document(name, graph) do
      %{
        "pack_id" => Ecto.UUID.generate(),
        "version" => "1.0.0",
        "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
        "exported_at" => "2026-01-01T00:00:00Z",
        "definitions" => [
          %{
            "definition_id" => Ecto.UUID.generate(),
            "process_key" => name,
            "name" => name,
            "version" => "1.0.0",
            "graph" => graph
          }
        ],
        "service_catalog_entries" => [],
        "variable_schemas" => [],
        "manifest" => %{"required_roles" => []}
      }
    end

    test "install result `warnings` carries the single-member line naming both nodes and the role; the definition still installs" do
      tenant = tenant!("req464-pack-one")
      cleanup_installs!(tenant.tenant_id)
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)
      name = unique("req464-pack-def")

      assert {:ok, result} =
               SolutionPack.install(
                 pack_document(name, seq_graph(role, role, %{})),
                 Ecto.UUID.generate(),
                 prefix: tenant.schema_name
               )

      assert [%{status: "installed"}] = result.installed_definitions
      assert [line] = lines(result.warnings)
      assert line =~ role
      assert line =~ "first-review"
      assert line =~ "second-review"
      assert line =~ name
      assert Enum.all?(result.warnings, &is_binary/1)

      assert Repo.aggregate(Definitions.ProcessDefinition, :count, :id,
               prefix: tenant.schema_name
             ) ==
               1
    end

    test "valid neighbour: with two members the install result has no single-member line" do
      tenant = tenant!("req464-pack-two")
      cleanup_installs!(tenant.tenant_id)
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 2)

      assert {:ok, result} =
               SolutionPack.install(
                 pack_document(unique("req464-pack-def"), seq_graph(role, role, %{})),
                 Ecto.UUID.generate(),
                 prefix: tenant.schema_name
               )

      assert lines(result.warnings) == []
    end

    test "check 1 runs at install: a non-list distinct_from fails the install and stores nothing" do
      tenant = tenant!("req464-pack-bad")
      cleanup_installs!(tenant.tenant_id)
      graph = seq_graph("r", "r", %{"distinct_from" => "first-review"})

      assert {:error, reason} =
               SolutionPack.install(
                 pack_document(unique("req464-pack-def"), graph),
                 Ecto.UUID.generate(),
                 prefix: tenant.schema_name
               )

      assert inspect(reason) =~ "invalid_distinct_from"

      assert Repo.aggregate(Definitions.ProcessDefinition, :count, :id,
               prefix: tenant.schema_name
             ) ==
               0
    end
  end

  describe "Definitions.activate/2" do
    test "a definition that only WARNS activates; the result carries no warnings and no distinct_from_single_member_role text" do
      tenant = tenant!("req464-activate")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      assert [_] = lines(validate!(tenant.schema_name, definition).warnings)

      assert {:ok, result} = Definitions.activate(definition.id, prefix: tenant.schema_name)
      assert result.definition.status == :active
      refute Map.has_key?(result, :warnings)
      refute inspect(result) =~ "distinct_from_single_member_role"
    end

    test "a distinct_from check never changes the stored graph (validate leaves it byte-identical)" do
      tenant = tenant!("req464-nomutate")
      role = unique("shared-role")
      _ = role_with_members!(tenant.schema_name, role, 1)
      definition = create!(tenant.schema_name, seq_graph(role, role, %{}))

      _ = validate!(tenant.schema_name, definition)
      assert {:ok, reloaded} = Definitions.get_by_id(definition.id, prefix: tenant.schema_name)
      assert reloaded.graph == definition.graph
    end
  end
end
