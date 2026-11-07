/** D-1 / T-TZ — GH 3735 R7: one date format per language, in the tenant zone. */
import { describe, expect, it } from 'vitest'
import { formatDateInZone, formatDateTimeInZone } from '../format'

const AT = '2026-11-05T11:24:00Z'

describe('D-1 formatDateTimeInZone', () => {
  it('en: Nov 5, 2026 16:24 (with seconds on request)', () => {
    expect(formatDateTimeInZone(AT, { timeZone: 'Asia/Almaty', locale: 'en' })).toBe('Nov 5, 2026 16:24')
    expect(formatDateTimeInZone('2026-11-05T11:24:09Z', { timeZone: 'Asia/Almaty', locale: 'en', seconds: true })).toBe('Nov 5, 2026 16:24:09')
  })
  it.each(['ru', 'kk', 'uz'])('%s: DD-MM-YYYY HH:mm', (locale) => {
    expect(formatDateTimeInZone(AT, { timeZone: 'Asia/Almaty', locale })).toBe('05-11-2026 16:24')
  })
  it('a date only', () => {
    expect(formatDateInZone(AT, { timeZone: 'Asia/Almaty', locale: 'en' })).toBe('Nov 5, 2026')
    expect(formatDateInZone(AT, { timeZone: 'Asia/Almaty', locale: 'ru' })).toBe('05-11-2026')
    expect(formatDateInZone(null, { timeZone: 'Asia/Almaty' })).toBe('')
  })
  it('the day follows the zone, not the browser', () => {
    expect(formatDateTimeInZone('2026-11-05T22:30:00Z', { timeZone: 'Asia/Almaty', locale: 'en' })).toBe('Nov 6, 2026 03:30')
  })
})
