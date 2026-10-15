defmodule Letflow.Routers.Promotions do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Promotion-pipeline sub-router (REQ-077), mounted at `/promotions` by
  `Letflow.Plugs.ApiPipeline`. Ports six R-Co route modules
  (`promotion_review.zig`, `promotions.zig`, `promotion_read.zig`,
  `promotion_assertion.zig`) as eight of this requirement's ten routes — R9
  (rollback) lives in `Letflow.Routers.Definitions` and R10 (ENV-03 promote)
  lives in `Letflow.Routers.Tenants`, each for the one-forward-per-prefix
  reason stated in their own moduledocs. See
  `lib/letflow/design/req077-promotion-pipeline-routes.md` for the full
  gate-approved design this module implements.

  ## Route table (design §1)

  | # | Method | Path | Handler | Context call(s) | Success |
  |---|---|---|---|---|---|
  | R1 | POST | `/` | `handle_submit/2` | `PromotionPlan.compute_promotion_plan/5` -> `PromotionConflict.reject_if_conflicts/4` -> `PromotionDigest.compute_plan_digest/1` -> `PromotionReviewStore.insert_review/2` | 201 |
  | R2 | POST | `/plan` | `handle_plan/2` | `PromotionPlan.compute_promotion_plan/5` | 200 |
  | R3 | GET | `/:id` | `handle_get_assertion_run/2` | `PromotionReviewStore.get_review/2` -> `Definitions.get_latest_assertion_run/2` | 200 |
  | R4 | GET | `/:id/context` | `handle_context/2` | `PromotionReviewStore.get_review/2` | 200 |
  | R5 | POST | `/:id/approve` | `handle_approve/2` | `PromotionReviewStore.approve_review/4` | 200 |
  | R6 | POST | `/:id/reject` | `handle_reject/2` | `PromotionReviewStore.reject_review/3` | 200 |
  | R7 | POST | `/:id/apply` | `handle_apply/2` | `Promotion.apply_review/4` | 200 |
  | R8 | POST | `/:review_id/run-assertions` | `handle_run_assertions/2` | `PromotionArtifact.from_json/1` -> `Definitions.apply_promotion_assertion_rerun/6` | 200/422 |
  | R11 | GET | `/platform-events` | `handle_platform_events/1` | `Letflow.EventStore.list_platform_events/1` | 200 |
  | R12 | GET | `/` | `handle_list_reviews/1` | `PromotionReviewStore.list_reviews/2` | 200 |

  R12 is REQ-397 (`lib/letflow/design/req397-promotion-review-list-route.md`)
  -- a paginated, filterable list of the caller's own tenant's
  `promotion_reviews` rows, so a reviewer can discover reviews without an
  out-of-band review id. Declared last among this module's routes (design
  §4.1), after `POST /:review_id/run-assertions` and before `match _` --
  purely stylistic, since a plain `GET /` cannot be captured by any `:id`-
  shaped wildcard in this module regardless of declaration order.

  R11 is ISS-0733 GAP B (`lib/letflow/design/iss0733-promotion-audit-and-platform-events-read.md`
  §2) -- a dedicated `:PromotionsRead` read (own tenant schema only) of the platform
  sentinel's own event stream (`EventStore.platform_instance_id/0`), added
  alongside this module's other ten routes rather than as a scoped exception
  in `Letflow.Instances.timeline/3` (design §2.3). Declared before `/:id` so
  the literal `platform-events` path segment is never captured by the `:id`
  wildcard.

  ## The `POST /promotions` collision, resolved (F-2, a deliberate divergence from R-Co)

  PROVENANCE (historical, not current decision authority):
  R-Co has two handlers claiming this path: `promotions.zig`'s
  `handleCreatePromotionPlan` (a read-only diff preview, wired at
  `main.zig:1577`) and `promotion_review.zig`'s `handleSubmitPromotion`
  (computes the diff, re-checks conflicts, computes the digest, and inserts
  a `promotion_reviews` row — never wired in R-Co at all, F-1). This module
  assigns `POST /promotions` to **submit** (`handleSubmitPromotion`'s
  semantics, 201, a durable write) and `POST /promotions/plan` to **preview**
  (`handleCreatePromotionPlan`'s semantics, 200, read-only) — the only
  assignment where a `POST` on the collection URI that returns 201 and
  creates a resource lands on the collection URI itself. Nothing outside
  R-Co consumed either contract before this requirement (`web/` has no
  promotion client), so there is no compatibility cost either way.

  ## Authorization: explicit keys, TENANT scope (ISS-0993 / ISS-0994)

  Every route is declared with `authz_get`/`authz_post` and an explicit policy
  key: `:PromotionsRead` (R3 `GET /:id`, R4 `GET /:id/context`, R11
  `GET /platform-events`, R12 `GET /`) and `:PromotionsManage` (R1 `POST /`, R2
  `POST /plan`, R5-R8 approve/reject/apply/run-assertions). Both permissions
  are TENANT scope (`Letflow.Api.Authorization.permission_scope/1`): own-tenant
  review lifecycle works for the tenant's administrators, and nothing here
  resolves to `:Unknown` any more. R11 reads only the sentinel event stream
  inside the caller's own tenant schema.

  REQ-446 (named, scoped permissions): the three permissions are named,
  not `:Unknown`, and all TENANT scope -- including R11, which returns only
  rows of the caller's own schema, so no separate platform permission exists.
  INV-10 response shaping: for a caller that is NOT a platform-tenant operator
  (`Letflow.PlatformTenant.scope_facts_for/1` on `auth_context.tenant_id`, never a
  request value), R11 is shaped by a per-event-type payload ALLOWLIST
  (ISS-0999, `@platform_event_allowlist`): only listed scalar keys are kept, the
  tenant-id keys only when they are the caller's own, `source_definition_id`,
  `review_id`, teardown `error` and every unknown key are omitted, an unknown
  event type gets payload `{}` (event kept), and the item has no `actor_id`.
  The R4 `serialised_plan` is likewise a top-level key ALLOWLIST (ISS-1021,
  `@plan_allowlist`): `process_key` and `base_version` (scalars), the source and
  target tenant ids only when they are the caller's own, the source and target
  definition ids only when their own side's tenant id is the caller's, and
  `entries` as stored only when both stored tenant ids are the caller's own, `[]`
  otherwise (ISS-1023). Every other key is
  omitted and a non-map plan becomes `{"entries": []}`. Operators see both
  unchanged.

  The rule for naming ANOTHER tenant (`Letflow.PlatformTenant.cross_tenant_promotion_operator_only?/0`): only a
  request that reads or writes a tenant OTHER than the caller's is
  operator-only (platform-tenant `PLATFORM_ADMIN`). Product limitation: a
  customer cannot promote from its test tenant to its production tenant by
  itself until a tenant-pairing model is specified. That check is
  `Letflow.Api.TenantTarget.authorize_target_tenant/2` (source and target ids
  of R1/R2, stored ids of R5-R8), called by these handlers (A2).

  ## INV-5 — a cross-tenant review id is the SAME response as a nonexistent one (design §5)

  `promotion_reviews` carries no `tenant_id` column at all (REQ-064 /
  Decision 0006 D2) — the per-tenant Postgres schema a row lives in already
  identifies its tenant. So another tenant's review is not "found and then
  filtered" — it is simply not present in the schema `conn.assigns.scoped_opts`
  points at, and the underlying primary-key lookup resolves to nothing for
  that reason through the exact same code path as a review id that was
  never issued to anyone. There is
  deliberately no second, unscoped existence check anywhere in this module —
  one would (a) reintroduce the distinguishability INV-5 forbids, (b) add a
  round-trip on one path and not the other (a timing signal), and (c) itself
  be a cross-tenant read (an INV-1 violation).

  ## The single-atom 409 rule (design §6.1) — approve/reject/apply

  `PromotionReviewStore` returns the same `:invalid_transition` atom for
  every illegal edge AND for a lost optimistic-lock race — it cannot, and
  must not, be asked to distinguish them (a second read to find out would be
  a TOCTOU and an oracle off a failed write). So R5/R6/R7 map
  `:invalid_transition` to exactly one 409 document, `detail: "review is not
  in a state that permits this transition"`, naming the *operation class*,
  never the row's actual status. This is a deliberate 409 upgrade from
  R-Co's 400 `INVALID_REVIEW_TRANSITION` (D-8), required by AC4's own
  wording; the other two 409s (`PLAN_DIGEST_MISMATCH`,
  `DUPLICATE_REVIEW`) needed no such upgrade and carry through unchanged as
  409s here too.

  ## Assertion-run idempotency is preserved by omission (design §8.1, AC2)

  PROVENANCE (historical, not current decision authority):
  `Definitions.apply_promotion_assertion_rerun/6` already derives its own
  idempotency key from `(review_id, plan_digest)` and returns the cached row
  unchanged on a repeat. This module's only obligations are omissions: no
  `Idempotency-Key` header is read or forwarded, and `assertion_rerun_map/1`
  (§7.5) does NOT surface `idempotent_hit` — the one field in
  `assertion_rerun_result/0` that differs between the first call and a
  repeat. Emitting it would make AC2's "two identical successful responses"
  false by construction. R-Co's `ALREADY_RECORDED` 200-with-error-envelope
  repeat path (`promotion_assertion.zig:133`, D-5) is not ported — it breaks
  AC2 outright.

  ## The assertion-run gate condition (design §7.5)

  R8's 200-vs-422 split keys on the returned `assertions_failed == 0`, NOT
  on `status == :passed` — `apply_promotion_assertion_rerun/6`'s own `@doc`
  states this gate condition explicitly (a `status = :teardown_failed`
  result with `assertions_failed == 0` is a green gate). Porting R-Co's
  `result.status != .failed` check would silently disagree with that
  documented contract.

  ## The unknown-field note (design §4.4)

  PROVENANCE (historical, not current decision authority):
  `Letflow.Api.Validation.validate/2` returns `Map.take(body,
  declared_field_names)`, so a caller-injected field not in a route's schema
  (e.g. an `approved_by` trying to override `actor_id`) cannot reach the
  handler's `attrs` at all — structurally, not by a runtime check. R-Co's
  422 `UNKNOWN_FIELD` response (`promotion_review.zig:398-406`) is therefore
  not ported: stronger by construction, weaker in diagnostics only.

  ## The `permission_checker` (design §7.9; ISS-0993 section 9)

  `PromotionPlan.compute_promotion_plan/5` and `Promotion.promote_definition/3`
  require a `permission_checker`. Every call site below passes
  `Letflow.Definitions.PromotionAccess.checker_for(conn.assigns.auth_context)`:
  true iff the source tenant equals the caller's own tenant or the caller holds
  platform scope (recomputed, never the stored flag). The old allow-all
  default checker was deleted from `PromotionPlan` (A2). In addition,
  every tenant id the REQUEST names (R1/R2 body ids) or a stored review names
  (R5/R6/R7/R8 re-check) goes through `Letflow.Api.TenantTarget.authorize_target_tenant/2`
  BEFORE any lookup: a foreign id is the same 404 as a nonexistent one.

  The READ routes (`GET /:id`, `GET /:id/context`, `GET /`) use a separate,
  party-based predicate (`review_read_access/2`, ISS-1029): a caller whose
  tenant is the stored source OR target keeps the own-side view, a non-party
  non-operator gets the nonexistent-id 404 (the list omits the row). The write
  routes keep the strict both-sides predicate.

  ## The allowlist statement (design §7, AC6)

  Every response body below is a hand-built map with exactly the key set
  named in its own `@doc` — never a `Jason.Encoder` derivation over an Ecto
  struct, never `Map.from_struct/1`, never `Map.drop/2`. This module never
  touches the persistence layer directly — no such call and no such import
  or alias appears anywhere in it — every database-touching call goes
  through a promotion context
  module (`Letflow.Definitions.PromotionPlan`/`PromotionConflict`/
  `PromotionDigest`/`PromotionReviewStore`/`PromotionArtifact`,
  `Letflow.Definitions`, `Letflow.Definitions.Promotion`), each already
  scoped by the `[prefix: ...]` fragment `Letflow.Plugs.Authorize` resolved
  before this router's `:dispatch` ever ran.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Definitions
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionArtifact
  alias Letflow.Definitions.PromotionAccess
  alias Letflow.Definitions.PromotionConflict
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionPlan
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.TenantTarget
  alias Letflow.Api.Validation
  alias Letflow.Api.Pagination
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.EventStore
  alias Letflow.EventStore.PlatformEvents
  alias Letflow.PlatformTenant

  # Explicit policy keys (see moduledoc): :PromotionsRead / :PromotionsManage.
  # "/plan" is declared before the "/:id/..." two-segment patterns even
  # though it cannot actually collide with any of them (no `post "/:id"`
  # exists in this file) -- the cheap, order-independent-looking form
  # (design §2.2).

  authz_post "/", :PromotionsManage do
    handle_submit(conn)
  end

  authz_post "/plan", :PromotionsManage do
    handle_plan(conn)
  end

  # ISS-0733 GAP B (R11, design §2.4) -- declared before "/:id" (same
  # ordering discipline as "/plan" above) so the literal "platform-events"
  # segment is never captured by the :id wildcard.
  authz_get "/platform-events", :PromotionsRead do
    handle_platform_events(conn)
  end

  authz_get "/:id", :PromotionsRead do
    handle_get_assertion_run(conn, conn.params["id"])
  end

  authz_get "/:id/context", :PromotionsRead do
    handle_context(conn, conn.params["id"])
  end

  authz_post "/:id/approve", :PromotionsManage do
    handle_approve(conn, conn.params["id"])
  end

  authz_post "/:id/reject", :PromotionsManage do
    handle_reject(conn, conn.params["id"])
  end

  authz_post "/:id/apply", :PromotionsManage do
    handle_apply(conn, conn.params["id"])
  end

  authz_post "/:review_id/run-assertions", :PromotionsManage do
    handle_run_assertions(conn, conn.params["review_id"])
  end

  # R12 (design §4.1) -- declared last among this module's routes, mirroring
  # Routers.Definitions's own `authz_get "/"` placement. Purely
  # stylistic/consistency-driven: `GET /` cannot be captured by `GET /:id`,
  # `GET /:id/context`, or `GET /platform-events` regardless of declaration
  # order, since none of those patterns matches an empty path segment.
  authz_get "/", :PromotionsRead do
    handle_list_reviews(conn)
  end

  authz_unmatched(:ordinary)

  # ── POST /promotions -- R1, submit (design §7.1) ────────────────────────

  @submit_schema [
    %FieldConstraint{
      name: "source_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "target_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "process_key",
      required: true,
      type: :string,
      reject_empty_string: true,
      max_length: 255
    },
    %FieldConstraint{
      name: "base_version",
      required: true,
      type: :string,
      reject_empty_string: true,
      max_length: 64
    }
  ]

  defp handle_submit(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case Validation.validate(@submit_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        if tenants_authorized?(conn, [attrs["source_tenant_id"], attrs["target_tenant_id"]]) do
          render_submit(conn, do_submit(conn, actor_id, attrs, opts))
        else
          Response.not_found(conn)
        end
    end
  end

  # ISS-0993 section 8/9: every tenant id the request (or a stored review)
  # names must be the caller's own or the caller must hold platform scope,
  # decided BEFORE any lookup; a denial is the zero-detail 404.
  defp tenants_authorized?(conn, tenant_ids) do
    Enum.all?(tenant_ids, &(TenantTarget.authorize_target_tenant(conn, &1) == :ok))
  end

  defp do_submit(conn, actor_id, attrs, opts) do
    with {:ok, plan} <-
           PromotionPlan.compute_promotion_plan(
             actor_id,
             attrs["source_tenant_id"],
             attrs["target_tenant_id"],
             attrs["process_key"],
             permission_checker: PromotionAccess.checker_for(conn.assigns.auth_context)
           ),
         :ok <-
           PromotionConflict.reject_if_conflicts(
             actor_id,
             attrs["target_tenant_id"],
             [attrs["process_key"]],
             [attrs["base_version"]]
           ) do
      digest = PromotionDigest.compute_plan_digest(plan)

      PromotionReviewStore.insert_review(
        %{plan: plan, digest: digest, requested_by: actor_id},
        opts
      )
    end
  end

  defp render_submit(conn, {:ok, %PromotionReview{} = review}) do
    Response.created(conn, %{"review_id" => review.id, "plan_digest" => review.plan_digest})
  end

  defp render_submit(conn, {:error, :forbidden}),
    do: Response.forbidden(conn, "insufficient permissions")

  defp render_submit(conn, {:error, :invalid_promotion_source}),
    do:
      Response.send_problem(
        conn,
        Error.invalid_promotion_source("source_tenant_id must name a test tenant")
      )

  defp render_submit(conn, {:error, :empty_plan}),
    do:
      Response.send_problem(
        conn,
        Error.empty_promotion_plan("source and target are identical after canonicalisation")
      )

  defp render_submit(conn, {:error, :invalid_tenant_id}),
    do:
      Response.unprocessable(
        conn,
        "source_tenant_id or target_tenant_id does not name a provisioned tenant"
      )

  defp render_submit(conn, {:error, {:conflicts, details}}),
    do:
      Response.send_problem(
        conn,
        Error.promotion_conflict("target tenant has advanced past base_version", details)
      )

  # Route always passes two 1-element lists -- unreachable by construction.
  defp render_submit(conn, {:error, :mismatched_process_key_list}),
    do: Response.internal_error(conn)

  defp render_submit(conn, {:error, :duplicate_review}),
    do: Response.conflict(conn, "a live review for this plan digest already exists")

  # digest computed from the same plan one line earlier -- a mismatch here is
  # internal inconsistency, never caller-caused.
  defp render_submit(conn, {:error, :digest_mismatch}), do: Response.internal_error(conn)
  defp render_submit(conn, {:error, :invalid_schema_name}), do: Response.internal_error(conn)
  defp render_submit(conn, {:error, %Ecto.Changeset{}}), do: Response.internal_error(conn)

  # ── POST /promotions/plan -- R2, plan preview (design §7.2) ─────────────

  @plan_schema [
    %FieldConstraint{
      name: "source_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "target_tenant_id",
      required: true,
      type: :uuid,
      reject_empty_string: true
    },
    %FieldConstraint{
      name: "process_key",
      required: true,
      type: :string,
      reject_empty_string: true,
      max_length: 255
    }
  ]

  defp handle_plan(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case Validation.validate(@plan_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        if tenants_authorized?(conn, [attrs["source_tenant_id"], attrs["target_tenant_id"]]) do
          result =
            PromotionPlan.compute_promotion_plan(
              actor_id,
              attrs["source_tenant_id"],
              attrs["target_tenant_id"],
              attrs["process_key"],
              permission_checker: PromotionAccess.checker_for(conn.assigns.auth_context)
            )

          render_plan(conn, result, opts)
        else
          Response.not_found(conn)
        end
    end
  end

  defp render_plan(conn, {:ok, plan}, _opts),
    do: Response.ok(conn, %{"entries" => Enum.map(plan.entries, &plan_entry_map/1)})

  defp render_plan(conn, {:error, :forbidden}, _opts),
    do: Response.forbidden(conn, "insufficient permissions")

  defp render_plan(conn, {:error, :invalid_promotion_source}, _opts),
    do:
      Response.send_problem(
        conn,
        Error.invalid_promotion_source("source_tenant_id must name a test tenant")
      )

  defp render_plan(conn, {:error, :empty_plan}, _opts),
    do:
      Response.send_problem(
        conn,
        Error.empty_promotion_plan("source and target are identical after canonicalisation")
      )

  defp render_plan(conn, {:error, :invalid_tenant_id}, _opts),
    do:
      Response.unprocessable(
        conn,
        "source_tenant_id or target_tenant_id does not name a provisioned tenant"
      )

  # PROVENANCE (historical, not current decision authority):
  # Exactly 5 keys (design §7.2), ported from promotions.zig:145-163.
  # `before`/`after` emitted as-is (object/string/nil) -- not stringified,
  # unlike R-Co (a considered improvement, not a port defect).
  @doc false
  @spec plan_entry_map(PromotionPlan.plan_entry()) :: map()
  defp plan_entry_map(entry) do
    %{
      "type" => Atom.to_string(entry.type),
      "id" => entry.id,
      "change_kind" => Atom.to_string(entry.change_kind),
      "before" => entry.before,
      "after" => entry.after
    }
  end

  # ── GET /promotions/:id -- R3, latest assertion run (design §7.4) ───────

  defp handle_get_assertion_run(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    case PromotionReviewStore.get_review(raw_id, opts) do
      {:error, :review_not_found} ->
        Response.not_found(conn)

      {:ok, %PromotionReview{} = review} ->
        # ISS-1029: a non-party gets the nonexistent-id 404 BEFORE any
        # assertion-run data is read; a named party (:own_side) keeps the
        # existing 7-key run map (no new shape; AC1/AC5).
        case review_read_access(conn, review) do
          :none ->
            Response.not_found(conn)

          _full_or_own_side ->
            render_assertion_run(conn, Definitions.get_latest_assertion_run(raw_id, opts))
        end
    end
  end

  defp render_assertion_run(conn, {:error, :not_found}),
    do: Response.ok(conn, %{"assertion_run" => nil})

  defp render_assertion_run(conn, {:ok, run}),
    do: Response.ok(conn, %{"assertion_run" => assertion_run_map(run)})

  # PROVENANCE (historical, not current decision authority):
  # Exactly 7 keys (design §7.4), ported from promotion_read.zig:102-149.
  # `plan_digest` is deliberately excluded -- see design §7.4/§8.3: emitting
  # it here would hand a reader of an assertion run the exact token needed
  # to approve or apply the review it belongs to.
  @doc false
  @spec assertion_run_map(Definitions.PromotionAssertionRun.t()) :: map()
  defp assertion_run_map(run) do
    %{
      "run_id" => run.id,
      "status" => Atom.to_string(run.status),
      "sandbox_id" => run.sandbox_id,
      "teardown_error" => run.teardown_error,
      "assertions_passed" => run.assertions_passed,
      "assertions_failed" => run.assertions_failed,
      "failing_assertion_ids" => run.failing_assertion_ids
    }
  end

  # ── GET /promotions/:id/context -- R4 (design §7.3) ──────────────────────

  defp handle_context(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    render_context(conn, PromotionReviewStore.get_review(raw_id, opts))
  end

  defp render_context(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  # ISS-1029: a NON-PARTY (neither stored id is the caller's tenant) answers the
  # same zero-detail 404 as a nonexistent id; a named party keeps the ISS-1023
  # own-side view (shape_plan/2 stays LIVE for it: foreign ids omitted).
  defp render_context(conn, {:ok, %PromotionReview{} = review}) do
    case review_read_access(conn, review) do
      :none -> Response.not_found(conn)
      _full_or_own_side -> Response.ok(conn, review_context_map(review, tenant_view(conn)))
    end
  end

  # ISS-1029 (AC7): an unparseable stored text must not 500 the operator, who
  # sees every row. Degraded context: serialised_plan renders as JSON null.
  @spec tolerant_plan(String.t()) :: term()
  defp tolerant_plan(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # Exactly 9 keys (design §7.3), ported from promotion_review.zig:321-337.
  # `serialised_plan` is decoded (real object, not a spliced raw string).
  # `created_at` is real (`iso8601/1` of `inserted_at`) -- R-Co hardcodes
  # "1970-01-01T00:00:00Z" (D-3), not ported. `assertions`/
  # `needs_review_package` are domain logic computed inline by the handler
  # in R-Co and are not ported here (OQ-3, no context module produces either).
  @doc false
  @spec review_context_map(PromotionReview.t(), tenant_view()) :: map()
  defp review_context_map(review, view) do
    %{
      "review_id" => review.id,
      "plan_digest" => review.plan_digest,
      "serialised_plan" => shape_plan(tolerant_plan(review.serialised_plan), view),
      "status" => Atom.to_string(review.status),
      "requested_by" => review.requested_by,
      "def_type" => review.def_type,
      "def_id" => review.def_id,
      "created_at" => iso8601(review.inserted_at),
      "row_version" => review.row_version
    }
  end

  # ── POST /promotions/:id/approve -- R5 (design §7.5, §5.3, §6) ──────────

  @digest_schema [
    %FieldConstraint{
      name: "plan_digest",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 64,
      max_length: 64
    }
  ]

  defp handle_approve(conn, raw_id) do
    case cast_review_id(raw_id) do
      {:error, :not_uuid} ->
        Response.not_found(conn)

      {:ok, id} ->
        opts = conn.assigns.scoped_opts
        actor_id = conn.assigns.auth_context.user_id

        case Validation.validate(@digest_schema, conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, attrs} ->
            if stored_tenants_authorized?(conn, id, opts) do
              render_approve(
                conn,
                PromotionReviewStore.approve_review(id, actor_id, attrs["plan_digest"], opts)
              )
            else
              Response.not_found(conn)
            end
        end
    end
  end

  defp render_approve(conn, {:ok, review}),
    do: Response.ok(conn, %{"review_id" => review.id, "status" => "approved"})

  defp render_approve(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  defp render_approve(conn, {:error, :self_approval_forbidden}),
    do: Response.forbidden(conn, "a reviewer cannot approve their own promotion request")

  defp render_approve(conn, {:error, :digest_mismatch}),
    do: Response.conflict(conn, "the provided plan_digest does not match the stored digest")

  defp render_approve(conn, {:error, :invalid_transition}), do: invalid_transition_response(conn)

  # ── POST /promotions/:id/reject -- R6 (design §7.5, §5.2, §6) ───────────

  defp handle_reject(conn, raw_id) do
    case cast_review_id(raw_id) do
      {:error, :not_uuid} ->
        Response.not_found(conn)

      {:ok, id} ->
        opts = conn.assigns.scoped_opts
        actor_id = conn.assigns.auth_context.user_id

        case Validation.validate([], conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, _attrs} ->
            if stored_tenants_authorized?(conn, id, opts) do
              render_reject(conn, PromotionReviewStore.reject_review(id, actor_id, opts))
            else
              Response.not_found(conn)
            end
        end
    end
  end

  defp render_reject(conn, {:ok, review}),
    do: Response.ok(conn, %{"review_id" => review.id, "status" => "rejected"})

  defp render_reject(conn, {:error, :review_not_found}), do: Response.not_found(conn)
  defp render_reject(conn, {:error, :invalid_transition}), do: invalid_transition_response(conn)

  # ── POST /promotions/:id/apply -- R7 (design §7.5, §9.3) ────────────────

  defp handle_apply(conn, raw_id) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case Validation.validate(@digest_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        if stored_tenants_authorized?(conn, raw_id, opts) do
          result =
            Promotion.apply_review(
              raw_id,
              actor_id,
              attrs["plan_digest"],
              Keyword.merge(opts,
                permission_checker: PromotionAccess.checker_for(conn.assigns.auth_context),
                event_appender: &PlatformEvents.append_definition_promoted/2
              )
            )

          render_apply(conn, result)
        else
          Response.not_found(conn)
        end
    end
  end

  # R5-R8 (approve, reject, apply, run-assertions; design 7.2 rows 30/31,
  # ISS-1026): a review row written before this fix must
  # not be able to read or write another tenant. The stored source/target ids
  # are re-checked with the same helper before any promotion work. A review
  # that does not exist (or is not a UUID) is left to the downstream
  # `:review_not_found` -> 404 path, so the bytes are identical.
  defp stored_tenants_authorized?(conn, raw_review_id, opts) do
    case PromotionReviewStore.get_review(raw_review_id, opts) do
      {:ok, %PromotionReview{} = review} -> review_tenants_authorized?(conn, review)
      {:error, :review_not_found} -> true
    end
  end

  # The strict WRITE predicate (ISS-1026): BOTH stored ids must be the
  # caller's. Used by approve/reject/apply/run-assertions only; the read
  # routes use review_read_access/2. A malformed or non-map stored plan
  # decodes to %{} so its (absent) ids fail the check closed; never raises.
  @spec review_tenants_authorized?(Plug.Conn.t(), PromotionReview.t()) :: boolean()
  defp review_tenants_authorized?(conn, %PromotionReview{serialised_plan: serialised}) do
    plan = stored_plan_ids(serialised)
    tenants_authorized?(conn, [plan["source_tenant_id"], plan["target_tenant_id"]])
  end

  # ISS-1029 READ predicate (GET /:id, GET /:id/context, the list), separate
  # from the write predicate above:
  #   :full      operator, or both stored ids are the caller's tenant
  #   :own_side  a named party (exactly one stored id is the caller's tenant):
  #              the ISS-1023 own-side view
  #   :none      non-party, or ids unreadable (fail closed): nonexistent-id 404
  # The caller's tenant comes ONLY from the authenticated auth_context (via
  # TenantTarget.authorize_target_tenant/2), never from the request (AC3).
  # Never raises: non-bang decode, and the operator path never decodes.
  @spec review_read_access(Plug.Conn.t(), PromotionReview.t()) :: :full | :own_side | :none
  defp review_read_access(conn, %PromotionReview{serialised_plan: serialised}) do
    case tenant_view(conn) do
      :operator ->
        :full

      {:tenant, _own} ->
        plan = stored_plan_ids(serialised)
        own_source? = TenantTarget.authorize_target_tenant(conn, plan["source_tenant_id"]) == :ok
        own_target? = TenantTarget.authorize_target_tenant(conn, plan["target_tenant_id"]) == :ok

        cond do
          own_source? and own_target? -> :full
          own_source? or own_target? -> :own_side
          true -> :none
        end
    end
  end

  @spec stored_plan_ids(String.t()) :: map()
  defp stored_plan_ids(serialised) do
    case Jason.decode(serialised) do
      {:ok, %{} = decoded} -> decoded
      _malformed -> %{}
    end
  end

  defp render_apply(conn, {:ok, %{review_id: review_id}}),
    do: Response.ok(conn, %{"review_id" => review_id, "status" => "applied"})

  defp render_apply(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  defp render_apply(conn, {:error, :digest_mismatch}),
    do: Response.conflict(conn, "the provided plan_digest does not match the stored digest")

  defp render_apply(conn, {:error, :invalid_transition}), do: invalid_transition_response(conn)

  defp render_apply(conn, {:error, :assertion_run_missing}),
    do:
      Response.conflict(
        conn,
        "no assertion run has been recorded for this review; run assertions before applying"
      )

  defp render_apply(conn, {:error, :assertion_run_digest_mismatch}),
    do:
      Response.conflict(
        conn,
        "the most recent assertion run does not match the plan_digest being applied; re-run assertions against the current plan"
      )

  defp render_apply(conn, {:error, :assertion_run_in_progress}),
    do:
      Response.conflict(
        conn,
        "the most recent assertion run for this review has not finished yet; wait for it to complete or re-run assertions before applying"
      )

  defp render_apply(conn, {:error, :assertion_run_failed}),
    do:
      Response.conflict(
        conn,
        "the most recent assertion run recorded failing assertions; applying is blocked until a rehearsal with zero failures is recorded"
      )

  defp render_apply(conn, {:error, {:promotion_failed, :forbidden}}),
    do: Response.forbidden(conn, "insufficient permissions")

  defp render_apply(conn, {:error, {:promotion_failed, :invalid_promotion_source}}),
    do:
      Response.send_problem(
        conn,
        Error.invalid_promotion_source("source_tenant_id must name a test tenant")
      )

  defp render_apply(conn, {:error, {:promotion_failed, :source_definition_missing}}),
    do: Response.conflict(conn, "the source definition is no longer active")

  defp render_apply(conn, {:error, {:promotion_failed, {:conflicts, details}}}),
    do:
      Response.send_problem(
        conn,
        Error.promotion_conflict("target tenant has advanced past base_version", details)
      )

  defp render_apply(conn, {:error, {:promotion_failed, :duplicate_version}}),
    do: Response.conflict(conn, "the target version already exists in the target tenant")

  defp render_apply(conn, {:error, {:promotion_failed, :invalid_tenant_id}}),
    do: Response.internal_error(conn)

  # GH 2534 PR 7c-1 (design 4.5): a promoted graph binding a tenant script the TARGET tenant
  # cannot run is refused before activation, like Definitions.activate/2's 422.
  defp render_apply(
         conn,
         {:error, {:promotion_failed, {:script_binding_invalid, node_id, reason}}}
       ),
       do: Response.script_binding_invalid(conn, node_id, reason)

  # GH #2587 PR A1b (design gh2587-req499-pr-a-prerequisites.md 2A.4): the promoted graph names
  # the reserved engine namespace; same 422 body as Definitions.activate/2's.
  defp render_apply(
         conn,
         {:error, {:promotion_failed, {:expression_references_reserved_variable, references}}}
       ),
       do: Response.expression_references_reserved_variable(conn, references)

  defp render_apply(conn, {:error, {:promotion_failed, _other}}),
    do: Response.internal_error(conn)

  # ── POST /promotions/:review_id/run-assertions -- R8 (design §7.5) ──────

  @run_assertions_schema [
    %FieldConstraint{
      name: "plan_digest",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 64,
      max_length: 64
    },
    %FieldConstraint{name: "artifact", required: true, type: :object}
  ]

  defp handle_run_assertions(conn, raw_review_id) do
    case cast_review_id(raw_review_id) do
      {:error, :not_uuid} ->
        Response.not_found(conn)

      {:ok, review_id} ->
        opts = conn.assigns.scoped_opts

        case Validation.validate(@run_assertions_schema, conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, attrs} ->
            if stored_tenants_authorized?(conn, review_id, opts) do
              run_assertions(conn, review_id, attrs, opts)
            else
              Response.not_found(conn)
            end
        end
    end
  end

  defp run_assertions(conn, review_id, attrs, opts) do
    case PromotionArtifact.from_json(attrs["artifact"]) do
      {:error, {:invalid_artifact, _field}} ->
        Response.unprocessable(conn, "artifact is not a well-formed promotion artifact")

      {:ok, artifact} ->
        sandbox_pool =
          Application.get_env(:letflow, :promotion_assertion_pool, Letflow.SandboxPool)

        max_wait_ms = Application.get_env(:letflow, :promotion_assertion_max_wait_ms, 5_000)

        result =
          Definitions.apply_promotion_assertion_rerun(
            review_id,
            attrs["plan_digest"],
            artifact,
            sandbox_pool,
            max_wait_ms,
            Keyword.merge(opts,
              event_appender: &PlatformEvents.append_promotion_assertion_teardown_failed/2
            )
          )

        render_run_assertions(conn, result)
    end
  end

  defp render_run_assertions(conn, {:ok, %{assertions_failed: 0} = r}),
    do: Response.ok(conn, assertion_rerun_map(r))

  # Body is the plain assertion_rerun_map/1 (design §7.5 -- "same body
  # shape" as the 200 case), NOT an RFC 9457 problem document: a
  # not-all-assertions-passed result is structured content the caller needs
  # to read (run_id, failing_assertion_ids, ...), not an error envelope.
  defp render_run_assertions(conn, {:ok, %{assertions_failed: n} = r}) when n > 0,
    do: Response.send_json(conn, 422, assertion_rerun_map(r))

  defp render_run_assertions(conn, {:error, :review_not_found}), do: Response.not_found(conn)

  defp render_run_assertions(conn, {:error, :sandbox_unavailable}),
    do: Response.service_unavailable(conn, "no sandbox free within timeout")

  defp render_run_assertions(conn, {:error, :provision_failed}),
    do: Response.service_unavailable(conn, "sandbox provisioning failed")

  defp render_run_assertions(conn, {:error, :fixture_load_failed}),
    do: Response.unprocessable(conn, "fixture load into sandbox failed")

  defp render_run_assertions(conn, {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}),
    do: Response.internal_error(conn)

  defp render_run_assertions(conn, {:error, _other}), do: Response.internal_error(conn)

  # PROVENANCE (historical, not current decision authority):
  # Exactly 6 keys (design §7.5), ported from promotion_assertion.zig:145-170.
  # `idempotent_hit` is deliberately NOT a key -- see moduledoc, AC2.
  @doc false
  @spec assertion_rerun_map(Definitions.assertion_rerun_result()) :: map()
  defp assertion_rerun_map(r) do
    %{
      "run_id" => r.run_id,
      "status" => Atom.to_string(r.status),
      "assertions_passed" => r.assertions_passed,
      "assertions_failed" => r.assertions_failed,
      "failing_assertion_ids" => r.failing_assertion_ids,
      "sandbox_id" => r.sandbox_id
    }
  end

  # ── GET /promotions/platform-events -- R11 (design §2.4-§2.6, ISS-0733 GAP B) ─

  # A new, distinct cursor-endpoint prefix -- does not collide with "A:"
  # (Routers.Audit), "T:"/"U:" (Tenants/Identity) already in use elsewhere;
  # decode_cursor/4's {:error, :wrong_endpoint} rejects a cursor minted by
  # another endpoint.
  @platform_events_cursor_prefix "PE:"

  @spec handle_platform_events(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_platform_events(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params
    opts = conn.assigns.scoped_opts

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, cursor_seek} <- parse_platform_events_cursor(Map.get(query, "cursor")) do
      params = %{
        prefix: Keyword.fetch!(opts, :prefix),
        page_size: page_size,
        cursor: cursor_seek,
        event_type: non_empty_platform_event_type(Map.get(query, "event_type"))
      }

      # Shaping happens after the page is read; the cursor is independent of it.
      render_platform_events(
        conn,
        EventStore.list_platform_events(params),
        tenant_view(conn)
      )
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_cursor} ->
        Response.bad_request(conn, "invalid cursor")
    end
  end

  defp render_platform_events(conn, {:ok, %{items: items, next_cursor: next_cursor}}, view) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &platform_event_map(&1, view)),
      "next_cursor" => next_cursor
    })
  end

  # Same COLLAPSE/STATUS split as Routers.Audit's parse_cursor_param/1 --
  # every decode_cursor/4 failure (:invalid_base64, :wrong_endpoint,
  # :expired) folds into one route-level :invalid_cursor, mapped to 400 in
  # handle_platform_events/1's else block above.
  defp parse_platform_events_cursor(nil), do: {:ok, nil}
  defp parse_platform_events_cursor(""), do: {:ok, nil}

  defp parse_platform_events_cursor(raw) when is_binary(raw) do
    with {:ok, %Pagination.Cursor{inner: inner}} <-
           Pagination.decode_cursor(
             raw,
             @platform_events_cursor_prefix,
             byte_size(@platform_events_cursor_prefix)
           ),
         {:ok, seek} <- platform_events_seek_from_cursor(inner) do
      {:ok, seek}
    else
      _invalid_base64_or_wrong_endpoint_or_expired_or_invalid_cursor ->
        {:error, :invalid_cursor}
    end
  end

  # Raw payload is "PE:<mint_time_us>:<sequence_num>:<event_id>", matching
  # Routers.Audit's own "<prefix>:<mint_time_us>:<...>" layout -- the only
  # place this cursor's internal layout is interpreted.
  defp platform_events_seek_from_cursor(inner) do
    with mint_colon when not is_nil(mint_colon) <- Pagination.find_nth_colon(inner, 2),
         seq_colon when not is_nil(seq_colon) <- Pagination.find_nth_colon(inner, 3),
         {:ok, sequence_num} <-
           Pagination.parse_int_from_cursor(inner, mint_colon + 1, seq_colon - mint_colon - 1),
         event_id <- binary_part(inner, seq_colon + 1, byte_size(inner) - seq_colon - 1),
         {:ok, _} <- Ecto.UUID.cast(event_id) do
      {:ok, {sequence_num, event_id}}
    else
      _invalid ->
        {:error, :invalid_cursor}
    end
  end

  defp non_empty_platform_event_type(nil), do: nil
  defp non_empty_platform_event_type(""), do: nil
  defp non_empty_platform_event_type(value) when is_binary(value), do: value

  # -- Response allowlist (INV-2) --
  # Per-event-type payload allowlist for a NON-operator reader of R11
  # (lib/letflow/design/iss0999-platform-events-allowlist.md, INV-10): a
  # promotion event written at a target tenant carries identifiers of other
  # tenants' schemas, so the shaping is an ALLOWLIST, not a key-pattern deny.
  # `plain` keys are kept when their value is a scalar; `own_tenant` keys are
  # kept only when the value is the caller's own tenant id. Everything else
  # (notably source_definition_id, review_id, teardown `error`) is omitted.
  # An event type with no entry here gets payload %{} (event kept).
  @platform_event_allowlist %{
    "DEFINITION_PROMOTED" => %{
      plain: ["target_definition_id", "process_key"],
      own_tenant: ["source_tenant_id", "target_tenant_id"]
    },
    "DEFINITION_VERSION_ROLLED_BACK" => %{
      plain: ["process_key", "from_version", "to_version"],
      own_tenant: []
    },
    "PROMOTION_ASSERTION_TEARDOWN_FAILED" => %{
      plain: ["run_id", "sandbox_id"],
      own_tenant: ["tenant_id"]
    }
  }

  # Test seam for the registry-drift test only (ISS-0999 T-9).
  @doc false
  @spec platform_event_allowlist() :: %{
          String.t() => %{plain: [String.t()], own_tenant: [String.t()]}
        }
  def platform_event_allowlist, do: @platform_event_allowlist

  # Hand-built allowlist (design §2.6), same discipline as Routers.Audit's
  # audit_item/1 -- never a raw struct/Jason.Encoder derivation. A non-operator
  # item has no `actor_id` key (the actor may be a user of another tenant).
  @spec platform_event_map(EventStore.platform_event_item(), tenant_view()) :: map()
  defp platform_event_map(item, view) do
    base = %{
      "event_id" => item.event_id,
      "event_type" => item.event_type,
      "timestamp" => iso8601(item.timestamp),
      "sequence_num" => item.sequence_num,
      "payload" => shape_platform_event_payload(item.payload, item.event_type, view)
    }

    case view do
      :operator -> Map.put(base, "actor_id", item.actor_id)
      {:tenant, _own} -> base
    end
  end

  # Operator: unchanged. Non-operator: exactly the allowlisted keys that pass
  # the value rules; %{} for an unknown type, a non-map payload or the `$ref`
  # oversized form. No recursion: a map or list value is omitted (fail closed).
  @spec shape_platform_event_payload(term(), String.t(), tenant_view()) :: term()
  defp shape_platform_event_payload(payload, _event_type, :operator), do: payload

  defp shape_platform_event_payload(payload, event_type, {:tenant, own})
       when is_map(payload) and not is_struct(payload) do
    case Map.fetch(@platform_event_allowlist, event_type) do
      {:ok, %{plain: plain, own_tenant: own_keys}} ->
        Enum.reduce(payload, %{}, fn {key, val}, acc ->
          cond do
            key in plain and scalar?(val) -> Map.put(acc, key, val)
            key in own_keys and own_tenant_value?(val, own) -> Map.put(acc, key, val)
            true -> acc
          end
        end)

      :error ->
        %{}
    end
  end

  defp shape_platform_event_payload(_payload, _event_type, {:tenant, _own}), do: %{}

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  # ── INV-10 response shaping (REQ-446) ────────────────────────────────────

  # Who is reading, as far as tenant ids go: a platform-tenant operator sees
  # everything; anyone else may see only its own tenant id (nil = none at all).
  # Recomputed from `auth_context` via `PlatformTenant.scope_facts_for/1`
  # (the stored flag is never read, nothing comes from the request).
  @typep tenant_view :: :operator | {:tenant, String.t() | nil}

  @spec tenant_view(Plug.Conn.t()) :: tenant_view()
  defp tenant_view(conn) do
    auth_context = Map.get(conn.assigns, :auth_context)

    if PlatformTenant.scope_facts_for(auth_context).platform_scope? do
      :operator
    else
      own = if is_map(auth_context), do: Map.get(auth_context, :tenant_id)
      {:tenant, if(is_binary(own), do: own)}
    end
  end

  # -- Response allowlist (INV-2) --
  # Top-level key allowlist for the `serialised_plan` a NON-operator reads on
  # GET /promotions/:id/context (lib/letflow/design/iss1021-context-plan-allowlist.md,
  # INV-10). `plain` keys are kept when scalar; `own_tenant` keys only when the
  # value is the caller's own tenant id; `own_side` definition ids (key =>
  # gating tenant-id key) only when scalar AND the gating tenant id is the
  # caller's own; `entries` is kept only when it is a list AND every
  # `entries_gate` tenant id is the caller's own (ISS-1023, INV-10), else `[]`.
  # Every other top-level key is omitted.
  @plan_allowlist %{
    plain: ["process_key", "base_version"],
    own_tenant: ["source_tenant_id", "target_tenant_id"],
    own_side: %{
      "source_definition_id" => "source_tenant_id",
      "target_definition_id" => "target_tenant_id"
    },
    entries: "entries",
    entries_gate: ["source_tenant_id", "target_tenant_id"]
  }

  # Test seam for the allowlist drift test only (ISS-1021 T-12).
  @doc false
  @spec plan_allowlist() :: %{
          plain: [String.t()],
          own_tenant: [String.t()],
          own_side: %{String.t() => String.t()},
          entries: String.t(),
          entries_gate: [String.t()]
        }
  def plan_allowlist, do: @plan_allowlist

  # Operator: the decoded plan, unchanged (any shape). Non-operator: always a
  # NEW hand-built map from the allowlist, never the input value; a non-map
  # plan yields %{"entries" => []}; `entries` is always present as a list.
  @spec shape_plan(term(), tenant_view()) :: term()
  defp shape_plan(plan, :operator), do: plan

  defp shape_plan(plan, {:tenant, own}) when is_map(plan) and not is_struct(plan) do
    %{plain: plain, own_tenant: own_keys, own_side: own_side, entries: entries_key} =
      @plan_allowlist

    base =
      Enum.reduce(plain, %{}, fn key, acc ->
        case Map.fetch(plan, key) do
          {:ok, val} -> if scalar?(val), do: Map.put(acc, key, val), else: acc
          :error -> acc
        end
      end)

    base =
      Enum.reduce(own_keys, base, fn key, acc ->
        case Map.fetch(plan, key) do
          {:ok, val} -> if own_tenant_value?(val, own), do: Map.put(acc, key, val), else: acc
          :error -> acc
        end
      end)

    base =
      Enum.reduce(own_side, base, fn {def_key, tenant_key}, acc ->
        with {:ok, def_val} <- Map.fetch(plan, def_key),
             true <- scalar?(def_val),
             {:ok, tenant_val} <- Map.fetch(plan, tenant_key),
             true <- own_tenant_value?(tenant_val, own) do
          Map.put(acc, def_key, def_val)
        else
          _ -> acc
        end
      end)

    entries =
      case Map.get(plan, entries_key) do
        list when is_list(list) -> if entries_visible?(plan, own), do: list, else: []
        _other -> []
      end

    Map.put(base, entries_key, entries)
  end

  defp shape_plan(_plan, {:tenant, _own}), do: %{"entries" => []}

  # ISS-1023 (INV-10): `entries` mixes both sides' graph content, so it is
  # shown only when EVERY gate key's stored value is the caller's own tenant id
  # (all-or-nothing; a missing or non-binary value fails closed).
  @spec entries_visible?(map(), String.t() | nil) :: boolean()
  defp entries_visible?(plan, own) do
    Enum.all?(@plan_allowlist.entries_gate, fn key ->
      case Map.fetch(plan, key) do
        {:ok, val} -> own_tenant_value?(val, own)
        :error -> false
      end
    end)
  end

  defp own_tenant_value?(value, own) when is_binary(value) and is_binary(own),
    do: String.downcase(value) == String.downcase(own)

  defp own_tenant_value?(_value, _own), do: false

  # ── GET /promotions -- R12, review-queue list (design §4) ───────────────

  @spec handle_list_reviews(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_list_reviews(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params
    opts = conn.assigns.scoped_opts

    with {:ok, status_filter} <- parse_status_filter_param(Map.get(query, "status")),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      filters = %{
        status: status_filter,
        def_id: non_empty(Map.get(query, "def_id")),
        def_type: non_empty(Map.get(query, "def_type")),
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      # ISS-1029: a non-operator never sees a review of which they are not a
      # named party (omitted, no placeholder); the operator path passes no
      # predicate (unchanged).
      store_opts =
        case tenant_view(conn) do
          :operator ->
            opts

          _non_operator ->
            Keyword.put(opts, :row_visible?, &(review_read_access(conn, &1) != :none))
        end

      render_list_reviews(conn, PromotionReviewStore.list_reviews(filters, store_opts))
    else
      {:error, :invalid_status} ->
        Response.bad_request(
          conn,
          "status must be one or more of (comma-separated): pending_review, approved, rejected, applied, failed, superseded"
        )

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  defp render_list_reviews(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &promotion_review_list_item_map/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_reviews(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_list_reviews(conn, {:error, :wrong_endpoint}),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  defp render_list_reviews(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  # Includes {:error, :invalid_schema_name} (design §3.2) -- not explicitly
  # branched on, matching Routers.Definitions's own render_list_result/2
  # unmapped-error catch-all precedent.
  defp render_list_reviews(conn, {:error, _other}), do: Response.internal_error(conn)

  # `status` accepts one or more comma-separated values (design §4.3) -- a
  # single query param, not repeated `status=` params or `status[]=`
  # bracket-array syntax (see the design doc for why). `nil`/`""` and an
  # all-empty-after-split value (`?status=` or `?status=,,`) both mean "no
  # filter." Any single unrecognised piece rejects the WHOLE filter, never
  # silently reducing it to the valid subset.
  @spec parse_status_filter_param(String.t() | nil) ::
          {:ok, [PromotionReview.status()] | nil} | {:error, :invalid_status}
  defp parse_status_filter_param(nil), do: {:ok, nil}
  defp parse_status_filter_param(""), do: {:ok, nil}

  defp parse_status_filter_param(raw) when is_binary(raw) do
    pieces =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case pieces do
      [] -> {:ok, nil}
      _ -> parse_status_pieces(pieces, [])
    end
  end

  defp parse_status_pieces([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_status_pieces([piece | rest], acc) do
    case status_filter_atom(piece) do
      {:ok, atom} -> parse_status_pieces(rest, [atom | acc])
      :error -> {:error, :invalid_status}
    end
  end

  defp status_filter_atom("pending_review"), do: {:ok, :pending_review}
  defp status_filter_atom("approved"), do: {:ok, :approved}
  defp status_filter_atom("rejected"), do: {:ok, :rejected}
  defp status_filter_atom("applied"), do: {:ok, :applied}
  defp status_filter_atom("failed"), do: {:ok, :failed}
  defp status_filter_atom("superseded"), do: {:ok, :superseded}
  defp status_filter_atom(_other), do: :error

  # Same "empty string == absent filter" idiom tasks.ex's own list handler
  # already uses (design §4.2) -- this module does not currently define
  # non_empty/1; every router file that needs it defines its own copy
  # rather than importing a shared helper.
  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # 7-key allowlist, in this exact order (design §4.5). Deliberately
  # excludes plan_digest/serialised_plan/approved_by/approved_at/
  # superseded_by/row_version -- none is named in REQ-397's acceptance
  # criteria, and a reviewer who needs any of them already has
  # GET /promotions/:id/context (R4) one click away via this row's own id.
  @spec promotion_review_list_item_map(PromotionReview.t()) :: map()
  defp promotion_review_list_item_map(review) do
    %{
      "id" => review.id,
      "status" => Atom.to_string(review.status),
      "def_type" => review.def_type,
      "def_id" => review.def_id,
      "requested_by" => review.requested_by,
      "inserted_at" => iso8601(review.inserted_at),
      "updated_at" => iso8601(review.updated_at)
    }
  end

  # ── Shared helpers ────────────────────────────────────────────────────

  # Single-atom 409 rule (design §6.1) -- one status, one type, one detail,
  # for EVERY illegal state transition on R5/R6/R7 alike. Never names the
  # row's actual status.
  defp invalid_transition_response(conn),
    do: Response.conflict(conn, "review is not in a state that permits this transition")

  # Path-parameter UUID pre-validation (design §3.2) -- required ahead of
  # `PromotionReviewStore.approve_review/4`/`reject_review/3` (whose shared
  # `transition/6` mechanism receives the id as a plain `:binary_id` lookup
  # with no defensive cast of its own) and ahead of
  # `Definitions.apply_promotion_assertion_rerun/6` (design §11 OQ-10 --
  # confirmed here: it takes `review_id` as a plain binary into a changeset
  # with an FK, with no defensive cast either). A non-UUID path segment would
  # otherwise raise `Ecto.Query.CastError`/surface as an FK violation instead
  # of the 404 INV-5 requires -- malformed and nonexistent must be the same
  # fact from the caller's side. `get_review/2` and
  # `get_latest_assertion_run/2` (used by R3/R4/R7) already cast internally,
  # so this helper is not called before those.
  @spec cast_review_id(String.t()) :: {:ok, Ecto.UUID.t()} | {:error, :not_uuid}
  defp cast_review_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_uuid}
    end
  end

  # `PromotionReview` (see `Letflow.Definitions.PromotionReview`) declares
  # `timestamps(type: :utc_datetime_usec)`, so `inserted_at`/`updated_at`
  # are `%DateTime{}` at runtime, not `%NaiveDateTime{}` -- unlike
  # `Letflow.Routers.Tenants`' own `iso8601/1`, which only ever sees
  # `%NaiveDateTime{}` because its schema's timestamps aren't UTC-typed.
  # A `%DateTime{}` is already UTC-anchored, so it goes straight to
  # `DateTime.to_iso8601/1` with no naive->UTC conversion step.
  defp iso8601(%DateTime{} = utc), do: DateTime.to_iso8601(utc)

  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
