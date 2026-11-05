import { describe, expect, it } from 'vitest'
import { addMonths, combineDateTime, formatDateText, maskDate, maskTime, monthGrid, parseDate, parseTime, splitDateTime } from '@/components/ui/dateTimeModel'

describe('dateTimeModel', () => {
  it('parses day-first in ru and year-first in en, refuses a swapped en text', () => {
    expect(parseDate('05-11-2026', 'ru')).toEqual({ iso: '2026-11-05' })
    expect(parseDate('05.11.2026', 'kk')).toEqual({ iso: '2026-11-05' })
    expect(parseDate('2026-11-05', 'ru')).toEqual({ iso: '2026-11-05' })
    expect(parseDate('2026-11-05', 'en')).toEqual({ iso: '2026-11-05' })
    expect(parseDate('05-11-2026', 'en')).toEqual({ error: 'format' })
    expect(parseDate('31-02-2026', 'ru')).toEqual({ error: 'exists' })
  })
  it('formats and masks', () => {
    expect(formatDateText('2026-11-05', 'ru')).toBe('05-11-2026')
    expect(formatDateText('2026-11-05', 'en')).toBe('2026-11-05')
    expect(maskDate('05112026', 'ru')).toBe('05-11-2026')
    expect(maskDate('20261105', 'en')).toBe('2026-11-05')
    expect(maskDate('5-', 'ru')).toBe('05-')
    expect(maskDate('2026-11-05', 'ru')).toBe('05-11-2026')
  })
  it('time: lenient forms, range and single digit', () => {
    for (const t of ['9:30', '930', '0930', '09.30', '09:30']) expect(parseTime(t)).toEqual({ time: '09:30' })
    expect(parseTime('9')).toEqual({ error: 'format' })
    expect(parseTime('25:00')).toEqual({ error: 'range' })
    expect(maskTime('0930')).toBe('09:30')
  })
  it('date-time pair and calendar grid', () => {
    expect(splitDateTime('2026-11-05T09:30')).toEqual({ date: '2026-11-05', time: '09:30' })
    expect(combineDateTime('2026-11-05', '')).toBe('')
    expect(combineDateTime('2026-11-05', '09:30')).toBe('2026-11-05T09:30')
    const g = monthGrid(2026, 11)
    expect(g).toHaveLength(6)
    expect(g[0][0].iso).toBe('2026-10-26')
    expect(addMonths('2026-01-31', 1)).toBe('2026-02-28')
  })
})
