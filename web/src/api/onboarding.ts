/** Onboarding API — tenant registration
 *  Covers: ONB-UI-01..04, ISS-1030 (administrator / realm display)
 *  All calls go through client.ts per frontend conventions.
 *  Idempotency-Key is injected per-call by submitOnboarding (not by client.ts globally).
 */

import { client } from './client'
import type { ApiError } from '@/types/api'

// ── Types ──────────────────────────────────────────────────────────────────────

export interface OnboardingFormValues {
  slug: string
  display_name: string
  /** Optional (ISS-1030): blank after trim is omitted from the request. */
  admin_email?: string
  hostname: string
  /** Optional (ISS-1030): blank after trim is omitted from the request. */
  idp_realm_id?: string
}

export interface OnboardingSubmitRequest {
  slug: string
  display_name: string
  // ISS-1030: these two are OMITTED (never sent as '' or null) when blank.
  admin_email?: string
  idp_realm_id?: string
  hostname: string
}

// ── Wire shape of the synchronous backend (ISS-1030) ──────────────────────────
// lib/letflow/routers/onboarding.ex: POST /onboarding answers 201 with the
// onboarding record plus `login`, `administrator`, `ignored_fields`;
// GET /onboarding/:id, GET /onboarding?hostname= and POST /:id/bind-realm
// answer the record plus `login`. These types mirror the wire; pages consume
// them directly (no adapter). The backend never emits a saga `state`, a
// `failed` outcome or an `onboarding_id` key -- the identifier is `id`.

export interface OnboardingLogin {
  loginable: boolean
  status: 'realm_bound' | 'not_yet_loginable'
  idp_realm_id: string | null
  next_steps: string[]
}

export interface OnboardingAdministratorField {
  field: string
  /** Present only when the server echoed a string of at most 255 characters. */
  value?: string
}

/**
 * `none`: no administrator e-mail was sent; `pending`: the e-mail is stored as
 * a pending TENANT_ADMIN grant (`grant_id` present); `not_stored`: the e-mail
 * was sent but the grant could not be stored; `not_provisioned`: legacy state
 * of the first PR, still rendered when received.
 */
export type OnboardingAdministratorState =
  | 'none'
  | 'pending'
  | 'not_stored'
  | 'not_provisioned'

export interface OnboardingAdministrator {
  state: OnboardingAdministratorState
  /** Present only when `state` is `pending`. */
  grant_id?: string
  message: string
  not_provisioned: OnboardingAdministratorField[]
  next_steps: string[]
}

export interface OnboardingRecord {
  id: string
  tenant_id: string
  slug: string
  hostname: string
  created_at: string
  login?: OnboardingLogin
  /** 201 body only. */
  administrator?: OnboardingAdministrator
  /** 201 body only: names (never values) of request keys the server did not use. */
  ignored_fields?: string[]
}

// ── Error class ────────────────────────────────────────────────────────────────

export class OnboardingApiError extends Error {
  constructor(
    public readonly httpStatus: number,
    public readonly body: Record<string, unknown>,
  ) {
    super(`Onboarding API error: HTTP ${httpStatus}`)
    this.name = 'OnboardingApiError'
  }
}

// ── API helpers ────────────────────────────────────────────────────────────────

/** Convert an ApiError into OnboardingApiError for caller taxonomy handling. */
function toOnboardingApiError(err: unknown): OnboardingApiError {
  const apiErr = err as ApiError
  const rawDetails: unknown = apiErr.details
  // A 422 carries its field errors as an array under `errors`.
  const details: Record<string, unknown> = Array.isArray(rawDetails)
    ? { errors: rawDetails }
    : ((rawDetails ?? {}) as Record<string, unknown>)
  return new OnboardingApiError(apiErr.status ?? 500, {
    ...details,
    ...(!details['error'] && apiErr.code ? { error: apiErr.code } : {}),
    ...(!details['title'] && apiErr.message ? { title: apiErr.message } : {}),
  })
}

function nonBlank(value: string | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed ? trimmed : undefined
}

/**
 * Constraint name of the server's field error for `field` in a 422 body, if
 * any. Only the constraint is read, never a received value.
 */
export function fieldErrorConstraint(
  body: Record<string, unknown>,
  field: string,
): string | undefined {
  const errors = body['errors']
  if (!Array.isArray(errors)) return undefined
  for (const e of errors) {
    if (e && typeof e === 'object' && (e as Record<string, unknown>)['field'] === field) {
      const c = (e as Record<string, unknown>)['constraint']
      return typeof c === 'string' ? c : 'invalid'
    }
  }
  return undefined
}

// ── Public API ─────────────────────────────────────────────────────────────────

/**
 * POST /api/v1/onboarding
 * Injects the provided idempotencyKey as the Idempotency-Key header.
 * Throws OnboardingApiError on non-201 responses so callers can inspect the
 * status and body for the error taxonomy (section 9.2).
 */
export async function submitOnboarding(
  formValues: OnboardingFormValues,
  idempotencyKey: string,
): Promise<OnboardingRecord> {
  const adminEmail = nonBlank(formValues.admin_email)
  const realmId = nonBlank(formValues.idp_realm_id)

  const body: OnboardingSubmitRequest = {
    slug: formValues.slug,
    display_name: formValues.display_name,
    ...(adminEmail ? { admin_email: adminEmail } : {}),
    ...(realmId ? { idp_realm_id: realmId } : {}),
    hostname: formValues.hostname,
  }

  return client
    .postWithHeaders<OnboardingRecord>('/api/v1/onboarding', body, {
      'Idempotency-Key': idempotencyKey,
    })
    .catch((err: unknown) => {
      throw toOnboardingApiError(err)
    })
}

/**
 * GET /api/v1/onboarding/:onboardingId
 * Returns the onboarding record (with `login`). Throws on non-2xx responses.
 */
export async function getOnboarding(onboardingId: string): Promise<OnboardingRecord> {
  return client.get<OnboardingRecord>(`/api/v1/onboarding/${encodeURIComponent(onboardingId)}`)
}

/**
 * GET /api/v1/onboarding?hostname=<hostname>
 * Returns the record for the given hostname. Throws on non-2xx (404 = not found).
 */
export async function getOnboardingByHostname(hostname: string): Promise<OnboardingRecord> {
  return client.get<OnboardingRecord>('/api/v1/onboarding', { hostname })
}

/**
 * POST /api/v1/onboarding/:onboardingId/bind-realm  (ISS-1030, bind-once)
 * The server validates, checks the realm with the identity provider and is
 * authoritative; this only sends the trimmed value. Throws OnboardingApiError.
 */
export async function bindRealm(
  onboardingId: string,
  idpRealmId: string,
): Promise<OnboardingRecord> {
  return client
    .post<OnboardingRecord>(
      `/api/v1/onboarding/${encodeURIComponent(onboardingId)}/bind-realm`,
      { idp_realm_id: idpRealmId.trim() },
    )
    .catch((err: unknown) => {
      throw toOnboardingApiError(err)
    })
}
