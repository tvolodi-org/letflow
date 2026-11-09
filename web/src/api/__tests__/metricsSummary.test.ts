import { describe, expect, it } from 'vitest'
import { parsePrometheusText } from '../metrics'
import {
  buildSummary,
  counterRate,
  histogramShare,
  refreshAgeSeconds,
  refreshStatus,
  topErrorRoutes,
} from '../metricsSummary'

const HIST = [
  '# TYPE letflow_db_query_duration_seconds histogram',
  'letflow_db_query_duration_seconds_bucket{query_type="a",le="0.5"} 50',
  'letflow_db_query_duration_seconds_bucket{query_type="a",le="1.0"} 90',
  'letflow_db_query_duration_seconds_bucket{query_type="a",le="+Inf"} 100',
  'letflow_db_query_duration_seconds_bucket{query_type="b",le="0.5"} 100',
  'letflow_db_query_duration_seconds_bucket{query_type="b",le="1.0"} 100',
  'letflow_db_query_duration_seconds_bucket{query_type="b",le="+Inf"} 100',
  'letflow_db_query_duration_seconds_count{query_type="a"} 100',
].join('\n')

const reading = (text: string, atSeconds: number) => ({ families: parsePrometheusText(text), atSeconds })
const counters = (req: number, err: number) =>
  `letflow_http_requests_total{method="GET",route_template="/a",status="200"} ${req}\nletflow_http_errors_total{route_template="/a"} ${err}\n`

describe('metricsSummary', () => {
  it('S1: counterRate is per minute and null when not measurable', () => {
    expect(counterRate(100, 220, 60)).toBe(120)
    expect(counterRate(null, 220, 60)).toBeNull()
    expect(counterRate(300, 220, 60)).toBeNull()
    expect(counterRate(100, 220, 0)).toBeNull()
  })

  it('S2: error status ok / warn / red / unknown', () => {
    const st = (prev: string | null, curr: string) =>
      buildSummary(prev ? reading(prev, 0) : null, reading(curr, 60), 60).find((f) => f.id === 'errors')?.status
    expect(st(counters(0, 0), counters(1000, 0))).toBe('ok')
    expect(st(counters(0, 0), counters(1000, 10))).toBe('warn')
    expect(st(counters(0, 0), counters(1000, 100))).toBe('red')
    expect(st(null, 'up 1\n')).toBe('unknown')
  })

  it('S3: histogramShare sums all labels and uses the 1.0 boundary', () => {
    // total 200, within 1.0 = 190 -> 5%
    expect(histogramShare(parsePrometheusText(HIST), 'letflow_db_query_duration_seconds', 1)).toBeCloseTo(0.05)
    expect(histogramShare([], 'x', 1)).toBeNull()
  })

  it('S4: background refresh age thresholds, missing timestamp', () => {
    const f = (ts: string) => parsePrometheusText(`letflow_active_instances_last_refresh_timestamp_seconds ${ts}\n`)
    expect(refreshStatus(refreshAgeSeconds(f('1000'), 1000 + 60))).toBe('ok')
    expect(refreshStatus(refreshAgeSeconds(f('1000'), 1000 + 11 * 60))).toBe('warn')
    expect(refreshStatus(refreshAgeSeconds(f('1000'), 1000 + 31 * 60))).toBe('red')
    expect(refreshStatus(refreshAgeSeconds(f('0'), 5000))).toBe('unknown')
    expect(refreshStatus(refreshAgeSeconds([], 5000))).toBe('unknown')
  })

  it('S5: topErrorRoutes orders by count and caps at 3', () => {
    const text = ['a', 'b', 'c', 'd'].map((r, i) => `letflow_http_errors_total{route_template="/${r}"} ${i + 1}`).join('\n')
    expect(topErrorRoutes(parsePrometheusText(text)).map((r) => r.route)).toEqual(['/d', '/c', '/b'])
  })
})
