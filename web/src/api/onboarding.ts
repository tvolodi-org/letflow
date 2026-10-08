/** Onboarding API — tenant registration
 *  Covers: ONB-UI-01..04, ISS-1030 (administrator / realm display)
 *  All calls go through client.ts per frontend conventions.
 *  Idempotency-Key is injected per-call by submitOnboarding (not by client.ts globally).
 */

import { client } from './client'
import type { ApiError } from '@/types/api'

// ── Types ──────────────────────────────────────────────────────────────────────

export interface RealmConfig {
  default_token_lifetime_seconds?: number
  min_password_length?: number
  require_uppercase?: boolean
  require_digit?: boolean
  signing_key_algorithm?: string
}

export interface ClientConfig {
  redirect_uris: string[]
  service_account_enabled?: boolean
}

export interface OnboardingFormValues {
  slug: string
  display_name: string
  /** Optional (ISS-1030): blank after trim is omitted from the request. */
  admin_email?: string
  admin_username?: string
  admin_display_name?: string
  hostname: string
  redirect_uris: string[]
  /** Optional (ISS-1030): blank after trim is omitted from the request. */
  idp_realm_id?: string
  realm_config?: RealmConfig
  client_config?: Omit<ClientConfig, 'redirect_uris'>
}

export interface OnboardingSubmitRequest {
  slug: string
  display_name: string
  // ISS-1030: these four are OMITTED (never sent as '' or null) when blank.
  admin_email?: string
  admin_username?: string
  admin_display_name?: string
  idp_realm_id?: string
  hostname: string
  client_config: ClientConfig
  realm_config?: RealmConfig
}

// ── Wire shape of the synchronous backend (ISS-1030) ──────────────────────────
// lib/letflow/routers/onboarding.ex: POST /onboarding answers 201 with the
// onboarding record plus `login`, `administrator`, `ignored_fields`;
// GET /onboarding/:id, GET /onboarding?hostname= and POST /:id/bind-realm
// answer the record plus `login`.

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

export interface OnboardingAdministrator {
  state: string
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

export type OnboardingState = 'pending' | 'completed' | 'failed'

export interface OnboardingStatusPending {
  state: 'pending'
}

export interface OnboardingStatusCompleted {
  state: 'completed'
  onboarding_id: string
  tenant_id: string
  hostname: string
  slug?: string
  created?: string
  // The synchronous backend does not provision a client or an admin user and
  // does not return these (ISS-1030, OQ-10); they stay for the saga shape.
  idp_realm_id?: string | null
  client_id?: string
  admin_user_id?: string
  oidc_authority?: string
  discovery_url?: string
  // ISS-1030 additions, taken from the backend response.
  login?: OnboardingLogin
  administrator?: OnboardingAdministrator
  ignored_fields?: string[]
}

export interface OnboardingStatusFailed {
  state: 'failed'
  error: string
}

export type OnboardingSagaResult =
  | OnboardingStatusPending
  | OnboardingStatusCompleted
  | OnboardingStatusFailed

export interface OnboardingCreateResponse {
  onboarding_id: string
  /** The created record, adapted to the saga-shaped "completed" result. */
  result: OnboardingStatusCompleted
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

/**
 * Thin adapter (design OQ-10): the backend answers synchronously with a plain
 * record ({id, tenant_id, slug, hostname, created_at, login, ...}); the pages
 * are written against the saga shape ({state, onboarding_id, ...}). This maps
 * the record to the saga-shaped "completed" result, limited to what the pages
 * display. It does not invent values the server did not send.
 */
export function adaptRecord(raw: OnboardingRecord | OnboardingSagaResult): OnboardingSagaResult {
  if ('state' in raw) return raw
  return {
    state: 'completed',
    onboarding_id: raw.id,
    tenant_id: raw.tenant_id,
    hostname: raw.hostname,
    slug: raw.slug,
    created: raw.created_at,
    idp_realm_id: raw.login?.idp_realm_id ?? null,
    ...(raw.login ? { login: raw.login } : {}),
    ...(raw.administrator ? { administrator: raw.administrator } : {}),
    ...(raw.ignored_fields ? { ignored_fields: raw.ignored_fields } : {}),
  }
}

function adaptCompleted(raw: OnboardingRecord | OnboardingSagaResult): OnboardingStatusCompleted {
  const adapted = adaptRecord(raw)
  if (adapted.state !== 'completed') {
    throw new OnboardingApiError(502, { error: 'unexpected_onboarding_state' })
  }
  return adapted
}

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
): Promise<OnboardingCreateResponse> {
  const adminEmail = nonBlank(formValues.admin_email)
  const adminUsername = nonBlank(formValues.admin_username)
  const adminDisplayName = nonBlank(formValues.admin_display_name)
  const realmId = nonBlank(formValues.idp_realm_id)

  const body: OnboardingSubmitRequest = {
    slug: formValues.slug,
    display_name: formValues.display_name,
    ...(adminEmail ? { admin_email: adminEmail } : {}),
    ...(adminUsername ? { admin_username: adminUsername } : {}),
    ...(adminDisplayName ? { admin_display_name: adminDisplayName } : {}),
    ...(realmId ? { idp_realm_id: realmId } : {}),
    hostname: formValues.hostname,
    client_config: {
      redirect_uris: formValues.redirect_uris,
      ...(formValues.client_config?.service_account_enabled !== undefined
        ? { service_account_enabled: formValues.client_config.service_account_enabled }
        : {}),
    },
    ...(formValues.realm_config && Object.keys(formValues.realm_config).length > 0
      ? { realm_config: formValues.realm_config }
      : {}),
  }

  const record = await client
    .postWithHeaders<OnboardingRecord>('/api/v1/onboarding', body, {
      'Idempotency-Key': idempotencyKey,
    })
    .catch((err: unknown) => {
      throw toOnboardingApiError(err)
    })

  const result = adaptCompleted(record)
  return { onboarding_id: result.onboarding_id, result }
}

/**
 * GET /api/v1/onboarding/:onboardingId
 * Returns the current record (adapted to the saga shape).
 * Throws on non-2xx responses.
 */
export async function getOnboardingStatus(onboardingId: string): Promise<OnboardingSagaResult> {
  const raw = await client.get<OnboardingRecord | OnboardingSagaResult>(
    `/api/v1/onboarding/${encodeURIComponent(onboardingId)}`,
  )
  return adaptRecord(raw)
}

/**
 * GET /api/v1/onboarding?hostname=<hostname>
 * Returns the record for the given hostname (adapted to the saga shape).
 * Throws on non-2xx responses (404 means not found).
 */
export async function getOnboardingByHostname(hostname: string): Promise<OnboardingStatusCompleted> {
  const raw = await client.get<OnboardingRecord | OnboardingSagaResult>('/api/v1/onboarding', {
    hostname,
  })
  return adaptCompleted(raw)
}

/**
 * POST /api/v1/onboarding/:onboardingId/bind-realm  (ISS-1030, bind-once)
 * The server validates, checks the realm with the identity provider and is
 * authoritative; this only sends the trimmed value. Throws OnboardingApiError.
 */
export async function bindRealm(
  onboardingId: string,
  idpRealmId: string,
): Promise<OnboardingStatusCompleted> {
  const raw = await client
    .post<OnboardingRecord>(
      `/api/v1/onboarding/${encodeURIComponent(onboardingId)}/bind-realm`,
      { idp_realm_id: idpRealmId.trim() },
    )
    .catch((err: unknown) => {
      throw toOnboardingApiError(err)
    })
  return adaptCompleted(raw)
}
