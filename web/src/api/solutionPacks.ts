/** solutionPacks — REQ-381: solution-pack update-review/apply API client.
 *
 *  Dedicated small module (matches `definitionRollback.ts`/`promotions.ts`'s
 *  own precedent of one small API module per distinct backend concern). Wire
 *  shapes mirror REQ-380's real response/request shapes exactly (INV-2
 *  discipline applies to the frontend too — no field this screen doesn't
 *  name) — see `lib/letflow/design/req381-solution-pack-update-review-screen.md`
 *  §3 and `lib/letflow/routers/solution_packs.ex:181-187,375-573`.
 */

import { client } from './client'

export type PackArtefactClassification =
  | 'unchanged'
  | 'safe_to_update'
  | 'local_only'
  | 'both_sides_conflict'

export type PackUpdateAction = 'advanced_to_incoming' | 'advanced_to_merged' | 'left_unchanged'

export type PackResolutionChoice = 'keep_local' | 'take_incoming' | 'merged'

export interface PackArtefactInput {
  artefact_type: string
  artefact_id: string
  content: string
}

export interface PackUpdateReviewRequest {
  target_version: string
  theirs_artefacts: PackArtefactInput[]
  incoming_artefacts: PackArtefactInput[]
}

export interface PackUpdateReviewEntry {
  artefact_type: string
  artefact_id: string
  classification: PackArtefactClassification
  resolved: boolean
}

export interface PackUpdateReviewResponse {
  pack_id: string
  target_version: string
  entries: PackUpdateReviewEntry[]
  has_unresolved_conflicts: boolean
}

export interface PackResolutionInput {
  artefact_type: string
  artefact_id: string
  resolution: PackResolutionChoice
  resolved_content: string | null
}

export interface PackUpdateApplyRequest extends PackUpdateReviewRequest {
  resolutions: PackResolutionInput[]
}

export interface PackUpdateAppliedEntry {
  artefact_type: string
  artefact_id: string
  classification: PackArtefactClassification
  action: PackUpdateAction
}

export interface PackUpdateApplyResponse {
  pack_id: string
  target_version: string
  applied_entries: PackUpdateAppliedEntry[]
  resolutions_recorded: number
}

/**
 * Parses the 409 detail string `update-apply` names an unresolved conflict
 * with: "unresolved conflict on artefact_type=<type> artefact_id=<id>"
 * (`lib/letflow/routers/solution_packs.ex:555-562`). Mirrors
 * `DefinitionRollbackPage.tsx`'s own `classifyRollbackError` convention of
 * reading `err.details.detail` (the RFC 9457 problem document's `detail`
 * field, preserved by `client.ts`'s error mapping) via exact-shape regex,
 * never `err.message`.
 */
const UNRESOLVED_CONFLICT_DETAIL_RE =
  /unresolved conflict on artefact_type=(\S+) artefact_id=(\S+)/

export function parseUnresolvedConflictDetail(
  detail: string | undefined,
): { artefactType: string; artefactId: string } | null {
  if (!detail) return null
  const match = UNRESOLVED_CONFLICT_DETAIL_RE.exec(detail)
  if (!match) return null
  return { artefactType: match[1], artefactId: match[2] }
}

export type PackOverrideStatus = 'active' | 'retired' | 'orphaned'

export interface PackOverride {
  override_id: string
  override_version: number
  pack_id: string
  artefact_type: string
  artefact_id: string
  made_against: string
  status: PackOverrideStatus
  reason: string
  created_by: string
  inserted_at: string
  patch: Record<string, unknown>
}

export interface PackOverrideListResponse {
  overrides: PackOverride[]
}

export interface PackOverrideCreateRequest {
  artefact_type: string
  artefact_id: string
  patch: Record<string, unknown>
  reason: string
}

export interface PackOverrideVersionRequest {
  patch: Record<string, unknown>
  reason: string
  base_version?: number
}

export interface PackOverrideRetireRequest {
  reason: string
  base_version?: number
}

export const solutionPacksApi = {
  updateReview: (packId: string, body: PackUpdateReviewRequest) =>
    client.post<PackUpdateReviewResponse>(
      `/api/v1/solution-packs/${encodeURIComponent(packId)}/update-review`,
      body,
    ),

  updateApply: (packId: string, body: PackUpdateApplyRequest) =>
    client.post<PackUpdateApplyResponse>(
      `/api/v1/solution-packs/${encodeURIComponent(packId)}/update-apply`,
      body,
    ),

  /** REQ-596 / REQ-631 — per-tenant overrides; the tenant comes from the session, never the request. */
  listOverrides: (packId: string) =>
    client.get<PackOverrideListResponse>(
      `/api/v1/solution-packs/${encodeURIComponent(packId)}/overrides`,
    ),

  createOverride: (packId: string, body: PackOverrideCreateRequest) =>
    client.post<PackOverride>(`/api/v1/solution-packs/${encodeURIComponent(packId)}/overrides`, body),

  newOverrideVersion: (packId: string, overrideId: string, body: PackOverrideVersionRequest) =>
    client.post<PackOverride>(
      `/api/v1/solution-packs/${encodeURIComponent(packId)}/overrides/${encodeURIComponent(overrideId)}/versions`,
      body,
    ),

  retireOverride: (packId: string, overrideId: string, body: PackOverrideRetireRequest) =>
    client.post<PackOverride>(
      `/api/v1/solution-packs/${encodeURIComponent(packId)}/overrides/${encodeURIComponent(overrideId)}/retire`,
      body,
    ),

  /**
   * Existing generic definitions endpoint (`GET /api/v1/definitions/:id`),
   * reused (not new) — sources `theirs_artefacts` (design §2). Returns the
   * decoded graph object, NOT a canonical string — the caller runs it
   * through `canonicalizeArtefactContent` before placing it in
   * `theirs_artefacts[].content`. A 404 (tenant never had this artefact) is
   * treated as "no theirs content" — resolves to `null`, per design §2 —
   * rather than throwing, since the launcher's fan-out loop must continue
   * past a genuinely-absent artefact.
   */
  fetchTenantArtefactGraph: async (
    artefactId: string,
  ): Promise<{ graph: Record<string, unknown> } | null> => {
    try {
      const definition = await client.get<{ graph: Record<string, unknown> }>(
        `/api/v1/definitions/${encodeURIComponent(artefactId)}`,
      )
      return { graph: definition.graph }
    } catch (err) {
      if (err && typeof err === 'object' && 'status' in err && (err as { status: number }).status === 404) {
        return null
      }
      throw err
    }
  },
}
