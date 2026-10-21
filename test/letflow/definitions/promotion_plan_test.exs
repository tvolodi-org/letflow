defmodule Letflow.Definitions.PromotionPlanTest do
  @moduledoc """
  Tests for `Letflow.Definitions.PromotionPlan.compute_promotion_plan/5` (REQ-036,
  PRM-01). See `test/specs/REQ-036.md` for the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  ## Fixture strategy -- mirrors snapshot_store_test.exs's established pattern

  `compute_promotion_plan/5` reads `process_definitions` under TWO tenants' schemas
  (source and target), so each test that needs real rows provisions TWO real tenant
  schemas via `provisioned_tenant/0` (real `CREATE SCHEMA` +
  `TenantProvisioning.replay_migrations/1`), exactly like
  `test/letflow/definitions/snapshot_store_test.exs`'s own `provisioned_tenant/1`.
  `Ecto.Migrator` needs a second real DB connection the sandbox can't hand out, hence
  Sandbox `:auto` mode and manual `on_exit/1` cleanup instead of the normal
  rolled-back transaction. `async: false` for the whole module, for the same reason
  `snapshot_store_test.exs`/`migrations_test.exs` are `async: false`.

  Every `process_definitions` row is inserted directly via
  `ProcessDefinition.create_changeset/2` + `Repo.insert!/2` (no create/1 context
  function exists yet), then activated via a guarded raw UPDATE mirroring
  `migrations_test.exs`'s own `activate/2` helper -- `create_changeset/2` never casts
  `:status` (design INV-DEF-8), so a real ACTIVE fixture row cannot be produced any
  other way.

  ## `opts[:permission_checker]` is supplied explicitly on EVERY call in this file

  `compute_promotion_plan/5` has no built-in default for `:permission_checker`
  (`Keyword.fetch!/2` -- design §9.1) -- every single call below passes it, either
  `allow/0` or `deny/0`, never relying on a default that does not exist.

  ## AC3's production-tenant test injects `opts[:tenant_classifier]` explicitly

  The real `default_tenant_classifier/1` classifies every tenant as `:test` (design
  §9.2) -- there is no tenant "kind" column in this codebase to build a real
  production-tenant fixture against. The AC3 test below injects a deterministic
  `tenant_classifier` returning `:production` for its fixture, per this run's own
  task briefing -- this is the design's own stated limitation, not a gap in this test.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionPlan
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req036-plan",
      display_name: "REQ-036 PromotionPlan Test Tenant"
    )
  end

  defp unique_process_key(prefix \\ "req036-proc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp insert_definition!(schema_name, attrs) do
    base = %{
      version: "1.0.0",
      graph: %{"nodes" => [], "edges" => []},
      created_by: Ecto.UUID.generate()
    }

    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(Map.merge(base, attrs))
    |> Repo.insert!(prefix: schema_name)
  end

  # Guarded, single-statement UPDATE -- mirrors migrations_test.exs's own activate/2
  # helper exactly. Neither changeset casts :status (design INV-DEF-8), so a raw
  # UPDATE is the only way to produce a real ACTIVE fixture row.
  defp activate!(schema_name, id) do
    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(id)]
             )
  end

  defp insert_active_definition!(schema_name, attrs) do
    definition = insert_definition!(schema_name, attrs)
    activate!(schema_name, definition.id)
    %{definition | status: :active}
  end

  defp allow, do: fn _actor_id, _source_tenant_id -> true end
  defp deny, do: fn _actor_id, _source_tenant_id -> false end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "compute_promotion_plan/5 against a target tenant with no
  # existing version of process_key marks every produced entry change_kind: added"
  # ---------------------------------------------------------------------------------

  describe "compute_promotion_plan/5 -- acceptance criterion 1 (empty target)" do
    test "target has no process_definitions row at all -- every entry across all 5 dimensions is :added, before is nil everywhere" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id} = provisioned_tenant()

      process_key = unique_process_key()

      graph = %{
        "nodes" => [
          %{"id" => "n1", "node_type" => "START"},
          %{
            "id" => "n2",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"service_id" => "svc-A"}
          },
          %{
            "id" => "n3",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"module_ref" => "mod-A"}
          },
          %{"id" => "n4", "node_type" => "END"}
        ],
        "edges" => [%{"id" => "e1", "source" => "n1", "target" => "n2"}]
      }

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "1.0.0",
          graph: graph
        })

      # Injected explicitly so the :variable_schema dimension also participates in
      # this all-added assertion -- the real default fetcher always returns nil for
      # both sides (design §9.3), which would silently exclude this dimension.
      variable_schema_fetcher = fn tenant_id, _process_key ->
        if tenant_id == source_tenant_id, do: "schema-src", else: nil
      end

      assert {:ok, plan} =
               PromotionPlan.compute_promotion_plan(
                 Ecto.UUID.generate(),
                 source_tenant_id,
                 target_tenant_id,
                 process_key,
                 permission_checker: allow(),
                 variable_schema_fetcher: variable_schema_fetcher
               )

      assert plan.source_tenant_id == source_tenant_id
      assert plan.target_tenant_id == target_tenant_id
      assert plan.process_key == process_key
      assert plan.source_definition_id == source_def.id
      assert plan.target_definition_id == nil
      assert plan.base_version == nil

      assert Enum.all?(plan.entries, &(&1.change_kind == :added))
      assert Enum.all?(plan.entries, &is_nil(&1.before))
      assert length(plan.entries) == 8

      # Exact, order-sensitive assertion: pins both AC1's all-:added claim AND
      # design §2.5's {type_rank, id} sort in one assertion.
      assert plan.entries == [
               %{
                 type: :graph_node,
                 id: "n1",
                 change_kind: :added,
                 before: nil,
                 after: %{"id" => "n1", "node_type" => "START"}
               },
               %{
                 type: :graph_node,
                 id: "n2",
                 change_kind: :added,
                 before: nil,
                 after: %{
                   "id" => "n2",
                   "node_type" => "SERVICE_TASK",
                   "attributes" => %{"service_id" => "svc-A"}
                 }
               },
               %{
                 type: :graph_node,
                 id: "n3",
                 change_kind: :added,
                 before: nil,
                 after: %{
                   "id" => "n3",
                   "node_type" => "SUB_PROCESS",
                   "attributes" => %{"module_ref" => "mod-A"}
                 }
               },
               %{
                 type: :graph_node,
                 id: "n4",
                 change_kind: :added,
                 before: nil,
                 after: %{"id" => "n4", "node_type" => "END"}
               },
               %{
                 type: :graph_edge,
                 id: "e1",
                 change_kind: :added,
                 before: nil,
                 after: %{"id" => "e1", "source" => "n1", "target" => "n2"}
               },
               %{
                 type: :variable_schema,
                 id: "variable_schema",
                 change_kind: :added,
                 before: nil,
                 after: "schema-src"
               },
               %{
                 type: :service_binding,
                 id: "n2",
                 change_kind: :added,
                 before: nil,
                 after: "svc-A"
               },
               %{type: :module_ref, id: "n3", change_kind: :added, before: nil, after: "mod-A"}
             ]
    end

    test "a target row exists for process_key but is NOT active (still :draft) -- treated identically to no target row at all" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      insert_active_definition!(source_schema, %{
        name: process_key,
        version: "1.0.0",
        graph: %{"nodes" => [%{"id" => "n1", "node_type" => "START"}], "edges" => []}
      })

      # A DRAFT (non-active) row at the target under the SAME process_key -- must
      # never be read by fetch_active/2's status: :active filter.
      insert_definition!(target_schema, %{
        name: process_key,
        version: "0.1.0",
        graph: %{"nodes" => [], "edges" => []}
      })

      assert {:ok, plan} =
               PromotionPlan.compute_promotion_plan(
                 Ecto.UUID.generate(),
                 source_tenant_id,
                 target_tenant_id,
                 process_key,
                 permission_checker: allow()
               )

      assert plan.target_definition_id == nil
      assert plan.base_version == nil
      assert Enum.all?(plan.entries, &(&1.change_kind == :added))
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "compute_promotion_plan/5 against byte-identical source
  # and target definitions returns the empty-plan error, not a PromotionPlan with an
  # empty entries list"
  # ---------------------------------------------------------------------------------

  describe "compute_promotion_plan/5 -- acceptance criterion 2 (byte-identical source/target)" do
    test "identical ACTIVE graphs at source and target -- returns {:error, :empty_plan}, never {:ok, %{entries: []}}" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      graph = %{
        "nodes" => [
          %{"id" => "n1", "node_type" => "START"},
          %{"id" => "n2", "node_type" => "END"}
        ],
        "edges" => [%{"id" => "e1", "source" => "n1", "target" => "n2"}]
      }

      insert_active_definition!(source_schema, %{
        name: process_key,
        version: "1.0.0",
        graph: graph
      })

      insert_active_definition!(target_schema, %{
        name: process_key,
        version: "1.0.0",
        graph: graph
      })

      result =
        PromotionPlan.compute_promotion_plan(
          Ecto.UUID.generate(),
          source_tenant_id,
          target_tenant_id,
          process_key,
          permission_checker: allow()
        )

      assert result == {:error, :empty_plan}
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "compute_promotion_plan/5 against a source_tenant_id that
  # is itself a production tenant returns the invalid-promotion-source error before
  # reading any process_definitions row"
  # ---------------------------------------------------------------------------------

  describe "compute_promotion_plan/5 -- acceptance criterion 3 (production-tenant source)" do
    test "source_tenant_id classified :production -- {:error, :invalid_promotion_source}, even with a malformed target_tenant_id" do
      source_tenant_id = Ecto.UUID.generate()

      result =
        PromotionPlan.compute_promotion_plan(
          Ecto.UUID.generate(),
          source_tenant_id,
          "not-a-uuid-at-all",
          unique_process_key(),
          permission_checker: allow(),
          tenant_classifier: fn _tenant_id -> :production end
        )

      # If step 3 (schema resolution) had run first, this call would instead
      # return {:error, :invalid_tenant_id} for the malformed target. Getting
      # :invalid_promotion_source proves the classifier check short-circuited
      # everything after it, per design §3.2 steps 1-2's fixed order.
      assert result == {:error, :invalid_promotion_source}
    end

    test "source_tenant_id classified :test (the real default classifier) is never rejected on this ground" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id} = provisioned_tenant()

      process_key = unique_process_key()

      insert_active_definition!(source_schema, %{
        name: process_key,
        version: "1.0.0",
        graph: %{"nodes" => [%{"id" => "n1", "node_type" => "START"}], "edges" => []}
      })

      assert {:ok, _plan} =
               PromotionPlan.compute_promotion_plan(
                 Ecto.UUID.generate(),
                 source_tenant_id,
                 target_tenant_id,
                 process_key,
                 permission_checker: allow()
                 # No opts[:tenant_classifier] -- exercises the real
                 # default_tenant_classifier/1, per design §9.2.
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # permission_checker gate (design §9.1) -- precedes every other check, and has no
  # built-in default.
  # ---------------------------------------------------------------------------------

  describe "compute_promotion_plan/5 -- permission_checker gate" do
    test "permission_checker returning false -- {:error, :forbidden}, even with a malformed target_tenant_id (proves this is the very first check)" do
      source_tenant_id = Ecto.UUID.generate()

      result =
        PromotionPlan.compute_promotion_plan(
          Ecto.UUID.generate(),
          source_tenant_id,
          "not-a-uuid-at-all",
          unique_process_key(),
          permission_checker: deny()
        )

      assert result == {:error, :forbidden}
    end

    test "omitting opts[:permission_checker] entirely raises KeyError -- no silent allow-everything default" do
      assert_raise KeyError, fn ->
        PromotionPlan.compute_promotion_plan(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          unique_process_key(),
          []
        )
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # invalid_tenant_id -- design §3.2 step 3, reached only after permission_checker
  # and tenant_classifier both pass.
  # ---------------------------------------------------------------------------------

  describe "compute_promotion_plan/5 -- invalid_tenant_id" do
    test "a malformed source_tenant_id (after permission_checker/tenant_classifier both pass) returns {:error, :invalid_tenant_id}" do
      result =
        PromotionPlan.compute_promotion_plan(
          Ecto.UUID.generate(),
          "not-a-uuid",
          Ecto.UUID.generate(),
          unique_process_key(),
          permission_checker: allow()
        )

      assert result == {:error, :invalid_tenant_id}
    end
  end

  # ---------------------------------------------------------------------------------
  # Diff mechanics beyond AC1's all-:added case -- :modified and :removed change_kind,
  # and the before(=target)/after(=source) convention (design §2.2).
  # ---------------------------------------------------------------------------------

  describe "compute_promotion_plan/5 -- diff mechanics beyond AC1 (modified/removed change_kind)" do
    test "overlapping definitions produce a mix of :added, :modified and :removed entries, and byte-identical units produce no entry" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      target_graph = %{
        "nodes" => [
          %{"id" => "n1", "node_type" => "START"},
          %{
            "id" => "n2",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"service_id" => "svc-OLD"}
          },
          %{"id" => "n5", "node_type" => "HUMAN_TASK"}
        ],
        "edges" => [%{"id" => "e1", "source" => "n1", "target" => "n2"}]
      }

      source_graph = %{
        "nodes" => [
          %{"id" => "n1", "node_type" => "START"},
          %{
            "id" => "n2",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"service_id" => "svc-NEW"}
          },
          %{"id" => "n4", "node_type" => "END"}
        ],
        "edges" => [%{"id" => "e1", "source" => "n1", "target" => "n2"}]
      }

      insert_active_definition!(target_schema, %{
        name: process_key,
        version: "1.0.0",
        graph: target_graph
      })

      insert_active_definition!(source_schema, %{
        name: process_key,
        version: "2.0.0",
        graph: source_graph
      })

      assert {:ok, plan} =
               PromotionPlan.compute_promotion_plan(
                 Ecto.UUID.generate(),
                 source_tenant_id,
                 target_tenant_id,
                 process_key,
                 permission_checker: allow()
               )

      by_id = Map.new(plan.entries, &{{&1.type, &1.id}, &1})

      # n1 and e1 are byte-identical on both sides -- no entry at all for either.
      refute Map.has_key?(by_id, {:graph_node, "n1"})
      refute Map.has_key?(by_id, {:graph_edge, "e1"})

      # n2: same node_type, differing attributes.service_id -> :modified at BOTH the
      # :graph_node level (whole raw map differs) and the :service_binding level (the
      # raw string value differs). `before` is the TARGET's value, `after` the
      # SOURCE's, per design §2.2.
      assert %{
               change_kind: :modified,
               before: %{"attributes" => %{"service_id" => "svc-OLD"}},
               after: %{"attributes" => %{"service_id" => "svc-NEW"}}
             } = by_id[{:graph_node, "n2"}]

      assert %{change_kind: :modified, before: "svc-OLD", after: "svc-NEW"} =
               by_id[{:service_binding, "n2"}]

      # n5 exists only at target -> :removed (after: nil).
      assert %{change_kind: :removed, after: nil} = by_id[{:graph_node, "n5"}]

      # n4 exists only at source -> :added (before: nil).
      assert %{change_kind: :added, before: nil} = by_id[{:graph_node, "n4"}]

      assert plan.base_version == "1.0.0"
    end
  end
end
