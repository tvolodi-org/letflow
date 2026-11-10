import type { PrometheusMetricFamily } from './metrics'

/** Thresholds are settings, not rules: change them here. */
export const ERROR_SHARE_RED = 0.05
export const SLOW_SHARE_WARN = 0.01
export const SLOW_SHARE_RED = 0.05
export const SLOW_BOUNDARY_SECONDS = 1
export const REFRESH_STALE_WARN_SECONDS = 10 * 60
export const REFRESH_STALE_RED_SECONDS = 30 * 60
export const POOL_SHARE_WARN = 0.7
export const POOL_SHARE_RED = 0.9

export type FigureStatus = 'ok' | 'warn' | 'red' | 'unknown'

export type FigureId =
  | 'requests'
  | 'errors'
  | 'slowDb'
  | 'slowAppend'
  | 'refresh'
  | 'pool'

export interface Figure {
  id: FigureId
  status: FigureStatus
  /** Per-minute rate, share (0..1) or age in seconds, depending on the figure; null when not measurable yet. */
  value: number | null
  /** Pool figure only: slots held and the cap, for the card text. */
  pool?: PoolUse
}

export interface PoolUse {
  inUse: number
  cap: number
}

export interface ErrorRoute {
  route: string
  errors: number
}

const REQUESTS = 'letflow_http_requests_total'
const ERRORS = 'letflow_http_errors_total'
const DB_HIST = 'letflow_db_query_duration_seconds'
const APPEND_HIST = 'letflow_event_append_duration_seconds'
const POOL_IN_USE = 'letflow_db_admission_in_use'
const POOL_CAP = 'letflow_db_admission_cap'
const REFRESH = 'letflow_active_instances_last_refresh_timestamp_seconds'

function family(families: PrometheusMetricFamily[], name: string): PrometheusMetricFamily | undefined {
  return families.find((f) => f.name === name)
}

/** Sum of all samples of a counter family; null when the family is absent. */
export function sumFamily(families: PrometheusMetricFamily[], name: string): number | null {
  const f = family(families, name)
  if (!f) return null
  return f.samples.reduce((acc, s) => acc + s.value, 0)
}

/** Per-minute rate between two readings; null when it cannot be measured (first reading, dt<=0, restart). */
export function counterRate(prev: number | null, curr: number | null, dtSeconds: number): number | null {
  if (prev === null || curr === null || !(dtSeconds > 0) || curr < prev) return null
  return ((curr - prev) / dtSeconds) * 60
}

/**
 * Share of observations slower than the smallest bucket boundary >= leSeconds, cumulative since start.
 * Buckets are summed across all label sets (for example every query_type). Null when no data.
 */
export function histogramShare(families: PrometheusMetricFamily[], name: string, leSeconds: number): number | null {
  const f = family(families, name)
  if (!f) return null
  const bounds = new Map<number, number>()
  let total = 0
  for (const s of f.samples) {
    if (s.name.endsWith('_bucket')) {
      const raw = s.labels.le
      if (raw === undefined) continue
      if (raw === '+Inf') {
        total += s.value
        continue
      }
      const le = Number(raw)
      if (Number.isNaN(le)) continue
      bounds.set(le, (bounds.get(le) ?? 0) + s.value)
    }
  }
  if (total <= 0) return null
  const candidates = [...bounds.keys()].filter((le) => le >= leSeconds).sort((a, b) => a - b)
  if (candidates.length === 0) return null
  const within = bounds.get(candidates[0]) ?? 0
  return Math.max(0, (total - within) / total)
}

export function topErrorRoutes(families: PrometheusMetricFamily[], n = 3): ErrorRoute[] {
  const f = family(families, ERRORS)
  if (!f) return []
  const byRoute = new Map<string, number>()
  for (const s of f.samples) {
    const route = s.labels.route_template ?? '?'
    byRoute.set(route, (byRoute.get(route) ?? 0) + s.value)
  }
  return [...byRoute.entries()]
    .filter(([, errors]) => errors > 0)
    .map(([route, errors]) => ({ route, errors }))
    .sort((a, b) => b.errors - a.errors || a.route.localeCompare(b.route))
    .slice(0, n)
}

export function shareStatus(share: number | null): FigureStatus {
  if (share === null) return 'unknown'
  if (share >= SLOW_SHARE_RED) return 'red'
  if (share >= SLOW_SHARE_WARN) return 'warn'
  return 'ok'
}

export function refreshAgeSeconds(families: PrometheusMetricFamily[], nowSeconds: number): number | null {
  const f = family(families, REFRESH)
  if (!f || f.samples.length === 0) return null
  const ts = f.samples[0].value
  if (!(ts > 0)) return null
  return Math.max(0, nowSeconds - ts)
}

export function refreshStatus(age: number | null): FigureStatus {
  if (age === null) return 'unknown'
  if (age > REFRESH_STALE_RED_SECONDS) return 'red'
  if (age > REFRESH_STALE_WARN_SECONDS) return 'warn'
  return 'ok'
}

/** Admission slots held and the cap; null when either gauge is absent or the cap is not positive. */
export function poolUse(families: PrometheusMetricFamily[]): PoolUse | null {
  const inUse = family(families, POOL_IN_USE)?.samples[0]?.value
  const cap = family(families, POOL_CAP)?.samples[0]?.value
  if (inUse === undefined || cap === undefined || !(cap > 0) || inUse < 0) return null
  return { inUse, cap }
}

export function poolStatus(share: number | null): FigureStatus {
  if (share === null) return 'unknown'
  if (share >= POOL_SHARE_RED) return 'red'
  if (share >= POOL_SHARE_WARN) return 'warn'
  return 'ok'
}

export interface Reading {
  families: PrometheusMetricFamily[]
  /** Seconds since epoch of the moment the data was fetched. */
  atSeconds: number
}

export function errorStatus(errorsPerMin: number | null, requestsPerMin: number | null, errorsTotal: number | null): FigureStatus {
  if (errorsTotal === null) return 'unknown'
  if (errorsPerMin === null) return errorsTotal > 0 ? 'warn' : 'ok'
  if (errorsPerMin <= 0) return 'ok'
  if (requestsPerMin !== null && requestsPerMin > 0 && errorsPerMin / requestsPerMin >= ERROR_SHARE_RED) return 'red'
  return 'warn'
}

/** The figures for one reading; `prev` is the reading before it (null on the first poll). */
export function buildSummary(prev: Reading | null, curr: Reading, nowSeconds: number): Figure[] {
  const dt = prev ? curr.atSeconds - prev.atSeconds : 0
  const reqRate = counterRate(prev ? sumFamily(prev.families, REQUESTS) : null, sumFamily(curr.families, REQUESTS), dt)
  const errRate = counterRate(prev ? sumFamily(prev.families, ERRORS) : null, sumFamily(curr.families, ERRORS), dt)
  const errTotal = sumFamily(curr.families, ERRORS)
  const dbShare = histogramShare(curr.families, DB_HIST, SLOW_BOUNDARY_SECONDS)
  const appendShare = histogramShare(curr.families, APPEND_HIST, SLOW_BOUNDARY_SECONDS)
  const age = refreshAgeSeconds(curr.families, nowSeconds)
  const pool = poolUse(curr.families)
  const poolShare = pool ? Math.min(1, pool.inUse / pool.cap) : null
  return [
    { id: 'requests', status: sumFamily(curr.families, REQUESTS) === null ? 'unknown' : 'ok', value: reqRate },
    { id: 'errors', status: errorStatus(errRate, reqRate, errTotal), value: errRate },
    { id: 'slowDb', status: shareStatus(dbShare), value: dbShare },
    { id: 'slowAppend', status: shareStatus(appendShare), value: appendShare },
    { id: 'refresh', status: refreshStatus(age), value: age },
    { id: 'pool', status: poolStatus(poolShare), value: poolShare, ...(pool ? { pool } : {}) },
  ]
}
