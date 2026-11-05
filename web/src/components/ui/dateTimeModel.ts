/** dateTimeModel — pure logic of the platform date and time fields (NOTES.md "Date and time").
 *  Values are strings only: date `YYYY-MM-DD`, time `HH:mm`, date-time `YYYY-MM-DDTHH:mm`; empty is `''`.
 *  Typed format: `DD-MM-YYYY` in ru, kk, uz; `YYYY-MM-DD` in en. No time zone here. */
import { usesDayFirstDashes } from '@/i18n/format'

const pad = (n: number, w = 2) => String(n).padStart(w, '0')

export function daysIn(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate()
}

export function isoOf(y: number, m: number, d: number): string {
  return `${pad(y, 4)}-${pad(m)}-${pad(d)}`
}

/** Result of parsing typed text. `exists: false` = well-formed but not a calendar day (31-02). */
export type DateParse = { iso: string } | { error: 'format' | 'exists' }

/** Parse typed date text; lenient about the separator and about a year-first ISO text; strict about day/month order. */
export function parseDate(text: string, lang: string): DateParse {
  const t = text.trim()
  if (t === '') return { error: 'format' }
  let y: number
  let m: number
  let d: number
  let match = /^(\d{4})[-./\s](\d{1,2})[-./\s](\d{1,2})$/.exec(t)
  if (match) {
    y = Number(match[1])
    m = Number(match[2])
    d = Number(match[3])
  } else if (usesDayFirstDashes(lang)) {
    match = /^(\d{1,2})[-./\s](\d{1,2})[-./\s](\d{4})$/.exec(t) ?? /^(\d{2})(\d{2})(\d{4})$/.exec(t)
    if (!match) return { error: 'format' }
    d = Number(match[1])
    m = Number(match[2])
    y = Number(match[3])
  } else {
    match = /^(\d{4})(\d{2})(\d{2})$/.exec(t)
    if (!match) return { error: 'format' }
    y = Number(match[1])
    m = Number(match[2])
    d = Number(match[3])
  }
  if (m < 1 || m > 12 || d < 1 || y < 1 || d > daysIn(y, m)) return { error: 'exists' }
  return { iso: isoOf(y, m, d) }
}

/** The text shown for a valid ISO date in the field's typed format. */
export function formatDateText(iso: string, lang: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso)
  if (!m) return ''
  return usesDayFirstDashes(lang) ? `${m[3]}-${m[2]}-${m[1]}` : iso
}

/** Mask: digits only, separators inserted as a group completes (`5-` becomes `05-`). */
export function maskDate(text: string, lang: string): string {
  const dayFirst = usesDayFirstDashes(lang)
  // A pasted year-first ISO text is converted in the day-first languages.
  const iso = /^(\d{4})[-./](\d{1,2})[-./](\d{1,2})$/.exec(text.trim())
  if (iso && dayFirst) return `${pad(Number(iso[3]))}-${pad(Number(iso[2]))}-${iso[1]}`
  const digits = text.replace(/\D/g, '').slice(0, 8)
  const groups = dayFirst ? [2, 2, 4] : [4, 2, 2]
  const out: string[] = []
  let at = 0
  for (const g of groups) {
    if (at >= digits.length) break
    out.push(digits.slice(at, at + g))
    at += g
  }
  let res = out.join('-')
  // A trailing separator typed after a one-digit day/month group pads it: `5-` -> `05-`.
  const trailing = /[-./\s]$/.test(text) && digits.length > 0
  if (trailing && out.length > 0) {
    const last = out[out.length - 1]
    const gi = out.length - 1
    if (last.length === 1 && groups[gi] === 2) {
      out[gi] = `0${last}`
      res = out.join('-')
    }
    if (out[gi].length === groups[gi] && gi < 2) res += '-'
  } else if (out.length > 0 && out[out.length - 1].length === groups[out.length - 1] && out.length < 3) {
    res += '-'
  }
  return res
}

/** Parse a typed time: `9:30`, `930`, `0930`, `09.30`, `09:30`. A single digit is not a time. */
export function parseTime(text: string): { time: string } | { error: 'format' | 'range' } {
  const t = text.trim()
  const m = /^(\d{1,2})[:.](\d{2})$/.exec(t) ?? /^(\d{1,2})(\d{2})$/.exec(t)
  if (!m) return { error: 'format' }
  const h = Number(m[1])
  const min = Number(m[2])
  if (h > 23 || min > 59) return { error: 'range' }
  return { time: `${pad(h)}:${pad(min)}` }
}

export function maskTime(text: string): string {
  const digits = text.replace(/\D/g, '').slice(0, 4)
  if (digits.length <= 2 && !/[:.]/.test(text)) return digits.length === 2 ? `${digits}:` : digits
  if (digits.length <= 2) return `${digits}:`
  return `${digits.slice(0, 2)}:${digits.slice(2)}`
}

/** Split `YYYY-MM-DDTHH:mm` into its date and time parts (either may be empty). */
export function splitDateTime(value: string): { date: string; time: string } {
  const m = /^(\d{4}-\d{2}-\d{2})(?:T(\d{2}:\d{2}))?/.exec(value)
  return { date: m?.[1] ?? '', time: m?.[2] ?? '' }
}

export function combineDateTime(date: string, time: string): string {
  return date !== '' && time !== '' ? `${date}T${time}` : ''
}

/** Monday-first grid of the month: 6 rows of 7 ISO dates, with `inMonth` marking the days of the month. */
export function monthGrid(year: number, month: number): { iso: string; inMonth: boolean }[][] {
  const first = new Date(Date.UTC(year, month - 1, 1))
  const lead = (first.getUTCDay() + 6) % 7
  const rows: { iso: string; inMonth: boolean }[][] = []
  for (let r = 0; r < 6; r++) {
    const row: { iso: string; inMonth: boolean }[] = []
    for (let c = 0; c < 7; c++) {
      const d = new Date(Date.UTC(year, month - 1, 1 - lead + r * 7 + c))
      row.push({ iso: isoOf(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()), inMonth: d.getUTCMonth() === month - 1 })
    }
    rows.push(row)
  }
  return rows
}

export function addDays(iso: string, n: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1, d + n))
  return isoOf(dt.getUTCFullYear(), dt.getUTCMonth() + 1, dt.getUTCDate())
}

export function addMonths(iso: string, n: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  const total = y * 12 + (m - 1) + n
  const ny = Math.floor(total / 12)
  const nm = (total % 12) + 1
  return isoOf(ny, nm, Math.min(d, daysIn(ny, nm)))
}
