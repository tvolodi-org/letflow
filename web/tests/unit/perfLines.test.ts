/** T-1533 — the pure helpers of the manual lines-editor performance run (P1, P2). */
import { describe, expect, it } from 'vitest'
import { buildPasteText, invalidCount, median, summarize, toMarkdownTable } from '../e2e/support/perfLines'

describe('perfLines helpers', () => {
  it('P1 buildPasteText(1000): 1000 rows, every 50th invalid, deterministic', () => {
    const text = buildPasteText(1000)
    const rows = text.split('\n')
    expect(rows).toHaveLength(1000)
    expect(rows[0]).toBe('PERF-0001\t\t1')
    expect(rows[189]).toBe('PERF-0190\t\t' + (1 + (189 % 7)))
    expect(rows[199]).toBe('PERF-0010\t\t0')
    expect(rows[190]).toBe('PERF-0001\t\t' + (1 + (190 % 7)))
    const bad = rows.filter((r) => r.endsWith('\t\t0'))
    expect(bad).toHaveLength(20)
    expect(invalidCount(1000)).toBe(20)
    expect(invalidCount(100)).toBe(2)
    expect(rows[49]!.endsWith('\t\t0')).toBe(true)
    expect(buildPasteText(1000)).toBe(text)
    expect(buildPasteText(100, false).split('\n').some((r) => r.endsWith('\t\t0'))).toBe(false)
  })

  it('P2 median, summarize and the markdown table', () => {
    expect(median([3, 1, 2])).toBe(2)
    expect(median([4, 1, 2, 3])).toBe(2.5)
    expect(summarize([10, 30, 20])).toEqual({ median: 20, max: 30, runs: 3 })
    const md = toMarkdownTable({ open: { 100: [100, 300, 200], 500: [] }, post: { 100: [1000] } }, [100, 500])
    expect(md).toBe(
      ['| operation | 100 lines | 500 lines |', '|---|---|---|', '| open | 200 / 300 | n/a |', '| post | 1000 / 1000 | n/a |'].join('\n'),
    )
  })
})
