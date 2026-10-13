defmodule Letflow.Routers.PromotionContextShapingTest do
  @moduledoc """
  REQ-446 T-8 (`lib/letflow/design/req446-named-scoped-permissions.md` sections 1c / 4b / 5):
  INV-10 response shaping on `GET /promotions/:id/context`. ISS-1021 replaced the REQ-446
  key-suffix walk with a top-level key ALLOWLIST: for a caller that is not a platform-tenant
  operator the decoded `serialised_plan` holds only `process_key`, `base_version`, own tenant
  ids, own-side definition ids and `entries` only when both plan tenant ids are the caller's
  own (ISS-1023), as stored and not descended; `[]` otherwise. An operator sees the plan
  unchanged. See `test/specs/REQ-446.md`, `test/specs/ISS-1021.md` and `test/specs/ISS-1023.md`.

  The reviews are inserted straight into the schema under test through the real
  `PromotionReviewStore.insert_review/2` (a "legacy" row: the submit handler no longer lets an
  ordinary tenant admin create one naming a foreign tenant). `async: false` (platform pin).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.PromotionScopeFixture, as: Scope

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # REQ-447 PR 2: the platform tenant's administrator is PLATFORM_ADMIN (the operator); an
  # ordinary tenant's is TENANT_ADMIN (its PLATFORM_ADMIN would hold nothing).
  defp admin_roles(fixture) do
    if Letflow.PlatformTenant.platform_tenant?(fixture.tenant_id),
      do: ["PLATFORM_ADMIN"],
      else: ["TENANT_ADMIN"]
  end

  defp get(fixture, path) do
    Letflow.Routers.Promotions.call(
      Fixture.router_conn(:get, path, fixture, admin_roles(fixture), nil),
      Letflow.Routers.Promotions.init([])
    )
  end

  defp context(fixture, review_id), do: get(fixture, "/#{review_id}/context")

  defp entry_with_tenant_ids(tenant_id) do
    %{
      type: :graph_node,
      id: "n1-#{System.unique_integer([:positive, :monotonic])}",
      change_kind: :added,
      after: %{"id" => "n1", "node_type" => "START", "tenant_id" => tenant_id},
      before: nil,
      tenant_id: tenant_id
    }
  end

  describe "non-operator callers" do
    test "context_omits_foreign_tenant_ids_for_non_operator", ctx do
      %{review: review, plan: plan} =
        Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id, %{
          base_version: "1.0.0",
          target_definition_id: Ecto.UUID.generate()
        })

      resp = context(ctx.a, review.id)
      assert resp.status == 200

      refute resp.resp_body =~ ctx.b.tenant_id

      body = Jason.decode!(resp.resp_body)
      shaped = body["serialised_plan"]

      assert shaped["target_tenant_id"] == ctx.a.tenant_id
      assert Map.has_key?(shaped, "source_tenant_id") == false

      # ISS-1021: the source side is B (foreign), so its definition id is omitted too
      assert Map.has_key?(shaped, "source_definition_id") == false
      # the target side is A (own): kept, as are the plain scalars
      assert shaped["target_definition_id"] == plan.target_definition_id
      assert shaped["process_key"] == plan.process_key
      assert shaped["base_version"] == "1.0.0"
      # ISS-1023: the source side is foreign, so the whole diff is withheld
      assert plan.entries != []
      assert shaped["entries"] == []
      assert body["requested_by"] == review.requested_by
    end

    test "context_unknown_top_level_keys_dropped_and_entries_not_descended", ctx do
      %{review: review} =
        Scope.seed_review!(ctx.a, ctx.a.tenant_id, ctx.a.tenant_id, %{
          meta: %{
            origin_tenant_id: ctx.b.tenant_id,
            rows: [[%{tenant_id: ctx.b.tenant_id}, %{tenant_id: ctx.a.tenant_id, k: 1}]],
            n: 3
          },
          entries: [entry_with_tenant_ids(ctx.b.tenant_id)]
        })

      body = ctx.a |> context(review.id) |> Map.fetch!(:resp_body) |> Jason.decode!()
      plan = body["serialised_plan"]

      # outside the allowlist: an unknown top-level key is omitted whole (ISS-1021)
      assert Map.has_key?(plan, "meta") == false

      # inside `entries` (both sides own: kept as stored; residual R1b, the caller's own
      # free-form content)
      [entry] = plan["entries"]
      assert entry["tenant_id"] == ctx.b.tenant_id
      assert entry["after"]["tenant_id"] == ctx.b.tenant_id

      # both ids at the top level of the plan are the caller's own and survive
      assert plan["source_tenant_id"] == ctx.a.tenant_id
      assert plan["target_tenant_id"] == ctx.a.tenant_id
    end

    test "context_other_keys_and_status_unchanged", ctx do
      %{review: review} = Scope.seed_review!(ctx.a, ctx.b.tenant_id, ctx.a.tenant_id)

      body = ctx.a |> context(review.id) |> Map.fetch!(:resp_body) |> Jason.decode!()

      assert body |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "review_id",
                 "plan_digest",
                 "serialised_plan",
                 "status",
                 "requested_by",
                 "def_type",
                 "def_id",
                 "created_at",
                 "row_version"
               ])

      assert body["review_id"] == review.id
      assert body["plan_digest"] == review.plan_digest
      assert body["status"] == "pending_review"
      assert body["requested_by"] == review.requested_by
      assert body["def_id"] == review.def_id
      assert body["row_version"] == review.row_version

      # GET /promotions/:id is untouched by the shaping: its seven-key run map
      Repo.insert!(
        %PromotionAssertionRun{
          review_id: review.id,
          idempotency_key: "req446-#{System.unique_integer([:positive, :monotonic])}",
          plan_digest: review.plan_digest,
          status: :passed,
          assertions_total: 1,
          assertions_passed: 1,
          assertions_failed: 0,
          completed_at: DateTime.utc_now()
        },
        prefix: ctx.a.schema_name
      )

      run_resp = get(ctx.a, "/#{review.id}")
      assert run_resp.status == 200
      run = Jason.decode!(run_resp.resp_body)["assertion_run"]

      assert run |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 "run_id",
                 "status",
                 "sandbox_id",
                 "teardown_error",
                 "assertions_passed",
                 "assertions_failed",
                 "failing_assertion_ids"
               ])

      assert run["status"] == "passed"
    end
  end

  describe "operator" do
    test "context_unchanged_for_operator", ctx do
      %{review: review, plan: plan} =
        Scope.seed_review!(ctx.p, ctx.b.tenant_id, ctx.a.tenant_id, %{
          meta: %{origin_tenant_id: ctx.b.tenant_id}
        })

      resp = context(ctx.p, review.id)
      assert resp.status == 200
      assert resp.resp_body =~ ctx.b.tenant_id
      assert resp.resp_body =~ ctx.a.tenant_id

      body = Jason.decode!(resp.resp_body)

      # equal to the unshaped (stored) plan
      assert body["serialised_plan"] == plan |> Jason.encode!() |> Jason.decode!()
    end
  end
end
