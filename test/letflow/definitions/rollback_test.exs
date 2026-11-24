defmodule Letflow.Definitions.RollbackTest do
  @moduledoc """
  Tests for `Letflow.Definitions.rollback_definition_version/4` (REQ-038,
  PRM-08). See `test/specs/REQ-038.md` for the full test-case rationale and
  `lib/letflow/design/req038-promotion-rollback.md` for the gate-approved
  design this file exercises -- in particular §6/§7/INV-RB-10, the
  cardinality-branched `promotion_reviews` supersede-lookup that triggered
  this design's own CODE-DESIGN-VALIDATOR rework cycle and is this
  requirement's single most scrutinized piece of behavior.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

  ## Fixture strategy -- mirrors `store_test.exs`'s and `promotion_test.exs`'s
  established patterns, not a new mechanism

  `rollback_definition_version/4` lives directly on `Letflow.Definitions` (not
  a submodule, per the design doc §1's own scope note), so this file follows
  `store_test.exs`'s `provisioned_tenant/0` + Sandbox `:auto` + `async: false`
  convention exactly (real `CREATE SCHEMA` + `TenantProvisioning.replay_migrations/1`
  -- `Ecto.Migrator` needs a second real DB connection the ordinary sandboxed
  connection can't hand out). Only ONE tenant schema is needed per test
  (rollback is single-tenant, design §4.1/OQ-2), unlike `promotion_test.exs`'s
  two-tenant fixtures.

  `two_version_history!/2` below is the one fixture every AC1/guard-order/
  double-rollback test shares: it builds a process_key with two versions by
  calling the REAL, already-merged `Definitions.create/2` + `Definitions.activate/2`
  twice -- `activate/2`'s own deprecate-then-activate swap (REQ-030, already
  gate-approved) is what leaves the first version `:deprecated` and the second
  `:active`, which is the *ordinary*, already-shipped way a process_key
  accumulates rollback-eligible history. No row is ever written via a raw
  `Repo.insert!`/`Repo.update_all` bypassing the real state-machine functions.

  `promotion_reviews` fixtures (`review_pending!/3`, `review_approved!/3`,
  `review_applied!/3`) mirror `promotion_review_store_test.exs`'s own
  `insert_review_fixture!`/`approved_review!` helpers -- every row is created
  via the real `PromotionReviewStore` transition functions, never a raw insert
  bypassing that module's own guarded state machine. Each review's `entries`
  carries a fresh `System.unique_integer/1`-tagged node id so its
  `plan_digest` is always unique -- required so that two reviews for the SAME
  process_key (the exact scenario the ambiguous-match tests below need) don't
  collide on `uq_promotion_review_active_digest` (`(tenant_id, plan_digest)`
  while `pending_review`/`approved`).

  Every test provisions its own tenant and uses `unique_process_key/1`
  (`System.unique_integer/1`-suffixed) -- no shared or hard-coded identifiers,
  no test depends on another test's data or execution order, no wall-clock
  dependency anywhere (`docs/guides/test_developer_guide.md` §1's determinism
  rule).

  ## `opts[:permission_checker]` and `opts[:event_appender]` are supplied
  explicitly on EVERY call in this file

  Neither has a built-in default (`Keyword.fetch!/2` for both, design §4.1/
  §4.2, INV-RB-2) -- every call below passes both explicitly, mirroring
  `promotion_test.exs`'s own convention. Several tests below pass an
  "exploding" `event_appender` (`raise`s if invoked) specifically to PROVE a
  guard short-circuited before Step 3 ever ran, not merely to assert it did --
  the same "prove it, don't assert around it" technique
  `test/letflow/definitions/store_test.exs`'s AC6 block and
  `test/specs/REQ-031.md`'s short-circuit tests already established in this
  codebase.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.TenantProvisioning

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # Adopts the shared `Letflow.TenantFixture` (ISS-0109/GH#358, ISS-0116/GH#370) in
  # place of this file's own hand-rolled `insert_tenant!/0` + `drop_schema!/1` +
  # `provisioned_tenant/0` copies -- same rationale as promotion_test.exs's own
  # adoption (see that file's comment): behaviour-preserving by construction, adds a
  # completeness assertion post-replay, and emits a greppable
  # `LETFLOW_TENANT_FIXTURE` teardown marker. This file was the un-instrumented
  # module ISS-0116 caught a live 3F000 :invalid_schema_name reproduction in
  # (rollback_test.exs:642) -- adopting the fixture here is that issue's own
  # prescribed step 1, so the *next* occurrence carries a full
  # `capture_schema_state/1` report instead of a bare Postgrex error.
  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      Letflow.TenantFixture.provisioned_tenant!(
        slug_prefix: "req038-rollback",
        display_name: "REQ-038 Rollback Test Tenant"
      )

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  # A well-formed schema_name that DECODES to a real tenant_id (design §4.1's
  # own note: tenant_id_for_schema_name/1 is "a pure, no-I/O string
  # transform") but whose Postgres schema was never actually CREATEd --
  # provision_tenant_schema/1 is deliberately never called. Used only by the
  # AC5 "before any row is read or locked" test below.
  defp unprovisioned_schema_name do
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(Ecto.UUID.generate())
    schema_name
  end

  defp unique_process_key(prefix \\ "req038-rollback-proc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Minimal structurally-valid graph -- one START with an outgoing edge to one
  # END, satisfies Graph.validate_graph/1 so create/2 never rejects it for an
  # unrelated reason. Mirrors store_test.exs's valid_graph/0.
  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_attrs(overrides) do
    Map.merge(
      %{
        name: unique_process_key(),
        version: "1.0.0",
        graph: valid_graph(),
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp create!(schema_name, overrides) do
    assert {:ok, definition} = Definitions.create(create_attrs(overrides), prefix: schema_name)
    definition
  end

  defp activate!(schema_name, id) do
    assert {:ok, %{definition: definition}} = Definitions.activate(id, prefix: schema_name)
    definition
  end

  defp deprecate!(schema_name, id) do
    assert {:ok, definition} = Definitions.deprecate(id, prefix: schema_name)
    definition
  end

  defp archive!(schema_name, id) do
    assert {:ok, definition} = Definitions.archive(id, prefix: schema_name)
    definition
  end

  defp reread!(schema_name, id) do
    Repo.get!(ProcessDefinition, id, prefix: schema_name)
  end

  # Builds a process_key with two versions, v1 :deprecated and v2 :active --
  # via the REAL create/2 + activate/2 (activate/2's own already-shipped
  # deprecate-then-activate swap, REQ-030), never a raw Repo write. This is
  # the ordinary, already-shipped shape of "a process_key with rollback-
  # eligible history" every AC1/guard-order/double-rollback test below needs.
  defp two_version_history!(
         schema_name,
         process_key,
         v1_version \\ "1.0.0",
         v2_version \\ "2.0.0"
       ) do
    v1 = create!(schema_name, %{name: process_key, version: v1_version})
    _v1_active = activate!(schema_name, v1.id)
    v2 = create!(schema_name, %{name: process_key, version: v2_version})
    v2_active = activate!(schema_name, v2.id)

    %{v1: reread!(schema_name, v1.id), v2: v2_active}
  end

  # Task.async gives this read a genuinely separate BEAM process with its
  # own Postgres connection -- Sandbox mode is :auto (via provisioned_tenant/0,
  # real commits, no wrapping transaction), so this is a real, independent
  # re-read, not the same connection that ran TX1. Extracted to its own named
  # function (rather than an anonymous fn inline in the test body) so it
  # doesn't compound the enclosing test's already-long generated name.
  defp reread_statuses_via_separate_connection(prefix, id1, id2) do
    Task.async(fn ->
      {Repo.get!(ProcessDefinition, id1, prefix: prefix).status,
       Repo.get!(ProcessDefinition, id2, prefix: prefix).status}
    end)
    |> Task.await()
  end

  defp allow, do: fn _actor_id, _tenant_id -> true end
  defp deny, do: fn _actor_id, _tenant_id -> false end

  # A no-op event_appender that records what it was called with by sending a
  # message to the test process -- real function value, no mock/stub library.
  # Mirrors promotion_test.exs's recording_event_appender/1 exactly.
  defp recording_event_appender(test_pid) do
    fn event_attrs, prefix ->
      send(test_pid, {:event_appended, event_attrs, prefix})
      {:ok, %{event_id: Ecto.UUID.generate()}}
    end
  end

  # Raises if ever invoked -- used to PROVE (not merely assert) that a guard
  # short-circuited before Step 3 (the event-append) ever ran. If this
  # function is called, the test fails with the raised exception rather than
  # silently passing.
  defp exploding_event_appender do
    fn _event_attrs, _prefix ->
      raise "event_appender must not be called on this path"
    end
  end

  # A structurally-real PromotionPlan.t()-shaped map, mirroring
  # promotion_review_store_test.exs's sample_plan/2. `entries` carries a fresh
  # unique node id on every call so plan_digest is always unique -- see this
  # file's moduledoc for why that's load-bearing for the ambiguous-match
  # fixtures below.
  defp sample_plan(tenant_id, process_key) do
    %{
      source_tenant_id: Ecto.UUID.generate(),
      target_tenant_id: tenant_id,
      process_key: process_key,
      source_definition_id: Ecto.UUID.generate(),
      target_definition_id: nil,
      base_version: nil,
      entries: [
        %{
          type: :graph_node,
          id: "n-#{System.unique_integer([:positive, :monotonic])}",
          change_kind: :added,
          before: nil,
          after: %{"id" => "n1", "node_type" => "START"}
        }
      ]
    }
  end

  defp digest_for(plan), do: PromotionDigest.compute_plan_digest(plan)

  # pending_review, via the real insert_review/2 (never a raw Repo.insert!).
  defp review_pending!(schema_name, tenant_id, process_key) do
    plan = sample_plan(tenant_id, process_key)
    digest = digest_for(plan)

    assert {:ok, review} =
             PromotionReviewStore.insert_review(
               %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
               prefix: schema_name
             )

    review
  end

  # pending_review -> approved, via the real approve_review/4.
  defp review_approved!(schema_name, tenant_id, process_key) do
    review = review_pending!(schema_name, tenant_id, process_key)

    assert {:ok, approved} =
             PromotionReviewStore.approve_review(
               review.id,
               Ecto.UUID.generate(),
               review.plan_digest,
               prefix: schema_name
             )

    approved
  end

  # approved -> applied, via the real mark_review_applied/2.
  defp review_applied!(schema_name, tenant_id, process_key) do
    approved = review_approved!(schema_name, tenant_id, process_key)

    assert {:ok, applied} =
             PromotionReviewStore.mark_review_applied(approved.id, prefix: schema_name)

    applied
  end

  # T-2597 (SF-04): the outbound allow-list fence on the version-rollback path.
  describe "rollback_definition_version/4 -- the outbound allow-list fence (T-2597)" do
    defp http_graph do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "step",
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
          %{"id" => "e1", "source" => "start", "target" => "step"},
          %{"id" => "e2", "source" => "step", "target" => "end"}
        ]
      }
    end

    defp rollback_opts(schema_name) do
      [
        prefix: schema_name,
        permission_checker: allow(),
        event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
      ]
    end

    test "OD-RB: a rollback onto a graph reaching a host the list no longer allows is refused, and the pointer stays" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()

      assert {:ok, _} = Letflow.OutboundDestinations.add(schema_name, nil, "http", nil)

      assert {:ok, _} =
               Letflow.OutboundDestinations.add(schema_name, nil, "http", "api.example.com")

      v1 = create!(schema_name, %{name: process_key, version: "1.0.0", graph: http_graph()})
      activate!(schema_name, v1.id)
      v2 = create!(schema_name, %{name: process_key, version: "2.0.0"})
      activate!(schema_name, v2.id)

      # The host leaves the list after v1 was active.
      assert {:ok, _} =
               Letflow.OutboundDestinations.remove(schema_name, nil, "http", "api.example.com")

      assert {:error, {:outbound_destinations_invalid, violations}} =
               Definitions.rollback_definition_version(
                 process_key,
                 "1.0.0",
                 Ecto.UUID.generate(),
                 rollback_opts(schema_name)
               )

      assert :outbound_destination_not_allowed in Enum.map(violations, & &1.code)
      assert reread!(schema_name, v1.id).status == :deprecated
      assert reread!(schema_name, v2.id).status == :active

      # The same rollback passes once the list allows the host again.
      assert {:ok, _} =
               Letflow.OutboundDestinations.add(schema_name, nil, "http", "api.example.com")

      assert {:ok, result} =
               Definitions.rollback_definition_version(
                 process_key,
                 "1.0.0",
                 Ecto.UUID.generate(),
                 rollback_opts(schema_name)
               )

      assert result.definition_id == v1.id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1: "rolling back to a version with status SUPERSEDED (that was previously
  # ACTIVE) succeeds and flips the pointer: the target becomes ACTIVE and the
  # former ACTIVE becomes SUPERSEDED"
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- AC1: rollback to a SUPERSEDED version flips the pointer" do
    test "rolling back from v2 (active) to v1 (deprecated, previously active) succeeds and flips both rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1, v2: v2} = two_version_history!(schema_name, process_key)

      assert v1.status == :deprecated
      assert v2.status == :active

      actor_id = Ecto.UUID.generate()
      test_pid = self()

      assert {:ok, result} =
               Definitions.rollback_definition_version(process_key, v1.version, actor_id,
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(test_pid)
               )

      assert result.definition_id == v1.id
      assert result.version == v1.version
      assert result.rolled_back_from_version == v2.version
      assert is_binary(result.event_id)
      assert result.superseded_review_id == nil

      reread_v1 = reread!(schema_name, v1.id)
      reread_v2 = reread!(schema_name, v2.id)
      assert reread_v1.status == :active
      assert reread_v2.status == :deprecated

      assert_received {:event_appended, event_attrs, received_prefix}
      assert received_prefix == schema_name
      assert event_attrs.event_type == "DEFINITION_VERSION_ROLLED_BACK"
      assert event_attrs.process_key == process_key
      assert event_attrs.from_version == v2.version
      assert event_attrs.to_version == v1.version
      assert event_attrs.actor_id == actor_id

      # Exactly one event appended (INV-RB-6) -- no second message queued.
      refute_receive {:event_appended, _, _}
    end

    test "after rollback, get_active_by_name/2 returns the rolled-back-to row (status-enum reuse correctness)" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1} = two_version_history!(schema_name, process_key)

      assert {:ok, _result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(self())
               )

      assert {:ok, active} = Definitions.get_active_by_name(process_key, prefix: schema_name)
      assert active.id == v1.id
      assert active.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: "rolling back to a version whose status has never been ACTIVE or
  # SUPERSEDED for this process_key returns the version-never-active error, no
  # rows changed"
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- AC2: version never ACTIVE/SUPERSEDED -> version_never_active" do
    test "target row is still DRAFT (never activated) -> version_never_active, active row untouched" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()

      v1 = create!(schema_name, %{name: process_key, version: "1.0.0"})
      v1_active = activate!(schema_name, v1.id)
      v2_draft = create!(schema_name, %{name: process_key, version: "2.0.0"})

      before_row = reread!(schema_name, v1_active.id)

      assert {:error, :version_never_active} =
               Definitions.rollback_definition_version(process_key, "2.0.0", Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: exploding_event_appender()
               )

      after_row = reread!(schema_name, v1_active.id)
      assert after_row.status == :active
      assert after_row.updated_at == before_row.updated_at

      draft_reread = reread!(schema_name, v2_draft.id)
      assert draft_reread.status == :draft
    end

    test "target_version has no row at all -> version_never_active" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()

      v1 = create!(schema_name, %{name: process_key, version: "1.0.0"})
      _v1_active = activate!(schema_name, v1.id)

      assert {:error, :version_never_active} =
               Definitions.rollback_definition_version(
                 process_key,
                 "9.9.9-nonexistent",
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: exploding_event_appender()
               )
    end

    test "target row is ARCHIVED -- INV-RB-4 excludes :archived from the eligible rollback-target set" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()

      v1 = create!(schema_name, %{name: process_key, version: "1.0.0"})
      v1_active = activate!(schema_name, v1.id)
      v1_deprecated = deprecate!(schema_name, v1_active.id)
      v1_archived = archive!(schema_name, v1_deprecated.id)
      assert v1_archived.status == :archived

      v2 = create!(schema_name, %{name: process_key, version: "2.0.0"})
      _v2_active = activate!(schema_name, v2.id)

      assert {:error, :version_never_active} =
               Definitions.rollback_definition_version(process_key, "1.0.0", Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: exploding_event_appender()
               )

      reread_archived = reread!(schema_name, v1_archived.id)
      assert reread_archived.status == :archived
    end
  end

  # ---------------------------------------------------------------------------------
  # 3 guard cases checked in the CORRECT order -- a test that would catch a
  # reordering, per this run's own task briefing. process_key_not_found (2b)
  # must win even when a :deprecated row matching target_version genuinely
  # exists, because 2b's check (no CURRENT active row) short-circuits before
  # 2d's target-row lookup is ever reached (design §5 step 2, R-Co's own
  # "No current ACTIVE row -- process_key may simply never have been
  # promoted" unification).
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- guard order: process_key_not_found wins over version_never_active" do
    test "no row is currently ACTIVE (all deprecated) -> process_key_not_found, even though a DEPRECATED row matches target_version" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()

      v1 = create!(schema_name, %{name: process_key, version: "1.0.0"})
      v1_active = activate!(schema_name, v1.id)
      v1_deprecated = deprecate!(schema_name, v1_active.id)
      assert v1_deprecated.status == :deprecated
      # No row is :active for this process_key at all right now.

      # If guard ordering were reversed (the target-row lookup evaluated
      # before the current-active check), this call would find v1_deprecated
      # (status :deprecated, matching [:active, :deprecated]) and proceed
      # toward a swap against current_active == nil -- a defect. The actual
      # guard order (2b before 2d) must reject this as process_key_not_found
      # instead.
      assert {:error, :process_key_not_found} =
               Definitions.rollback_definition_version(process_key, "1.0.0", Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: exploding_event_appender()
               )

      reread_v1 = reread!(schema_name, v1_deprecated.id)
      assert reread_v1.status == :deprecated
    end

    test "process_key with zero rows at all -> the identical process_key_not_found error" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()

      assert {:error, :process_key_not_found} =
               Definitions.rollback_definition_version(process_key, "1.0.0", Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: exploding_event_appender()
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3: "rolling back to the currently-ACTIVE version returns the
  # already-active error, no rows changed, no event appended"
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- AC3: rolling back to the currently-ACTIVE version -> already_active" do
    test "target_version == current active version -> already_active, event_appender never called, row unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()

      v1 = create!(schema_name, %{name: process_key, version: "1.0.0"})
      v1_active = activate!(schema_name, v1.id)
      before_row = reread!(schema_name, v1_active.id)

      # exploding_event_appender/0 raises if ever invoked -- this test only
      # passes because the already-active guard fires before Step 3 (the
      # event-append) is ever reached.
      assert {:error, :already_active} =
               Definitions.rollback_definition_version(process_key, "1.0.0", Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: exploding_event_appender()
               )

      after_row = reread!(schema_name, v1_active.id)
      assert after_row.status == :active
      assert after_row.updated_at == before_row.updated_at
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5: "a caller lacking the platform.admin-equivalent permission is
  # rejected before any row is read or locked"
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- AC5: permission guard runs before any row is read or locked" do
    test "permission_checker returning false -> forbidden, proven to run before any process_definitions read" do
      schema_name = unprovisioned_schema_name()
      process_key = unique_process_key()

      # No CREATE SCHEMA ever ran for this schema_name -- if the permission
      # guard did not run BEFORE any Repo call, the very next step (locking
      # process_definitions rows under this nonexistent schema) would raise
      # a Postgrex undefined-schema error instead of cleanly returning
      # {:error, :forbidden}. event_appender additionally explodes if ever
      # invoked, proving the guard also short-circuits before Step 3.
      assert {:error, :forbidden} =
               Definitions.rollback_definition_version(process_key, "1.0.0", Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: deny(),
                 event_appender: exploding_event_appender()
               )
    end

    test "omitting opts[:permission_checker] raises KeyError -- no silent allow-everything default" do
      assert_raise KeyError, fn ->
        Definitions.rollback_definition_version(
          unique_process_key(),
          "1.0.0",
          Ecto.UUID.generate(),
          prefix: "does-not-matter",
          event_appender: exploding_event_appender()
        )
      end
    end

    test "omitting opts[:event_appender] raises KeyError -- no silent no-op default" do
      assert_raise KeyError, fn ->
        Definitions.rollback_definition_version(
          unique_process_key(),
          "1.0.0",
          Ecto.UUID.generate(),
          prefix: "does-not-matter",
          permission_checker: allow()
        )
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 (part 1) + the cardinality-branched promotion_reviews lookup
  # (design §6/§7, INV-RB-10) -- the single most scrutinized part of this
  # requirement (triggered CODE-DESIGN-VALIDATOR's only rework cycle on this
  # run). Named, explicit coverage of all three cardinality branches.
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- AC4 + cardinality-branched promotion_reviews lookup (INV-RB-10)" do
    test "zero matching promotion_reviews rows -> superseded_review_id: nil, not an error" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1} = two_version_history!(schema_name, process_key)

      # A review exists for a COMPLETELY DIFFERENT process_key -- proves the
      # lookup is genuinely scoped to this process_key, not "any row happens
      # to exist in this tenant."
      _unrelated = review_applied!(schema_name, tenant_id, unique_process_key())

      assert {:ok, result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(self())
               )

      assert result.superseded_review_id == nil
    end

    test "exactly one APPLIED promotion_reviews row for the process_key is superseded, superseded_by == the rollback's event_id" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1} = two_version_history!(schema_name, process_key)

      applied = review_applied!(schema_name, tenant_id, process_key)
      assert applied.status == :applied

      assert {:ok, result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(self())
               )

      assert result.superseded_review_id == applied.id

      reread_review = Repo.get!(PromotionReview, applied.id, prefix: schema_name)
      assert reread_review.status == :superseded
      assert reread_review.superseded_by == result.event_id
      assert reread_review.row_version == applied.row_version + 1
    end

    test "exactly one APPROVED promotion_reviews row -- the 7->8 edge REQ-038 widened on supersede_review/3 -- is superseded the same way" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1} = two_version_history!(schema_name, process_key)

      approved = review_approved!(schema_name, tenant_id, process_key)
      assert approved.status == :approved

      assert {:ok, result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(self())
               )

      assert result.superseded_review_id == approved.id

      reread_review = Repo.get!(PromotionReview, approved.id, prefix: schema_name)
      assert reread_review.status == :superseded
      assert reread_review.superseded_by == result.event_id
      assert reread_review.row_version == approved.row_version + 1
    end

    test "MORE THAN ONE matching row -> superseded_review_id: nil, ZERO rows mutated (not first, not most recent -- none)" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1} = two_version_history!(schema_name, process_key)

      applied = review_applied!(schema_name, tenant_id, process_key)
      approved = review_approved!(schema_name, tenant_id, process_key)

      assert {:ok, result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(self())
               )

      assert result.superseded_review_id == nil

      reread_applied = Repo.get!(PromotionReview, applied.id, prefix: schema_name)
      reread_approved = Repo.get!(PromotionReview, approved.id, prefix: schema_name)

      assert reread_applied.status == :applied
      assert reread_applied.row_version == applied.row_version
      assert reread_applied.superseded_by == nil

      assert reread_approved.status == :approved
      assert reread_approved.row_version == approved.row_version
      assert reread_approved.superseded_by == nil
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 (part 2): the event-append-after-commit window (design §4.2/§5 step 3,
  # §8 OQ-3, INV-RB-7) -- SECURITY-REVIEWER/REVIEWER both flagged this as
  # more security-sensitive for rollback than for promotion. This test proves
  # the pointer swap is genuinely already committed and queryable via a
  # SEPARATE process/connection before event_appender is even invoked --
  # demonstrating the ordering is real, not merely asserted.
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- event-append-after-commit: swap is committed before event_appender runs" do
    test "a fresh read from a separate connection, taken inside event_appender, already observes the swap" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1, v2: v2} = two_version_history!(schema_name, process_key)
      test_pid = self()

      verifying_event_appender = fn _event_attrs, prefix ->
        # A genuinely separate BEAM process/connection re-reads both rows --
        # see reread_statuses_via_separate_connection/3's own comment.
        {target_status, former_active_status} =
          reread_statuses_via_separate_connection(prefix, v1.id, v2.id)

        send(test_pid, {:statuses_at_append_time, target_status, former_active_status})
        {:ok, %{event_id: Ecto.UUID.generate()}}
      end

      assert {:ok, _result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: verifying_event_appender
               )

      assert_received {:statuses_at_append_time, :active, :deprecated}
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:event_appender] returning {:error, _} propagates unchanged, after
  # the pointer swap has already committed (design §4.2/§8 OQ-3, INV-RB-7) --
  # the same disclosed tradeoff already accepted for promote_definition/3
  # (promotion_test.exs's own equivalent test), pinned here so it doesn't
  # silently change shape.
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- event_appender {:error, _} propagates after the swap already committed" do
    test "an event_appender error propagates as this function's own result; the swap is NOT rolled back" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1, v2: v2} = two_version_history!(schema_name, process_key)

      failing_event_appender = fn _event_attrs, _prefix -> {:error, :event_store_unavailable} end

      assert {:error, :event_store_unavailable} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: failing_event_appender
               )

      assert reread!(schema_name, v1.id).status == :active
      assert reread!(schema_name, v2.id).status == :deprecated
    end
  end

  # ---------------------------------------------------------------------------------
  # Status-enum reuse correctness: a row that became :deprecated via THIS
  # module's own swap (not the original activate/2 promotion path) must still
  # be recognized as "was previously ACTIVE" by a SUBSEQUENT rollback's own
  # guard logic -- can you roll back twice in a row, alternating between two
  # versions?
  # ---------------------------------------------------------------------------------

  describe "rollback_definition_version/4 -- status-enum reuse correctness: a row deprecated via rollback's own swap is still eligible for a subsequent rollback" do
    test "rolling back twice in a row, alternating between two versions, both succeed" do
      %{schema_name: schema_name} = provisioned_tenant()
      process_key = unique_process_key()
      %{v1: v1, v2: v2} = two_version_history!(schema_name, process_key)

      assert {:ok, first_result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v1.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(self())
               )

      assert first_result.definition_id == v1.id
      assert reread!(schema_name, v1.id).status == :active
      assert reread!(schema_name, v2.id).status == :deprecated
      assert_received {:event_appended, _event_attrs, _prefix}

      # v2 is now :deprecated -- via THIS module's own swap, not the
      # original activate/2 promotion path. It must still be recognized as
      # "was previously ACTIVE" and be a legal rollback target.
      assert {:ok, second_result} =
               Definitions.rollback_definition_version(
                 process_key,
                 v2.version,
                 Ecto.UUID.generate(),
                 prefix: schema_name,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(self())
               )

      assert second_result.definition_id == v2.id
      assert second_result.rolled_back_from_version == v1.version
      assert reread!(schema_name, v2.id).status == :active
      assert reread!(schema_name, v1.id).status == :deprecated
      assert_received {:event_appended, _event_attrs, _prefix}
    end
  end
end
