defmodule Letflow.Definitions.PromotionReviewStoreTest do
  @moduledoc """
  Tests for `Letflow.Definitions.PromotionReviewStore` (REQ-037, PRM-04). See
  `test/specs/REQ-037.md` for the full test-case rationale and
  `lib/letflow/design/promotion_review_state_machine.md` §2/§4 for the
  gate-approved design this file exercises (§4 in particular spells out the
  exact AC4 concurrency-test recipe reused verbatim below).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

  ## Fixture strategy -- mirrors REQ-036's precedent
  (`promotion_plan_test.exs`/`promotion_conflict_test.exs`)

  Every transition function in this module writes to `promotion_reviews`, a
  table with no `@schema_prefix` (schema-per-tenant); `promotion_reviews`
  carries no `tenant_id` column at all (Decision 0006 D2 / REQ-064 -- the
  per-tenant schema alone identifies the tenant), so each test only needs to
  provision ONE real tenant schema (`provisioned_tenant/0`) -- unlike `promotion_plan_test.exs`,
  which needs two (source + target). Real `CREATE SCHEMA` +
  `TenantProvisioning.replay_migrations/1`, Sandbox `:auto` mode + manual
  `on_exit/1` cleanup (an `Ecto.Migrator` run needs a second real DB
  connection the ordinary sandboxed connection can't hand out), `async: false`
  for the whole module -- same reasoning as `promotion_plan_test.exs`'s own
  moduledoc.

  ## `insert_review/2`'s `digest` argument must always be a real 64-lowercase-hex
  digest actually derived from `plan.entries`

  `insert_review/2` re-verifies `digest` against `plan` before writing (design
  §2.3 step 1) and `PromotionReview.insert_changeset/2` separately format-
  validates `plan_digest` as exactly 64 lowercase hex characters -- every
  fixture below computes a real digest via `PromotionDigest.compute_plan_digest/1`
  rather than a hand-rolled string, so a passing insert in one test can never be
  an artifact of a malformed-but-accepted digest.

  ## `approve_review/4`'s digest-mismatch tests use a full-length (64-char) wrong
  digest, never a short placeholder

  `PromotionDigest.verify_digest/2`'s binary-vs-binary clause calls
  `:crypto.hash_equals/2` directly, which **raises** `ArgumentError` on two
  differently-sized binaries rather than returning `false` (confirmed against
  real OTP behaviour during REQ-036's own test design, see
  `test/specs/REQ-036.md` case 29). Every "wrong digest" fixture below is
  itself a real 64-char digest (of different content), never a short literal
  like `"wrong"`, so the mismatch path is genuinely exercised rather than
  accidentally raising.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366).
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req037-review",
      display_name: "REQ-037 PromotionReviewStore Test Tenant"
    )
  end

  defp unique_process_key(prefix \\ "req037-proc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # A structurally-real PromotionPlan.t()-shaped map. `target_tenant_id`
  # defaults to the tenant this row is meant to belong to, but every field is
  # overridable so the "prefix wins over plan" test can deliberately disagree.
  defp sample_plan(tenant_id, overrides \\ %{}) do
    %{
      source_tenant_id: Ecto.UUID.generate(),
      target_tenant_id: tenant_id,
      process_key: unique_process_key(),
      source_definition_id: Ecto.UUID.generate(),
      target_definition_id: nil,
      base_version: nil,
      entries: [
        %{
          type: :graph_node,
          id: "n1",
          change_kind: :added,
          before: nil,
          after: %{"id" => "n1", "node_type" => "START"}
        }
      ]
    }
    |> Map.merge(overrides)
  end

  # A real 64-lowercase-hex digest actually derived from `plan`, per this
  # file's moduledoc.
  defp digest_for(plan), do: PromotionDigest.compute_plan_digest(plan)

  # A plan whose `entries` are deliberately DIFFERENT from `sample_plan/2`'s own
  # default -- `compute_plan_digest/1` hashes only `plan.entries` (design/
  # PromotionDigest §0), so two `sample_plan/2` calls with the same (unvaried)
  # default entries would produce the IDENTICAL digest even for otherwise-unrelated
  # plans. Every "wrong digest" fixture in this file must be a digest of a plan
  # whose entries genuinely differ, or the mismatch path would never actually be
  # exercised.
  defp differing_plan(tenant_id) do
    sample_plan(tenant_id, %{
      entries: [
        %{
          type: :graph_node,
          id: "different-entry-#{System.unique_integer([:positive, :monotonic])}",
          change_kind: :removed,
          before: %{"id" => "gone"},
          after: nil
        }
      ]
    })
  end

  # Inserts one :pending_review row via the real insert_review/2 call (never a
  # direct Repo.insert! -- that would bypass the function under test).
  defp insert_review_fixture!(schema_name, tenant_id, opts \\ []) do
    plan = sample_plan(tenant_id, Keyword.get(opts, :plan_overrides, %{}))
    digest = digest_for(plan)
    requested_by = Keyword.get(opts, :requested_by, Ecto.UUID.generate())

    assert {:ok, review} =
             PromotionReviewStore.insert_review(
               %{plan: plan, digest: digest, requested_by: requested_by},
               prefix: schema_name
             )

    %{review: review, plan: plan, digest: digest, requested_by: requested_by}
  end

  # pending_review -> approved, via the real approve_review/4 (edge 1).
  defp approved_review!(schema_name, tenant_id) do
    %{review: review, digest: digest} = insert_review_fixture!(schema_name, tenant_id)
    actor_id = Ecto.UUID.generate()

    assert {:ok, approved} =
             PromotionReviewStore.approve_review(review.id, actor_id, digest, prefix: schema_name)

    approved
  end

  # pending_review -> rejected, via the real reject_review/3 (edge 2).
  defp rejected_review!(schema_name, tenant_id) do
    %{review: review} = insert_review_fixture!(schema_name, tenant_id)
    actor_id = Ecto.UUID.generate()

    assert {:ok, rejected} =
             PromotionReviewStore.reject_review(review.id, actor_id, prefix: schema_name)

    rejected
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "insert_review/1 followed by a second insert_review/1
  # with the identical plan_digest while the first is still
  # pending_review returns the duplicate-review error, not a second row"
  # ---------------------------------------------------------------------------------

  describe "insert_review/2 -- acceptance criterion 1 (duplicate review)" do
    test "a second insert_review/2 with the identical plan_digest while the first is pending_review -> :duplicate_review, not a second row" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      plan = sample_plan(tenant_id)
      digest = digest_for(plan)
      requested_by_1 = Ecto.UUID.generate()
      requested_by_2 = Ecto.UUID.generate()

      assert {:ok, first} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: digest, requested_by: requested_by_1},
                 prefix: schema_name
               )

      # A second call, even with a DIFFERENT requested_by, must still collide --
      # the unique index is on (plan_digest) alone, per Decision 0006 D2
      # (REQ-064 dropped promotion_reviews.tenant_id).
      assert {:error, :duplicate_review} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: digest, requested_by: requested_by_2},
                 prefix: schema_name
               )

      rows =
        Repo.all(
          from(p in PromotionReview,
            where: p.plan_digest == ^digest
          ),
          prefix: schema_name
        )

      assert length(rows) == 1
      assert hd(rows).id == first.id
      assert hd(rows).requested_by == requested_by_1
    end

    test "a duplicate plan_digest is accepted again once the first row is no longer pending_review/approved (rejected)" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      plan = sample_plan(tenant_id)
      digest = digest_for(plan)

      assert {:ok, first} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
                 prefix: schema_name
               )

      assert {:ok, _rejected} =
               PromotionReviewStore.reject_review(first.id, Ecto.UUID.generate(),
                 prefix: schema_name
               )

      # The partial unique index only covers status IN ('pending_review',
      # 'approved') -- once the first row is rejected, an identical
      # plan_digest is no longer a duplicate.
      assert {:ok, second} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
                 prefix: schema_name
               )

      refute second.id == first.id
    end
  end

  # ---------------------------------------------------------------------------------
  # insert_review/2's prefix-validity guard (design §2.3, post-REQ-064 note in
  # promotion_review_store.ex's own moduledoc): `promotion_reviews.tenant_id` no
  # longer exists (Decision 0006 D2) -- the per-tenant Postgres schema alone
  # identifies the tenant, so insert_review/2 no longer derives or stamps any
  # tenant_id value. `opts[:prefix]` is still resolved via
  # TenantProvisioning.tenant_id_for_schema_name/1 purely as an early
  # prefix-validity guard before Repo.insert/2.
  # ---------------------------------------------------------------------------------

  describe "insert_review/2 -- prefix validity still checked, no tenant_id stamped" do
    test "disagreeing target_tenant_id doesn't affect row placement, only echoed in serialised_plan" do
      %{tenant_id: real_tenant_id, schema_name: schema_name} = provisioned_tenant()

      # Deliberately a DIFFERENT, unrelated tenant_id -- never provisioned, never
      # related to schema_name at all. insert_review/2 never reads this value for
      # anything beyond echoing it back inside the serialised plan.
      disagreeing_target_tenant_id = Ecto.UUID.generate()
      refute disagreeing_target_tenant_id == real_tenant_id

      plan = sample_plan(real_tenant_id, %{target_tenant_id: disagreeing_target_tenant_id})
      digest = digest_for(plan)

      assert {:ok, review} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
                 prefix: schema_name
               )

      # The row landed in the prefix's own schema -- the only place "which tenant"
      # is recorded now that promotion_reviews carries no tenant_id column.
      assert Repo.get!(PromotionReview, review.id, prefix: schema_name).id == review.id

      # The plan's own (disagreeing) copy of target_tenant_id is still stored
      # verbatim inside serialised_plan (design §2.3 step 4 -- it stays part of
      # the JSON envelope), so this assertion also proves the disagreement was a
      # genuine one, not an accidental match.
      persisted = Repo.get!(PromotionReview, review.id, prefix: schema_name)

      assert Jason.decode!(persisted.serialised_plan)["target_tenant_id"] ==
               disagreeing_target_tenant_id
    end

    test "opts[:prefix] pointing at a schema name with no valid reverse tenant_id -> {:error, :invalid_schema_name}, no row written" do
      plan = sample_plan(Ecto.UUID.generate())
      digest = digest_for(plan)

      assert {:error, :invalid_schema_name} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
                 prefix: "not_a_real_tenant_schema_name"
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # insert_review/2's own digest re-verification (design §2.3 step 1) -- distinct
  # from AC3's approve_review/4 digest-mismatch gate, but the same INV-PRM04-3
  # constant-time-comparison contract applies here too.
  # ---------------------------------------------------------------------------------

  describe "insert_review/2 -- digest re-verification" do
    test "a digest that does not match plan.entries -> {:error, :digest_mismatch}, no row written" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      plan = sample_plan(tenant_id)
      wrong_digest = digest_for(differing_plan(tenant_id))
      refute wrong_digest == digest_for(plan)

      assert {:error, :digest_mismatch} =
               PromotionReviewStore.insert_review(
                 %{plan: plan, digest: wrong_digest, requested_by: Ecto.UUID.generate()},
                 prefix: schema_name
               )

      assert Repo.aggregate(PromotionReview, :count, prefix: schema_name) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "approve_review/4 called by the same principal recorded
  # as requested_by is rejected with a self-approval error before any row is
  # updated"
  # ---------------------------------------------------------------------------------

  describe "approve_review/4 -- acceptance criterion 2 (self-approval, before any row update)" do
    test "actor_id == requested_by -> {:error, :self_approval_forbidden}, and the row is provably unchanged afterwards" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      requested_by = Ecto.UUID.generate()

      %{review: review, digest: digest} =
        insert_review_fixture!(schema_name, tenant_id, requested_by: requested_by)

      assert {:error, :self_approval_forbidden} =
               PromotionReviewStore.approve_review(review.id, requested_by, digest,
                 prefix: schema_name
               )

      # Re-read from Postgres -- proves the guarded UPDATE was never even
      # attempted, not just that the in-memory reply looked right.
      reloaded = Repo.get!(PromotionReview, review.id, prefix: schema_name)
      assert reloaded.status == :pending_review
      assert reloaded.row_version == review.row_version
      assert reloaded.approved_by == nil
      assert reloaded.approved_at == nil
    end

    test "self-approval is rejected even when the supplied plan_digest is ALSO wrong -- self-approval gate runs first, digest gate never reached" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      requested_by = Ecto.UUID.generate()

      %{review: review, plan: plan} =
        insert_review_fixture!(schema_name, tenant_id, requested_by: requested_by)

      wrong_digest = digest_for(differing_plan(tenant_id))
      refute wrong_digest == digest_for(plan)

      assert {:error, :self_approval_forbidden} =
               PromotionReviewStore.approve_review(review.id, requested_by, wrong_digest,
                 prefix: schema_name
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "approve_review/4 with a plan_digest not matching the
  # stored value is rejected with a digest-mismatch error, distinct from the
  # self-approval and invalid-transition errors"
  # ---------------------------------------------------------------------------------

  describe "approve_review/4 -- acceptance criterion 3 (digest mismatch, distinct atom)" do
    test "a plan_digest not matching the stored value -> {:error, :digest_mismatch}, a different actor than requested_by" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      %{review: review, requested_by: requested_by} =
        insert_review_fixture!(schema_name, tenant_id)

      actor_id = Ecto.UUID.generate()
      refute actor_id == requested_by

      wrong_digest = digest_for(differing_plan(tenant_id))
      refute wrong_digest == review.plan_digest

      result =
        PromotionReviewStore.approve_review(review.id, actor_id, wrong_digest,
          prefix: schema_name
        )

      assert result == {:error, :digest_mismatch}
      # Explicit, side-by-side distinctness -- per AC3's own "distinct from the
      # self-approval and invalid-transition errors" wording.
      assert elem(result, 1) != :self_approval_forbidden
      assert elem(result, 1) != :invalid_transition

      reloaded = Repo.get!(PromotionReview, review.id, prefix: schema_name)
      assert reloaded.status == :pending_review
      assert reloaded.row_version == review.row_version
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "two concurrent approve_review/4 calls on the same
  # review_id: exactly one succeeds (row_version optimistic-lock check), the other
  # gets the invalid-transition error from the zero-rows-affected WHERE
  # row_version = $expected clause"
  #
  # Recipe reused verbatim from lib/letflow/design/promotion_review_state_machine.md
  # §4, which itself reuses test/letflow/event_store_test.exs's own established
  # Task.async + {:ready, pid}/:go barrier idiom (see that file's "concurrent
  # appends (AC2)" describe block) -- not a new mechanism invented here.
  # ---------------------------------------------------------------------------------

  describe "approve_review/4 -- acceptance criterion 4 (concurrency, Task.async barrier)" do
    test "two concurrent approve_review/4 calls on the same review_id: exactly one :ok, exactly one {:error, :invalid_transition}" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      %{review: review, digest: digest} = insert_review_fixture!(schema_name, tenant_id)

      assert review.status == :pending_review
      assert review.row_version == 1

      actor_id = Ecto.UUID.generate()
      parent = self()

      run = fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        after
          5000 -> flunk("barrier release never arrived")
        end

        PromotionReviewStore.approve_review(review.id, actor_id, digest, prefix: schema_name)
      end

      # Sandbox mode is :auto here (via provisioned_tenant/0) -- every process,
      # including these spawned Tasks, gets its own real, independent Postgres
      # connection, matching event_store_test.exs's identical concurrent-race
      # precedent.
      task1 = Task.async(run)
      task2 = Task.async(run)

      assert_receive {:ready, pid1}, 5000
      assert_receive {:ready, pid2}, 5000
      assert pid1 != pid2

      send(pid1, :go)
      send(pid2, :go)

      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)
      results = [result1, result2]

      assert Enum.count(results, &match?({:ok, %PromotionReview{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_transition})) == 1

      # Fresh read, outside either task -- exactly one row_version increment,
      # proving the loser's UPDATE truly affected zero rows rather than
      # succeeding and being silently overwritten.
      reloaded = Repo.get!(PromotionReview, review.id, prefix: schema_name)
      assert reloaded.status == :approved
      assert reloaded.row_version == 2
      assert reloaded.approved_by == actor_id
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 6 (part 1): all 7 permitted edges (design §2.1 table), one
  # explicit passing test each. Edge 7 (rejected -> superseded) simultaneously
  # satisfies acceptance criterion 5 -- explicitly labeled below, not left
  # implicit.
  # ---------------------------------------------------------------------------------

  describe "state machine -- acceptance criterion 6 (all 7 permitted edges)" do
    test "edge 1/7: pending_review -> approved, via approve_review/4" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      %{review: review, digest: digest} = insert_review_fixture!(schema_name, tenant_id)
      actor_id = Ecto.UUID.generate()

      assert {:ok, approved} =
               PromotionReviewStore.approve_review(review.id, actor_id, digest,
                 prefix: schema_name
               )

      assert approved.status == :approved
      assert approved.approved_by == actor_id
      assert approved.row_version == review.row_version + 1
    end

    test "edge 2/7: pending_review -> rejected, via reject_review/3" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      %{review: review} = insert_review_fixture!(schema_name, tenant_id)
      actor_id = Ecto.UUID.generate()

      assert {:ok, rejected} =
               PromotionReviewStore.reject_review(review.id, actor_id, prefix: schema_name)

      assert rejected.status == :rejected
      assert rejected.row_version == review.row_version + 1
    end

    test "edge 3/7: approved -> applied, via mark_review_applied/2" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      approved = approved_review!(schema_name, tenant_id)

      assert {:ok, applied} =
               PromotionReviewStore.mark_review_applied(approved.id, prefix: schema_name)

      assert applied.status == :applied
      assert applied.row_version == approved.row_version + 1
    end

    test "edge 4/7: approved -> failed, via mark_review_failed/2" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      approved = approved_review!(schema_name, tenant_id)

      assert {:ok, failed} =
               PromotionReviewStore.mark_review_failed(approved.id, prefix: schema_name)

      assert failed.status == :failed
      assert failed.row_version == approved.row_version + 1
    end

    test "edge 5/7: applied -> superseded, via supersede_review/3" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      approved = approved_review!(schema_name, tenant_id)

      assert {:ok, applied} =
               PromotionReviewStore.mark_review_applied(approved.id, prefix: schema_name)

      superseded_by_event_id = Ecto.UUID.generate()

      assert {:ok, superseded} =
               PromotionReviewStore.supersede_review(applied.id, superseded_by_event_id,
                 prefix: schema_name
               )

      assert superseded.status == :superseded
      assert superseded.superseded_by == superseded_by_event_id
      assert superseded.row_version == applied.row_version + 1
    end

    test "edge 6/7: failed -> superseded, via supersede_review/3" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      approved = approved_review!(schema_name, tenant_id)

      assert {:ok, failed} =
               PromotionReviewStore.mark_review_failed(approved.id, prefix: schema_name)

      superseded_by_event_id = Ecto.UUID.generate()

      assert {:ok, superseded} =
               PromotionReviewStore.supersede_review(failed.id, superseded_by_event_id,
                 prefix: schema_name
               )

      assert superseded.status == :superseded
      assert superseded.superseded_by == superseded_by_event_id
      assert superseded.row_version == failed.row_version + 1
    end

    # ---------------------------------------------------------------------------
    # Acceptance criterion 5: "a rejected review can be transitioned to superseded
    # via supersede_review/2 (-> /3, arity resolution §1.2), the NEW edge prm-04
    # adds, demonstrated explicitly, not left untested as if rejected were
    # terminal."
    #
    # This IS edge 7/7 in the design's own table (§2.1) -- rejected is
    # deliberately not a special case, it is a full member of
    # supersede_review/3's allowed_source_statuses, same shape as edges 5/6
    # above. Labeled with both AC numbers so neither acceptance criterion reads
    # as silently dropped.
    # ---------------------------------------------------------------------------
    test "edge 7/7 (acceptance criterion 5, the NEW edge): rejected -> superseded, via supersede_review/3 -- rejected is NOT terminal" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      rejected = rejected_review!(schema_name, tenant_id)
      assert rejected.status == :rejected

      superseded_by_event_id = Ecto.UUID.generate()

      assert {:ok, superseded} =
               PromotionReviewStore.supersede_review(rejected.id, superseded_by_event_id,
                 prefix: schema_name
               )

      assert superseded.status == :superseded
      assert superseded.superseded_by == superseded_by_event_id
      assert superseded.row_version == rejected.row_version + 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 6 (part 2): at least 2 non-edges, both returning the
  # IDENTICAL :invalid_transition atom regardless of which illegal edge was
  # attempted (INV-PRM04-1) -- demonstrated explicitly via a direct equality check
  # across both results, not just two separate assertions that happen to look
  # alike.
  # ---------------------------------------------------------------------------------

  describe "state machine -- acceptance criterion 6 (non-edges, identical :invalid_transition atom)" do
    test "rejected -> approved (illegal) and pending_review -> applied (illegal) both return exactly {:error, :invalid_transition}" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      # Non-edge 1: rejected -> approved. Uses a DIFFERENT actor than
      # requested_by so this genuinely exercises the status pre-check, not the
      # self-approval gate (which runs first and would otherwise mask this).
      rejected = rejected_review!(schema_name, tenant_id)
      illegal_digest = digest_for(sample_plan(tenant_id))
      actor_for_rejected = Ecto.UUID.generate()

      result_a =
        PromotionReviewStore.approve_review(rejected.id, actor_for_rejected, illegal_digest,
          prefix: schema_name
        )

      # Non-edge 2: pending_review -> applied (skips straight past approval).
      %{review: pending} = insert_review_fixture!(schema_name, tenant_id)
      result_b = PromotionReviewStore.mark_review_applied(pending.id, prefix: schema_name)

      assert result_a == {:error, :invalid_transition}
      assert result_b == {:error, :invalid_transition}

      # The explicit "identical atom regardless of which illegal edge" claim:
      # both results collapse to the SAME single term when de-duplicated.
      assert Enum.uniq([result_a, result_b]) == [{:error, :invalid_transition}]
    end

    test "superseded is a true terminal state: supersede_review/3 on an already-superseded row -> {:error, :invalid_transition} too" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      rejected = rejected_review!(schema_name, tenant_id)

      assert {:ok, superseded} =
               PromotionReviewStore.supersede_review(rejected.id, Ecto.UUID.generate(),
                 prefix: schema_name
               )

      result =
        PromotionReviewStore.supersede_review(superseded.id, Ecto.UUID.generate(),
          prefix: schema_name
        )

      assert result == {:error, :invalid_transition}
    end
  end

  # ---------------------------------------------------------------------------------
  # Beyond the bare acceptance criteria -- cheap, real coverage of the generic
  # transition mechanism's :review_not_found path, shared by all six transition
  # functions.
  # ---------------------------------------------------------------------------------

  describe "transition/6 (generic mechanism) -- :review_not_found" do
    test "every transition function returns {:error, :review_not_found} for an id that does not exist in this tenant's schema" do
      %{schema_name: schema_name} = provisioned_tenant()
      missing_id = Ecto.UUID.generate()

      assert PromotionReviewStore.approve_review(missing_id, Ecto.UUID.generate(), "x",
               prefix: schema_name
             ) ==
               {:error, :review_not_found}

      assert PromotionReviewStore.reject_review(missing_id, Ecto.UUID.generate(),
               prefix: schema_name
             ) ==
               {:error, :review_not_found}

      assert PromotionReviewStore.mark_review_applied(missing_id, prefix: schema_name) ==
               {:error, :review_not_found}

      assert PromotionReviewStore.mark_review_failed(missing_id, prefix: schema_name) ==
               {:error, :review_not_found}

      assert PromotionReviewStore.supersede_review(missing_id, Ecto.UUID.generate(),
               prefix: schema_name
             ) ==
               {:error, :review_not_found}
    end
  end

  # ---------------------------------------------------------------------------------
  # list_reviews/2 (REQ-397, design req397-promotion-review-list-route.md §3/§7)
  # -- context-level keyset/ordering edge case that doesn't need real-HTTP
  # dispatch. Router-level coverage (authz, tenant isolation, status/def_id
  # filters, invalid-status 400, pagination cursor round-trip) lives in
  # test/letflow/routers/promotions_test.exs's own "GET /promotions" describe
  # block per the design's own test-plan split.
  # ---------------------------------------------------------------------------------

  describe "list_reviews/2 -- keyset/ordering edge cases" do
    test "two rows with the same inserted_at second are still returned with no skip/duplicate across two consecutive page fetches, id DESC tiebreak" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      # Each fixture needs a distinct plan_digest (the partial unique index
      # rejects a second :pending_review row with an identical digest, per
      # this file's own moduledoc) -- vary entries per call, same technique
      # differing_plan/1 above uses.
      distinct_entries = fn ->
        [
          %{
            type: :graph_node,
            id: "n1-#{System.unique_integer([:positive, :monotonic])}",
            change_kind: :added,
            before: nil,
            after: %{"id" => "n1", "node_type" => "START"}
          }
        ]
      end

      %{review: review1} =
        insert_review_fixture!(schema_name, tenant_id,
          plan_overrides: %{entries: distinct_entries.()}
        )

      %{review: review2} =
        insert_review_fixture!(schema_name, tenant_id,
          plan_overrides: %{entries: distinct_entries.()}
        )

      %{review: review3} =
        insert_review_fixture!(schema_name, tenant_id,
          plan_overrides: %{entries: distinct_entries.()}
        )

      all_ids = [review1.id, review2.id, review3.id]

      assert {:ok, %{items: page1, next_cursor: cursor1}} =
               PromotionReviewStore.list_reviews(%{page_size: 2}, prefix: schema_name)

      assert length(page1) == 2
      assert is_binary(cursor1)

      assert {:ok, %{items: page2, next_cursor: cursor2}} =
               PromotionReviewStore.list_reviews(%{page_size: 2, cursor: cursor1},
                 prefix: schema_name
               )

      assert length(page2) == 1
      assert cursor2 == nil

      page1_ids = Enum.map(page1, & &1.id)
      page2_ids = Enum.map(page2, & &1.id)

      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
      assert Enum.sort(page1_ids ++ page2_ids) == Enum.sort(all_ids)
    end

    test "unrecognised prefix -> {:error, :invalid_schema_name}, no query executed" do
      assert {:error, :invalid_schema_name} =
               PromotionReviewStore.list_reviews(%{page_size: 50},
                 prefix: "not_a_real_tenant_schema_name"
               )
    end
  end

  # ISS-1029: the `:row_visible?` predicate, applied inside the keyset scan.
  describe "list_reviews/2 -- :row_visible? (ISS-1029)" do
    defp seed_rows!(schema_name, tenant_id, n) do
      for _ <- 1..n do
        entries = [
          %{
            type: :graph_node,
            id: "n1-#{System.unique_integer([:positive, :monotonic])}",
            change_kind: :added,
            before: nil,
            after: %{"id" => "n1", "node_type" => "START"}
          }
        ]

        %{review: review} =
          insert_review_fixture!(schema_name, tenant_id, plan_overrides: %{entries: entries})

        review
      end
    end

    # Every review id of the schema in list order (newest first), unfiltered.
    defp all_ids(schema_name, n) do
      {:ok, %{items: items}} =
        PromotionReviewStore.list_reviews(%{page_size: n + 10}, prefix: schema_name)

      Enum.map(items, & &1.id)
    end

    defp walk_store(schema_name, page_size, pred) do
      do_walk_store(schema_name, page_size, pred, nil, [])
    end

    defp do_walk_store(_schema, _ps, _pred, _cursor, acc) when length(acc) > 50,
      do: flunk("paging did not terminate")

    defp do_walk_store(schema_name, page_size, pred, cursor, acc) do
      filters = %{page_size: page_size, cursor: cursor}

      assert {:ok, %{items: items, next_cursor: next}} =
               PromotionReviewStore.list_reviews(filters,
                 prefix: schema_name,
                 row_visible?: pred
               )

      acc = acc ++ [{Enum.map(items, & &1.id), next}]
      if next, do: do_walk_store(schema_name, page_size, pred, next, acc), else: acc
    end

    test "nil and an absent option behave identically (no filtering)" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      seed_rows!(schema_name, tenant_id, 3)

      assert {:ok, %{items: absent, next_cursor: c1}} =
               PromotionReviewStore.list_reviews(%{page_size: 2}, prefix: schema_name)

      assert {:ok, %{items: with_nil, next_cursor: c2}} =
               PromotionReviewStore.list_reviews(%{page_size: 2},
                 prefix: schema_name,
                 row_visible?: nil
               )

      assert Enum.map(absent, & &1.id) == Enum.map(with_nil, & &1.id)
      assert is_binary(c1) and is_binary(c2)
    end

    test "all rows hidden -> empty page, nil cursor" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      seed_rows!(schema_name, tenant_id, 3)

      assert {:ok, %{items: [], next_cursor: nil}} =
               PromotionReviewStore.list_reviews(%{page_size: 1},
                 prefix: schema_name,
                 row_visible?: fn _ -> false end
               )
    end

    test "boundary pages hold only visible rows, each once, final cursor nil" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      seed_rows!(schema_name, tenant_id, 6)
      [_r1, r2, r3, _r4, _r5, r6] = all_ids(schema_name, 6)
      visible = MapSet.new([r2, r3, r6])
      pred = fn row -> MapSet.member?(visible, row.id) end

      for page_size <- [1, 2] do
        pages = walk_store(schema_name, page_size, pred)
        assert Enum.flat_map(pages, &elem(&1, 0)) == [r2, r3, r6]
        assert pages |> List.last() |> elem(1) == nil
      end
    end

    test "a hidden run longer than two scan chunks never strands the visible row" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      seed_rows!(schema_name, tenant_id, 251)
      ids = all_ids(schema_name, 251)
      oldest = List.last(ids)

      assert {:ok, %{items: [row], next_cursor: nil}} =
               PromotionReviewStore.list_reviews(%{page_size: 1},
                 prefix: schema_name,
                 row_visible?: fn r -> r.id == oldest end
               )

      assert row.id == oldest
    end

    test "a cursor from a filtered call encodes only the last emitted row" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      seed_rows!(schema_name, tenant_id, 3)
      [v1, hidden, v2] = all_ids(schema_name, 3)
      pred = fn row -> row.id != hidden end

      assert {:ok, %{items: [first], next_cursor: cursor}} =
               PromotionReviewStore.list_reviews(%{page_size: 1},
                 prefix: schema_name,
                 row_visible?: pred
               )

      assert first.id == v1
      {:ok, decoded} = Base.url_decode64(cursor, padding: false)
      assert decoded =~ v1
      refute decoded =~ hidden
      refute decoded =~ v2
    end

    test "a predicate that raises propagates (the router's predicate never raises)" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      seed_rows!(schema_name, tenant_id, 1)

      assert_raise RuntimeError, "boom", fn ->
        PromotionReviewStore.list_reviews(%{page_size: 1},
          prefix: schema_name,
          row_visible?: fn _ -> raise "boom" end
        )
      end
    end

    test "a value that is neither nil nor a 1-arity function raises ArgumentError" do
      %{schema_name: schema_name} = provisioned_tenant()

      for bad <- [:yes, true, fn _a, _b -> true end, "x"] do
        assert_raise ArgumentError, fn ->
          PromotionReviewStore.list_reviews(%{page_size: 1},
            prefix: schema_name,
            row_visible?: bad
          )
        end
      end
    end
  end
end
