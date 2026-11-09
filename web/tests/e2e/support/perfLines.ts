/**
 * T-1533 — pure helpers of the manual lines-editor performance run (perf-lines.e2e.spec.ts). No browser, no clock:
 * the unit test web/tests/unit/perfLines.test.ts pins them.
 */

/** Items in the fixed data set (PERF-0001..PERF-0190). The client item picker reads ONE page of 200 catalog items, and the
 *  GATE B masters already use 4 of them: 200 perf items would leave 4 codes unresolvable (measured, see the perf note). */
export const PERF_ITEMS = 190
/** Every INVALID_EVERY-th line (1-based) is made invalid on purpose (quantity 0). */
export const INVALID_EVERY = 50

export function perfCode(i: number): string {
  return `PERF-${String((i % PERF_ITEMS) + 1).padStart(4, '0')}`
}

/** Quantity of line `i` (0-based): 1..7, repeating. */
export function perfQuantity(i: number): number {
  return 1 + (i % 7)
}

/** Number of lines `buildPasteText(n)` makes invalid. */
export function invalidCount(n: number): number {
  return Math.floor(n / INVALID_EVERY)
}

/** The clipboard text of an n-line list: `code<TAB><TAB>quantity` (the empty middle cell is the lot column). With
 *  `withInvalid` every 50th line has quantity 0; without it the list is valid. Deterministic. */
export function buildPasteText(n: number, withInvalid = true): string {
  const rows: string[] = []
  for (let i = 0; i < n; i += 1) {
    const bad = withInvalid && (i + 1) % INVALID_EVERY === 0
    rows.push(`${perfCode(i)}\t\t${bad ? 0 : perfQuantity(i)}`)
  }
  return rows.join('\n')
}

export function median(xs: number[]): number {
  if (xs.length === 0) return NaN
  const s = [...xs].sort((a, b) => a - b)
  const m = Math.floor(s.length / 2)
  return s.length % 2 === 1 ? s[m]! : (s[m - 1]! + s[m]!) / 2
}

export interface CellSummary {
  median: number
  max: number
  runs: number
}

export function summarize(runs: number[]): CellSummary {
  return { median: median(runs), max: runs.length ? Math.max(...runs) : NaN, runs: runs.length }
}

export type PerfTable = Record<string, Record<number, number[]>>

/** Markdown table: one row per operation, one column per size, cell = "median / max" in ms. */
export function toMarkdownTable(table: PerfTable, sizes: number[]): string {
  const head = `| operation | ${sizes.map((s) => `${s} lines`).join(' | ')} |`
  const sep = `|---|${sizes.map(() => '---').join('|')}|`
  const body = Object.keys(table).map((op) => {
    const cells = sizes.map((s) => {
      const r = table[op]?.[s]
      if (!r || r.length === 0) return 'n/a'
      const c = summarize(r)
      return `${Math.round(c.median)} / ${Math.round(c.max)}`
    })
    return `| ${op} | ${cells.join(' | ')} |`
  })
  return [head, sep, ...body].join('\n')
}
