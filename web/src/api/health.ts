import { client } from './client'
import type { BackupStatus, HealthStatus, ReadinessResult } from '@/types/api'

// NOTE (ISS-0532, updated by T-1607): `GET /health/ready` never existed. The liveness probe below
// uses the real `GET /health`. Per-part readiness is now `GET /ready` (T-1607, `readiness()` below;
// `docs/frontend/contract-gaps.md` row 15), and the operator's backup line is
// `GET /api/v1/platform-status/backup` (`backupStatus()` below).

// `GET /api/v1/health` (`healthApi.get`) has no callers anywhere in
// `web/src` as of ISS-0532's diagnosis. Left in place — removing it is a
// separate, unrelated cleanup, not part of this fix.
export const healthApi = {
  get: () => client.get<HealthStatus>('/api/v1/health'),
}

/**
 * Connectivity probe — raw fetch to `GET /health` (liveness, not readiness;
 * see the ISS-0532 note above for why).
 * Returns true if the backend responds with a 2xx status.
 * Returns false on any error (network failure, timeout, non-2xx).
 * Never throws.
 */
export async function healthReady(): Promise<boolean> {
  try {
    await client.get<unknown>('/health')
    return true
  } catch {
    return false
  }
}

const READINESS_PARTS = ['database', 'migrations', 'secrets_key', 'identity'] as const

/**
 * Per-part readiness (`GET /ready`, public). The route answers 503 with a JSON body that names the
 * failing parts, so this reads the body on a non-2xx too (`client.getPublic` never throws on a
 * status). Rejects when the server cannot be reached or the body is not the readiness shape.
 */
export async function readiness(): Promise<ReadinessResult> {
  const { status, body } = await client.getPublic('/ready')
  const checks = (body as { checks?: Record<string, unknown> } | null)?.checks
  if ((status !== 200 && status !== 503) || !checks || typeof checks !== 'object') {
    throw new Error(`readiness: unexpected answer ${status}`)
  }
  const parts = READINESS_PARTS.map((part) => ({ part, ok: checks[part] === 'ok' }))
  return { ready: status === 200 && parts.every((p) => p.ok), parts }
}

/** The platform operator's backup freshness line (`GET /api/v1/platform-status/backup`). */
export function backupStatus(): Promise<BackupStatus> {
  return client.get<BackupStatus>('/api/v1/platform-status/backup')
}
