defmodule Letflow.Definitions.PromotionTest do
  @moduledoc """
  Tests for `Letflow.Definitions.Promotion.promote_definition/3` (REQ-037,
  ENV-03). See `test/specs/REQ-037.md` for the full test-case rationale and
  `lib/letflow/design/promotion_review_state_machine.md` §3 for the
  gate-approved design this file exercises.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

  ## Fixture strategy -- mirrors `promotion_plan_test.exs`'s two-tenant pattern

  `promote_definition/3` reads/writes `process_definitions` under TWO tenants'
  schemas (source and target), exactly like REQ-036's
  `PromotionPlan.compute_promotion_plan/5` -- so each test that needs real
  rows provisions TWO real tenant schemas via `provisioned_tenant/0` (real
  `CREATE SCHEMA` + `TenantProvisioning.replay_migrations/1`). Sandbox
  `:auto` mode + manual `on_exit/1` cleanup, `async: false` for the whole
  module -- same reasoning as `promotion_plan_test.exs`'s own moduledoc.

  ## `promote_definition/3` takes an in-memory `PromotionReview.t()` struct,
  not a `review_id` -- no `promotion_reviews` row needs to exist

  Unlike every function in `PromotionReviewStore`, `promote_definition/3`
  never reads `promotion_reviews` at all (design §3.2 step 1 decodes
  `review.serialised_plan` directly off the struct it was handed). Every
  fixture below builds a `%PromotionReview{}` struct literal in memory --
  never persisted -- exactly matching the design's own algorithm, which has
  no `Repo.get(PromotionReview, ...)` step.

  ## `opts[:permission_checker]` and `opts[:event_appender]` are supplied
  explicitly on EVERY call in this file

  Neither has a built-in default (`Keyword.fetch!/2` for both -- design §3.2,
  reusing `PromotionPlan.promotion_opts()`'s own no-default stance for
  `permission_checker`, plus a new, equally-no-default `event_appender` opt
  this design adds since there is no working `EventStore.append/2` call site
  for a definition-level event yet, design §5 OQ-1). Every single call below
  passes both explicitly, mirroring `promotion_plan_test.exs`'s own
  `opts[:permission_checker]` convention -- never relying on a default that
  does not exist.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.ProcessDefinition

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- mirrors promotion_plan_test.exs's own copies exactly
  # (per this project's established per-test-file self-sufficiency convention).
  # ---------------------------------------------------------------------------------

  # Adopts the shared `Letflow.TenantFixture` (ISS-0109 / GH#358) in place of this
  # file's own hand-rolled `insert_tenant!/0` + `drop_schema!/1` + `provisioned_tenant/0`
  # copies. Behaviour-preserving by construction (design §7.7): the same tenant row is
  # inserted, the same sandbox `:auto` switch is made, the same schema is provisioned,
  # the same replay is run, and the same three teardown statements are issued in the
  # same order -- the fixture additionally asserts the resulting schema is COMPLETE (so
  # a missing table is named here rather than surfacing 500 lines later as an opaque
  # 42P01) and emits one greppable `LETFLOW_TENANT_FIXTURE phase=teardown` line, so a
  # post-test drop can never again be mistaken for a mid-test one.
  defp provisioned_tenant do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: "req037-promo",
      display_name: "REQ-037 Promotion Test Tenant"
    )
  end

  defp unique_process_key(prefix \\ "req037-promo-proc") do
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

  # Guarded, single-statement UPDATE -- create_changeset/2 never casts :status
  # (design INV-DEF-8), mirrors migrations_test.exs's/promotion_plan_test.exs's
  # own activate!/2 helper exactly.
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

  # A no-op event_appender that records what it was called with by sending a
  # message to the test process -- real function value, no mock/stub library.
  defp recording_event_appender(test_pid) do
    fn event_attrs, prefix ->
      send(test_pid, {:event_appended, event_attrs, prefix})
      {:ok, %{event_id: Ecto.UUID.generate()}}
    end
  end

  # Builds an in-memory (never persisted) PromotionReview struct, matching the
  # exact envelope insert_review/2 would have produced (design §2.3 step 4 --
  # the FULL plan, not just entries). No tenant_id field -- REQ-064 (Decision
  # 0006 D2) dropped promotion_reviews.tenant_id; the target tenant is read
  # from plan["target_tenant_id"] inside serialised_plan instead (see
  # Promotion.promote_definition/3's own moduledoc).
  defp review_for(plan, overrides \\ %{}) do
    base = %{
      id: Ecto.UUID.generate(),
      plan_digest: PromotionDigest.compute_plan_digest(plan),
      def_id: plan.process_key,
      serialised_plan: Jason.encode!(plan),
      requested_by: Ecto.UUID.generate(),
      status: :approved,
      row_version: 2
    }

    struct(PromotionReview, Map.merge(base, overrides))
  end

  # ---------------------------------------------------------------------------------
  # promote_definition/3 -- basic success path
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- basic success path" do
    test "version-pointer move (deprecate old active, activate new target row) + event-append, both succeed" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "2.0.0",
          description: "source description",
          stage: "S2",
          graph: %{"nodes" => [%{"id" => "n1", "node_type" => "START"}], "edges" => []}
        })

      # Target starts with NO existing row for this process_key -- no conflict,
      # no prior active row to have deprecated (that half is asserted below via
      # a zero-active-count check for the row that never existed).
      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)
      actor_id = Ecto.UUID.generate()
      test_pid = self()

      assert {:ok, result} =
               Promotion.promote_definition(actor_id, review,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(test_pid)
               )

      assert result.source_definition_id == source_def.id
      assert result.process_key == process_key
      assert is_binary(result.target_definition_id)
      refute result.target_definition_id == source_def.id

      target_row =
        Repo.get!(ProcessDefinition, result.target_definition_id, prefix: target_schema)

      assert target_row.status == :active
      assert target_row.name == process_key
      assert target_row.version == "2.0.0"
      assert target_row.description == "source description"
      assert target_row.stage == "S2"
      assert target_row.created_by == actor_id

      # Source row is untouched by this operation -- promote_definition/3 only
      # ever writes to the TARGET tenant's schema.
      reloaded_source = Repo.get!(ProcessDefinition, source_def.id, prefix: source_schema)
      assert reloaded_source.status == :active

      assert_received {:event_appended, event_attrs, received_prefix}
      assert received_prefix == target_schema
      assert event_attrs.event_type == "DEFINITION_PROMOTED"
      assert event_attrs.actor_id == actor_id
      assert event_attrs.review_id == review.id
      assert event_attrs.source_tenant_id == source_tenant_id
      assert event_attrs.target_tenant_id == target_tenant_id
      assert event_attrs.source_definition_id == source_def.id
      assert event_attrs.target_definition_id == result.target_definition_id
      assert event_attrs.process_key == process_key
    end

    test "a pre-existing ACTIVE target row for the same process_key is deprecated as part of the same swap" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "3.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      # deprecate_previous_active/3 no longer filters on tenant_id at all
      # (REQ-064, Decision 0006 D2 -- process_definitions.tenant_id was
      # dropped); target_prefix's own schema-per-tenant scoping is the only
      # scoping mechanism now.
      previous_target_def =
        insert_active_definition!(target_schema, %{
          name: process_key,
          version: "1.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: previous_target_def.id,
        base_version: "1.0.0",
        entries: []
      }

      review = review_for(plan)
      test_pid = self()

      assert {:ok, result} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(test_pid)
               )

      new_target_row =
        Repo.get!(ProcessDefinition, result.target_definition_id, prefix: target_schema)

      assert new_target_row.status == :active
      assert new_target_row.version == "3.0.0"

      reloaded_previous =
        Repo.get!(ProcessDefinition, previous_target_def.id, prefix: target_schema)

      assert reloaded_previous.status == :deprecated

      assert_received {:event_appended, _event_attrs, _prefix}
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:permission_checker] -- fail-closed, no built-in default, checked before
  # any DB read (design §3.2 step 2, mirrors PromotionPlan's own convention).
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- opts[:permission_checker]" do
    test "permission_checker returning false -> {:error, :forbidden}, before any process_definitions read" do
      source_tenant_id = Ecto.UUID.generate()
      target_tenant_id = Ecto.UUID.generate()
      process_key = unique_process_key()

      # Neither tenant is provisioned (no CREATE SCHEMA ever ran) -- if
      # permission_checker did not short-circuit BEFORE any read, the very next
      # step (schema resolution / a Repo.get_by against a schema that doesn't
      # exist) would raise instead of cleanly returning {:error, :forbidden}.
      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      assert {:error, :forbidden} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: deny(),
                 event_appender: fn _attrs, _prefix -> {:ok, %{}} end
               )
    end

    test "omitting opts[:permission_checker] entirely raises KeyError -- no silent allow-everything default" do
      review =
        review_for(%{
          source_tenant_id: Ecto.UUID.generate(),
          target_tenant_id: Ecto.UUID.generate(),
          process_key: unique_process_key(),
          source_definition_id: nil,
          target_definition_id: nil,
          base_version: nil,
          entries: []
        })

      assert_raise KeyError, fn ->
        Promotion.promote_definition(Ecto.UUID.generate(), review,
          event_appender: fn _attrs, _prefix -> {:ok, %{}} end
        )
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:event_appender] -- fail-closed, no built-in default (design §3.2 step 9,
  # OQ-1) -- the "and event-append" half of ENV-03 this design deliberately does
  # not paper over with a silent no-op default.
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- opts[:event_appender]" do
    test "omitting opts[:event_appender] entirely raises KeyError -- no silent no-op default" do
      review =
        review_for(%{
          source_tenant_id: Ecto.UUID.generate(),
          target_tenant_id: Ecto.UUID.generate(),
          process_key: unique_process_key(),
          source_definition_id: nil,
          target_definition_id: nil,
          base_version: nil,
          entries: []
        })

      assert_raise KeyError, fn ->
        Promotion.promote_definition(Ecto.UUID.generate(), review, permission_checker: allow())
      end
    end

    test "an event_appender returning {:error, _} propagates unchanged, after the version-pointer move has already committed" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "1.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      failing_event_appender = fn _event_attrs, _prefix -> {:error, :event_store_unavailable} end

      assert {:error, :event_store_unavailable} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 event_appender: failing_event_appender
               )

      # Design §3.2 step 9 / §5 OQ-1: the version-pointer move is NOT rolled
      # back when the event-append fails -- the transaction (steps 7-8) already
      # committed before step 9 ever runs. This is the real, stated gap the
      # design does not paper over; this test pins that it stays that way
      # rather than silently changing shape.
      assert Repo.aggregate(
               from(d in ProcessDefinition,
                 where: d.status == :active
               ),
               :count,
               prefix: target_schema
             ) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:tenant_classifier] -- reuse, not reinvention (design INV-PRM04-5): a
  # production-classified source_tenant_id is rejected before promote_definition/3
  # ever attempts a process_definitions read.
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- opts[:tenant_classifier]" do
    test "source_tenant_id classified :production -> {:error, :invalid_promotion_source}" do
      source_tenant_id = Ecto.UUID.generate()

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: Ecto.UUID.generate(),
        process_key: unique_process_key(),
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      assert {:error, :invalid_promotion_source} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 tenant_classifier: fn _tenant_id -> :production end,
                 event_appender: fn _attrs, _prefix -> {:ok, %{}} end
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # promote_definition/3 -- :source_definition_missing (design §3.2 step 5, a new
  # error case not present on PromotionPlan.compute_error/0)
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- :source_definition_missing" do
    test "the source tenant has no ACTIVE row for process_key -> {:error, :source_definition_missing}" do
      %{tenant_id: source_tenant_id} = provisioned_tenant()
      %{tenant_id: target_tenant_id} = provisioned_tenant()

      process_key = unique_process_key()

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      assert {:error, :source_definition_missing} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 event_appender: fn _attrs, _prefix -> {:ok, %{}} end
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0733 GAP A -- write_target_definition/5's new step 8(c)
  # (`lib/letflow/design/iss0733-promotion-audit-and-platform-events-read.md`
  # §1) writes exactly one `audit_entries` row, in the TARGET tenant's own
  # schema, for a successful promotion. Pre-fix (`main`,
  # `write_target_definition/4`), `promote_definition/3` never calls
  # `Letflow.Audit` at all -- 0 rows after a successful promotion. This is the
  # exact regression this test is designed to prove: run unmodified against
  # `main` in a throwaway worktree, it finds 0; against this branch, it finds
  # exactly 1 with the fields §1.4 specifies. See the WF-03 handoff's
  # `result.summary` for both runs' quoted output.
  # ---------------------------------------------------------------------------------

  describe "ISS-0733 GAP A -- audit_entries row" do
    test "a successful promotion writes one definition.promote audit row in the target schema" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "1.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)
      actor_id = Ecto.UUID.generate()

      # Before the promotion, both schemas' audit_entries tables are empty --
      # this pins that the row below is genuinely produced by THIS call, not
      # a pre-existing fixture.
      assert Repo.aggregate(Entry, :count, prefix: source_schema) == 0
      assert Repo.aggregate(Entry, :count, prefix: target_schema) == 0

      assert {:ok, result} =
               Promotion.promote_definition(actor_id, review,
                 permission_checker: allow(),
                 event_appender: fn _event_attrs, _prefix ->
                   {:ok, %{event_id: Ecto.UUID.generate()}}
                 end
               )

      # 0 audit_entries rows in the SOURCE tenant's schema -- this write path
      # only ever touches the target tenant (design §1.5).
      assert Repo.aggregate(Entry, :count, prefix: source_schema) == 0

      entries = Repo.all(Entry, prefix: target_schema)
      assert length(entries) == 1
      assert [entry] = entries

      assert entry.action == "definition.promote"
      assert entry.resource_type == "definition"
      assert entry.resource_id == result.target_definition_id
      assert entry.actor_id == actor_id
      assert entry.before_state == nil

      assert entry.after_state["event_type"] == "DEFINITION_PROMOTED"
      assert entry.after_state["actor_id"] == actor_id
      assert entry.after_state["review_id"] == review.id
      assert entry.after_state["source_tenant_id"] == source_tenant_id
      assert entry.after_state["target_tenant_id"] == target_tenant_id
      assert entry.after_state["source_definition_id"] == source_def.id
      assert entry.after_state["target_definition_id"] == result.target_definition_id
      assert entry.after_state["process_key"] == process_key
    end

    test "an event_appender failure does not roll back the already-committed audit row" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "1.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      failing_event_appender = fn _event_attrs, _prefix -> {:error, :event_store_unavailable} end

      assert {:error, :event_store_unavailable} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 event_appender: failing_event_appender
               )

      # design §1.1/§3.2 step 9: the audit write (step 8c) is inside the SAME
      # transaction as the version-pointer swap (steps 7-8), which already
      # committed before step 9 (the event-append) ever runs -- so a failing
      # event_appender must NOT undo the audit row, exactly like it does not
      # undo the version-pointer move itself (already pinned by the sibling
      # `opts[:event_appender]` describe block above).
      assert [entry] = Repo.all(Entry, prefix: target_schema)
      assert entry.action == "definition.promote"
    end

    test "ISS-0981: a failed audit insert rolls back the whole version-pointer swap, not just the audit write" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "1.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)
      actor_id = Ecto.UUID.generate()

      Repo.query!(~s(DROP TABLE "#{target_schema}".audit_entries))

      # ISS-0981: write_target_definition/5 is now rescue-hardened -- a raise
      # from step 8(c)'s same-transaction Audit.insert_entry/3 call, forced
      # here by dropping the TARGET schema's own audit_entries table (step
      # 8(c) writes there, per write_target_definition/5's own moduledoc),
      # converts into {:error, {:transaction_failed, exception}} instead of
      # escaping uncaught.
      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Promotion.promote_definition(actor_id, review,
                 permission_checker: allow(),
                 event_appender: fn _event_attrs, _prefix ->
                   {:ok, %{event_id: Ecto.UUID.generate()}}
                 end
               )

      # The whole version-pointer swap (new row insert, deprecate-previous,
      # activate-new) rolled back along with the failed audit insert -- zero
      # :active rows for this process_key in the target schema.
      active_count =
        ProcessDefinition
        |> where([d], d.name == ^process_key and d.status == :active)
        |> Repo.aggregate(:count, prefix: target_schema)

      assert active_count == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # T-2597 (pilot gap G14): the OUTBOUND ALLOW-LIST fence on the PROMOTION path.
  #
  # A promoted graph is a graph of the TARGET tenant, so the TARGET tenant's
  # own list decides what it may reach -- the same rule the other three
  # activation paths apply. Without the fence a promotion activated a graph in
  # a tenant whose list was never read (a tenant whose list is empty reaches
  # nothing, so the copy would have reached everything).
  # ---------------------------------------------------------------------------------

  describe "T-2597: the OUTBOUND ALLOW-LIST fence on the promotion path" do
    # START -> an inline HTTP step -> END. The step's endpoint names a host.
    defp http_graph do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "http",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{
              "endpoint" => "https://api.example.com/hook",
              "method" => "POST",
              "timeout_ms" => 30_000
            }
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "http"},
          %{"id" => "e2", "source" => "http", "target" => "end"}
        ]
      }
    end

    defp http_plan(source_tenant_id, target_tenant_id, process_key, source_definition_id) do
      %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_definition_id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }
    end

    test "a promotion whose graph reaches a host the TARGET tenant does not allow is refused" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "2.0.0",
          description: "source description",
          stage: "S2",
          graph: http_graph()
        })

      review =
        review_for(http_plan(source_tenant_id, target_tenant_id, process_key, source_def.id))

      actor_id = Ecto.UUID.generate()

      # The TARGET tenant's list is empty (deny by default): the promotion is
      # refused with the same code the other three activation paths answer.
      assert {:error, {:outbound_destinations_invalid, violations}} =
               Promotion.promote_definition(actor_id, review,
                 permission_checker: allow(),
                 event_appender: fn _event_attrs, _prefix ->
                   {:ok, %{event_id: Ecto.UUID.generate()}}
                 end
               )

      assert :outbound_channel_not_allowed in Enum.map(violations, & &1.code)

      # The refused promotion wrote NOTHING into the target tenant: no row at
      # all, and no ACTIVE row.
      rows =
        ProcessDefinition
        |> where([d], d.name == ^process_key)
        |> Repo.all(prefix: target_schema)

      assert rows == []
    end

    test "the same promotion succeeds once the TARGET tenant's own list allows the host" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "2.0.0",
          description: "source description",
          stage: "S2",
          graph: http_graph()
        })

      actor_id = Ecto.UUID.generate()

      {:ok, _channel} = Letflow.OutboundDestinations.add(target_schema, actor_id, "http", nil)

      {:ok, _host} =
        Letflow.OutboundDestinations.add(target_schema, actor_id, "http", "api.example.com")

      review =
        review_for(http_plan(source_tenant_id, target_tenant_id, process_key, source_def.id))

      assert {:ok, result} =
               Promotion.promote_definition(actor_id, review,
                 permission_checker: allow(),
                 event_appender: fn _event_attrs, _prefix ->
                   {:ok, %{event_id: Ecto.UUID.generate()}}
                 end
               )

      target_row =
        Repo.get!(ProcessDefinition, result.target_definition_id, prefix: target_schema)

      assert target_row.status == :active
    end
  end
end
