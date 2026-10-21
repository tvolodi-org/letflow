import { client } from './client'
import type { CursorPage } from '@/types/api'

// ── Promotion Review types (PRM-02 – PRM-05) ──────────────────────────────────

/** Plan entry shape — canonical JSON object keys sorted lexicographically */
export interface PlanEntry {
  type: string
  id: string
  change_kind: 'added' | 'modified' | 'removed'
  before: string | null
  after: string | null
}

/** Promotion plan — array of plan entries */
export interface PromotionPlan {
  entries: PlanEntry[]
}

/** Conflict item inside a PROMOTION_CONFLICT response */
export interface PromotionConflictItem {
  process_key: string
  target_definition_id: string
  target_version: number
  source_change: string
  target_change: string
}

/** HTTP 409 PROMOTION_CONFLICT response body */
export interface PromotionConflictError {
  error: 'PROMOTION_CONFLICT'
  message: string
  conflicts: PromotionConflictItem[]
}

/** HTTP 409 PLAN_DIGEST_MISMATCH response body */
export interface PlanDigestMismatchError {
  error: 'PLAN_DIGEST_MISMATCH'
  message: string
}

/** HTTP 403 SELF_APPROVAL_FORBIDDEN response body */
export interface SelfApprovalForbiddenError {
  error: 'SELF_APPROVAL_FORBIDDEN'
  message: string
}

/** HTTP 400 INVALID_REVIEW_TRANSITION response body */
export interface InvalidReviewTransitionError {
  error: 'INVALID_REVIEW_TRANSITION'
  message: string
}

/** Review status — six-state promotion review state machine (PRM-04) */
export type ReviewStatus =
  | 'pending_review'
  | 'approved'
  | 'rejected'
  | 'applied'
  | 'failed'
  | 'superseded'

/** Stored promotion review record (PRM-04) */
export interface PromotionReview {
  id: string
  tenant_id: string
  plan_digest: string
  def_type: string
  def_id: string
  serialised_plan: string
  status: ReviewStatus
  requested_by: string
  approved_by: string | null
  approved_at: string | null
  superseded_by: string | null
  row_version: number
  created_at: string
  updated_at: string
}

/** GET /api/v1/promotions/{id}/context response */
export interface PromotionContext {
  review: PromotionReview
  /** Parsed serialised_plan — canonical JSON */
  plan: PromotionPlan
  /** Human-readable digest verification status */
  digest_verified: boolean
  /** NEEDS_REVIEW package artifact assertions */
  assertions: Array<{
    artifact_id: string
    assertion_type: string
    passed: boolean
  }>
}

/**
 * ISS-0731: the raw wire shape `GET /api/v1/promotions/{id}/context` actually
 * returns — `Letflow.Routers.Promotions.review_context_map/1`'s documented
 * "exactly 9 keys" (that moduledoc comment, §"GET /promotions/:id/context"),
 * confirmed live against a real review on 2026-09-20. It is FLAT (no nested
 * `review`/`plan` objects), has no `tenant_id`/`approved_by`/`approved_at`/
 * `superseded_by`/`updated_at` (`promotion_reviews` never grew those columns
 * on this port — REQ-064/Decision-0006-D2 dropped `tenant_id`; the others
 * were never added), and `serialised_plan` is already a decoded JSON object
 * (`Jason.decode!/1`'d by the handler), not the raw string the frontend
 * `PromotionReview.serialised_plan: string` field name implies. This is the
 * actual, unadapted backend response — `getContext` below maps it onto the
 * `PromotionContext` shape the already-built review components expect,
 * rather than changing those components (see ISS-0731 for the full
 * incident: the previous, never-exercised assumption crashed every real
 * promotion-review page load with "Cannot read properties of undefined").
 */
interface RawPromotionContext {
  review_id: string
  plan_digest: string
  serialised_plan: { entries: PlanEntry[] } & Record<string, unknown>
  status: ReviewStatus
  requested_by: string
  def_type: string
  def_id: string
  created_at: string
  row_version: number
}

/**
 * Adapts the real, flat backend response (`RawPromotionContext`) onto the
 * `PromotionContext` shape `PromotionReviewStateMachine`/`PlanDigestView`/
 * `NonSkippableApprovalGate` already consume (ISS-0731).
 *
 * Two fields have no backend source and are filled with a documented,
 * honest default rather than guessed:
 *   - `digest_verified: true` — this endpoint has nothing to compare the
 *     stored digest against; it simply returns the one digest of record.
 *     "Mismatch" is only a meaningful concept at write time (approve/apply's
 *     own 409 `PLAN_DIGEST_MISMATCH`), never at this read.
 *   - `assertions: []` — per-artifact assertion items are not part of this
 *     endpoint's response at all; the closest backend data is
 *     `GET /api/v1/promotions/{id}` (R3)'s aggregate `assertion_run` (pass/
 *     fail counts, not a per-artifact list) — a structurally different
 *     shape, out of scope for this crash fix (tracked separately).
 */
function adaptPromotionContext(raw: RawPromotionContext): PromotionContext {
  const review: PromotionReview = {
    id: raw.review_id,
    tenant_id: '',
    plan_digest: raw.plan_digest,
    def_type: raw.def_type,
    def_id: raw.def_id,
    serialised_plan: JSON.stringify(raw.serialised_plan),
    status: raw.status,
    requested_by: raw.requested_by,
    approved_by: null,
    approved_at: null,
    superseded_by: null,
    row_version: raw.row_version,
    created_at: raw.created_at,
    updated_at: raw.created_at,
  }
  return {
    review,
    plan: { entries: raw.serialised_plan.entries },
    digest_verified: true,
    assertions: [],
  }
}

/**
 * REQ-398 §2.1 — `GET /api/v1/promotions` filters. `status` is deliberately
 * a single value, not REQ-397's full comma-separated multi-status capability
 * — see design doc §5.2 for why (AC3's wording names one selected status).
 */
export interface PromotionReviewListFilters {
  status?: ReviewStatus
  def_id?: string
  def_type?: string
  cursor?: string
  page_size?: number
}

/**
 * REQ-398 §2.1 — `GET /api/v1/promotions` response item. A direct,
 * unadapted match to `Letflow.Routers.Promotions.promotion_review_list_item_map/1`'s
 * live 7-key response allowlist — no `Raw*` interface/adapter needed, unlike
 * `getContext` below (ISS-0731), because REQ-397's own AC5 named these exact
 * field names and the router confirms them verbatim.
 */
export interface PromotionReviewListItem {
  id: string
  status: ReviewStatus
  def_type: string
  def_id: string
  requested_by: string
  inserted_at: string
  updated_at: string
}

/** POST /api/v1/promotions/{id}/approve body */
export interface ApprovePromotionRequest {
  plan_digest: string
  approved_by: string
}

/** POST /api/v1/promotions/{id}/apply body */
export interface ApplyPromotionRequest {
  plan_digest: string
}

// ── API client ─────────────────────────────────────────────────────────────────

export const promotionsApi = {
  /**
   * GET /api/v1/promotions/{reviewId}/context
   * Returns the stored plan, digest, and review context for a given review.
   */
  getContext: (reviewId: string) =>
    client
      .get<RawPromotionContext>(`/api/v1/promotions/${reviewId}/context`)
      .then(adaptPromotionContext),

  /**
   * POST /api/v1/promotions/{reviewId}/approve
   * Approves a pending promotion review.
   * Gate: approved_by != requested_by (HTTP 403), status == pending_review (HTTP 400),
   *       plan_digest matches stored (HTTP 409).
   */
  approve: (reviewId: string, body: ApprovePromotionRequest) =>
    client.post<void>(`/api/v1/promotions/${reviewId}/approve`, body),

  /**
   * POST /api/v1/promotions/{reviewId}/reject
   * Rejects a pending promotion review.
   * Gate: status == pending_review (HTTP 400).
   */
  reject: (reviewId: string) =>
    client.post<void>(`/api/v1/promotions/${reviewId}/reject`, {}),

  /**
   * POST /api/v1/promotions/{reviewId}/apply
   * Applies an approved promotion.
   * Gate: status == approved (HTTP 400), plan_digest matches stored (HTTP 409).
   * No bypass parameter — non-skippable gate (PRM-05 AC3).
   */
  apply: (reviewId: string, body: ApplyPromotionRequest) =>
    client.post<void>(`/api/v1/promotions/${reviewId}/apply`, body),

  /**
   * GET /api/v1/promotions (REQ-397, platform-admin role-only)
   * Lists promotion-review rows, filterable by status/def_id/def_type,
   * cursor-paginated. REQ-397's envelope is exactly `{items, next_cursor}`
   * (design doc §2.2, hand-built response — no `count` field emitted).
   */
  list: (filters: PromotionReviewListFilters): Promise<CursorPage<PromotionReviewListItem>> =>
    client
      .get<{ items: PromotionReviewListItem[]; next_cursor: string | null }>('/api/v1/promotions', {
        status: filters.status,
        def_id: filters.def_id,
        def_type: filters.def_type,
        cursor: filters.cursor,
        page_size: filters.page_size ? String(filters.page_size) : undefined,
      })
      .then((response) => ({
        items: response.items,
        next_cursor: response.next_cursor,
        // count not sent by render_list_reviews/2 (hand-built response, not Pagination.page_response)
      })),
}
