/** API Client — typed fetch wrapper
 *  Adapted from ai-dala-forge/frontend/src/core/api/client.ts
 *  Changes for BPM Platform:
 *  - RFC 9457 Problem Details error parsing
 *  - Retry-After header surfaced on 429
 *  - VITE_API_BASE_URL via env
 */

import type { ApiError } from '@/types/api'

const BASE_URL = import.meta.env.VITE_API_BASE_URL ?? ''

// ── Token storage (in-memory — never localStorage/sessionStorage per FNFR-06) ──

let _token: string | null = null

export function getToken(): string | null {
  return _token
}
export function setToken(token: string): void {
  _token = token
}
export function clearToken(): void {
  _token = null
}

/** No-op — kept for API compatibility. */
export function tryRestoreE2eToken(): string | null {
  return null
}

/**
 * E2E session restore: read session from sessionStorage (written by test runner).
 * Returns the session object or null.
 */
export function tryRestoreE2eSession(): { token: string; display_name: string; roles: string[]; tenant_slug?: string | null; tenant_display_name?: string | null } | null {
  try {
    const raw = sessionStorage.getItem('__e2e_session')
    if (!raw) return null
    const session = JSON.parse(raw) as { token: string; display_name: string; roles: string[]; tenant_slug?: string | null; tenant_display_name?: string | null }
    if (session.token && session.roles?.length > 0) {
      _token = session.token
      return session
    }
    return null
  } catch {
    return null
  }
}

/** Extract user ID (sub claim) from JWT token */
function extractUserIdFromToken(token: string): string | null {
  try {
    const parts = token.split('.')
    if (parts.length !== 3) return null
    const decoded = JSON.parse(atob(parts[1]))
    return decoded.sub || null
  } catch {
    return null
  }
}

// ── Core request ───────────────────────────────────────────────────────────────

function buildRequestHeaders(extraHeaders?: Record<string, string>): Record<string, string> {
  const token = getToken()
  const headers: Record<string, string> = { ...extraHeaders }
  if (token) {
    headers['Authorization'] = `Bearer ${token}`
    // Extract user ID from JWT and send as required x-bpm-user-id header
    const userId = extractUserIdFromToken(token)
    if (userId) {
      headers['x-bpm-user-id'] = userId
    }
  }
  return headers
}

/** Backend constant `detail` of the REQ-463 distinct-person refusal. */
export const SEPARATION_OF_DUTIES_DETAIL = 'separation of duties'
export const SEPARATION_OF_DUTIES_CODE = 'SEPARATION_OF_DUTIES'
export const SEPARATION_OF_DUTIES_MESSAGE =
  'You cannot complete this step: a different person must do it (separation of duties).'
/** Claim/assign variant of the same refusal (TaskInboxPage). */
export const SEPARATION_OF_DUTIES_CLAIM_MESSAGE =
  'You cannot take this task: a different person must do it (separation of duties).'

/** True when `err` is the ApiError produced for the separation-of-duties 403. */
export function isSeparationOfDuties(err: unknown): boolean {
  const e = err as { status?: unknown; code?: unknown } | null | undefined
  return !!e && typeof e === 'object' && e.status === 403 && e.code === SEPARATION_OF_DUTIES_CODE
}

/** Shared non-2xx handling for both request() (json/text) and getBlob()
 *  (binary). Throws the same ApiError shape either way — callers branch on
 *  err.status, not on a blob-specific error type (design §2.2). Returns
 *  normally (does not throw) when response.ok. */
async function throwOnErrorResponse(
  response: Response,
  behavior: { suppressSessionExpiredEvent?: boolean } = {},
): Promise<void> {
  if (response.status === 401) {
    if (!behavior.suppressSessionExpiredEvent) {
      window.dispatchEvent(new CustomEvent('auth:session-expired'))
    }
    throw buildError(response, { status: 401, message: 'Session expired', code: 'UNAUTHORIZED' })
  }

  if (response.status === 429) {
    const retryAfter = response.headers.get('Retry-After')
    throw buildError(response, {
      status: 429,
      message: `Rate limit exceeded. Retry after ${retryAfter ?? '?'}s`,
      code: 'RATE_LIMITED',
      details: { retryAfter },
    })
  }

  if (response.status === 409) {
    // PD-08: capture X-Resource-Version on 409 so the frontend ConflictResolver
    // can carry the version stamp into the PATCH If-Match header.
    const xResourceVersion = response.headers.get('X-Resource-Version')
    let body: Record<string, unknown> = {}
    try {
      body = (await response.json()) as Record<string, unknown>
    } catch {
      /* not JSON */
    }
    throw buildError(response, {
      status: 409,
      message: (body['title'] as string) ?? (body['message'] as string) ?? 'Conflict',
      code: (body['type'] as string) ?? (body['code'] as string) ?? 'STALE_VERSION',
      details: {
        xResourceVersion: xResourceVersion ?? null,
        ...(Object.keys(body).length > 0 ? body : {}),
      },
    })
  }

  if (!response.ok) {
    // RFC 9457 Problem Details
    let body: Record<string, unknown> = {}
    try {
      body = (await response.json()) as Record<string, unknown>
    } catch { /* not JSON */ }

    const details =
      typeof body['errors'] === 'object' && body['errors'] !== null
        ? (body['errors'] as Record<string, unknown>)
        : (Object.keys(body).length > 0 ? body : undefined)

    // GH 2355 / ISS-1034 -- REQ-463 distinct-person refusal. The backend
    // answers it with the constant body {"detail":"separation of duties",
    // "status":403} (no title/type). Exact match only; every other 403 keeps
    // today's message/code.
    if (response.status === 403 && body['detail'] === SEPARATION_OF_DUTIES_DETAIL) {
      throw buildError(response, {
        status: 403,
        message: SEPARATION_OF_DUTIES_MESSAGE,
        code: SEPARATION_OF_DUTIES_CODE,
        details,
      })
    }

    throw buildError(response, {
      status: response.status,
      message: (body['title'] as string) ?? (body['message'] as string) ?? response.statusText,
      code: (body['type'] as string) ?? (body['code'] as string) ?? String(response.status),
      details,
    })
  }
}

async function request<T>(
  path: string,
  options: RequestInit = {},
  behavior: { suppressSessionExpiredEvent?: boolean } = {},
  parseAs: 'json' | 'text' = 'json',
): Promise<T> {
  const isFormData = options.body instanceof FormData

  const headers: Record<string, string> = buildRequestHeaders({
    ...(isFormData ? {} : { 'Content-Type': 'application/json' }),
    ...(options.headers as Record<string, string>),
  })

  const response = await window.fetch(`${BASE_URL}${path}`, { ...options, headers })

  await throwOnErrorResponse(response, behavior)

  if (response.status === 204) {
    return (parseAs === 'text' ? '' : undefined) as T
  }
  if (parseAs === 'text') {
    return (await response.text()) as T
  }
  return response.json() as Promise<T>
}

function buildError(response: Response, partial: Partial<ApiError>): ApiError {
  return {
    status: response.status,
    message: 'Request failed',
    code: String(response.status),
    ...partial,
  }
}

// ── Public API surface ─────────────────────────────────────────────────────────

export const client = {
  get<T>(path: string, params?: Record<string, unknown>): Promise<T> {
    const url = params
      ? `${path}?${new URLSearchParams(
          Object.fromEntries(
            Object.entries(params).filter((entry): entry is [string, string] => {
              const v = entry[1];
              return v !== undefined && v !== null && v !== '';
            }),
          ),
        )}`
      : path
    return request<T>(url)
  },
  /** Fetches a binary response as a Blob, attaching the same Authorization/
   *  x-bpm-user-id headers request() already attaches for json/text calls
   *  (design §2.2). On a non-2xx response, throws the same ApiError shape
   *  request()'s existing !response.ok branch does (401/429/409/generic) --
   *  callers branch on err.status (404/410/other), not on a blob-specific
   *  error type. Used for attachment content bytes, which are never JSON. */
  async getBlob(path: string, params?: Record<string, unknown>): Promise<{ blob: Blob; contentType: string }> {
    const url = params
      ? `${path}?${new URLSearchParams(
          Object.fromEntries(
            Object.entries(params).filter((entry): entry is [string, string] => {
              const v = entry[1];
              return v !== undefined && v !== null && v !== '';
            }),
          ),
        )}`
      : path
    const headers = buildRequestHeaders()
    const response = await window.fetch(`${BASE_URL}${url}`, { headers })
    await throwOnErrorResponse(response)
    const blob = await response.blob()
    const contentType = response.headers.get('Content-Type') ?? blob.type ?? 'application/octet-stream'
    return { blob, contentType }
  },
  getText(path: string, params?: Record<string, unknown>): Promise<string> {
    const url = params
      ? `${path}?${new URLSearchParams(
          Object.fromEntries(
            Object.entries(params).filter((entry): entry is [string, string] => {
              const v = entry[1];
              return v !== undefined && v !== null && v !== '';
            }),
          ),
        )}`
      : path
    return request<string>(url, {}, {}, 'text')
  },
  getWithToken<T>(path: string, token: string, params?: Record<string, unknown>): Promise<T> {
    const url = params
      ? `${path}?${new URLSearchParams(
          Object.fromEntries(
            Object.entries(params).filter((entry): entry is [string, string] => {
              const v = entry[1];
              return v !== undefined && v !== null && v !== '';
            }),
          ),
        )}`
      : path
    const headers: Record<string, string> = { Authorization: `Bearer ${token}` }
    const userId = extractUserIdFromToken(token)
    if (userId) {
      headers['x-bpm-user-id'] = userId
    }
    return request<T>(url, {
      headers,
    }, {
      suppressSessionExpiredEvent: true,
    })
  },
  post<T>(path: string, body?: unknown): Promise<T> {
    return request<T>(path, {
      method: 'POST',
      body: body instanceof FormData ? body : JSON.stringify(body),
    })
  },
  postWithHeaders<T>(path: string, body: unknown, extraHeaders: Record<string, string>): Promise<T> {
    return request<T>(path, {
      method: 'POST',
      headers: extraHeaders,
      body: JSON.stringify(body),
    })
  },
  put<T>(path: string, body?: unknown): Promise<T> {
    return request<T>(path, {
      method: 'PUT',
      body: body instanceof FormData ? body : JSON.stringify(body),
    })
  },
  /** PUT with caller-supplied extra headers — mirrors postWithHeaders (used
   *  for If-Match on an optimistic-concurrency update; REQ-336). */
  putWithHeaders<T>(path: string, body: unknown, extraHeaders: Record<string, string>): Promise<T> {
    return request<T>(path, {
      method: 'PUT',
      headers: extraHeaders,
      body: JSON.stringify(body),
    })
  },
  patch<T>(path: string, body?: unknown): Promise<T> {
    return request<T>(path, {
      method: 'PATCH',
      body: body instanceof FormData ? body : JSON.stringify(body),
    })
  },
  delete<T>(path: string): Promise<T> {
    return request<T>(path, { method: 'DELETE' })
  },
}
