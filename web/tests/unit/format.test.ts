/**
 * Unit tests — REQ-285: locale-aware date/time formatting helpers
 * (`web/src/i18n/format.ts`), built on react-intl's imperative `createIntl()`
 * API per decision 0021.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { formatDate, formatTime, formatDateTime, formatDateTimeInZone, formatLocalInput, _resetIntlCacheForTests } from '@/i18n/format'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { useSessionLocaleStore, resolveSessionLocale } from '@/i18n/sessionLocale'

function setLocale(locale: string) {
  useSessionLocaleStore.setState({ locale: locale as never })
  _resetIntlCacheForTests()
}

describe('REQ-285 — formatDate/formatTime/formatDateTime', () => {
  beforeEach(() => {
    useSessionLocaleStore.setState({ locale: resolveSessionLocale({ browserLocales: [] }) })
    _resetIntlCacheForTests()
  })

  const sample = new Date(Date.UTC(2026, 0, 15, 13, 30, 0)) // 2026-01-15T13:30:00Z

  it('formatDate renders a locale-aware date string (en)', () => {
    setLocale('en')
    const result = formatDate(sample)
    expect(typeof result).toBe('string')
    expect(result.length).toBeGreaterThan(0)
  })

  it('formatTime renders a locale-aware time string (en)', () => {
    setLocale('en')
    const result = formatTime(sample)
    expect(typeof result).toBe('string')
    expect(result.length).toBeGreaterThan(0)
  })

  it('formatDateTime renders both date and time components', () => {
    setLocale('en')
    const dateOnly = formatDate(sample)
    const timeOnly = formatTime(sample)
    const combined = formatDateTime(sample)
    // The combined output should carry more information than either alone --
    // concretely, it is not identical to just the date or just the time.
    expect(combined).not.toBe(dateOnly)
    expect(combined).not.toBe(timeOnly)
  })

  it('formatting is driven by the session locale -- different locales can format differently', () => {
    setLocale('en-US')
    const us = formatDate(sample)
    setLocale('fr-FR')
    const fr = formatDate(sample)
    // en-US and fr-FR use different date component orders/separators for the
    // same instant; this is what "locale-aware" means concretely.
    expect(us).not.toBe(fr)
  })

  it('accepts string and numeric timestamp inputs, not just Date objects', () => {
    setLocale('en')
    const iso = '2026-01-15T13:30:00.000Z'
    expect(() => formatDate(iso)).not.toThrow()
    expect(() => formatDateTime(sample.getTime())).not.toThrow()
  })

  it('no call in this module ever hardcodes a locale (AC5) -- formatting follows getSessionLocale()', () => {
    setLocale('es-ES')
    const es = formatDate(sample)
    setLocale('de-DE')
    const de = formatDate(sample)
    expect(es).not.toBe(de)
  })
})

describe('T-1381 — DD-MM-YYYY in ru, kk, uz; en unchanged', () => {
  const instant = '2026-11-10T04:30:00Z' // 09:30 in Asia/Almaty
  const zone = 'Asia/Almaty'
  const sample = new Date(Date.UTC(2026, 0, 15, 13, 30, 0))

  it.each(['ru', 'kk', 'uz', 'ru-RU'])('F1 %s: date and date-time', (loc) => {
    expect(formatDate(instant, { timeZone: zone }, loc)).toBe('10-11-2026')
    expect(formatDateTime(instant, { timeZone: zone }, loc)).toBe('10-11-2026 09:30')
    expect(formatDateTime(instant, { timeZone: zone, second: 'numeric' }, loc)).toBe('10-11-2026 09:30:00')
    expect(formatTime(instant, { timeZone: zone }, loc)).toBe('09:30')
    expect(formatDateTimeInZone(instant, { timeZone: zone, locale: loc })).toBe('10-11-2026 09:30')
    expect(formatDateTimeInZone(instant, { timeZone: zone, locale: loc, seconds: true })).toBe('10-11-2026 09:30:00')
  })
  it('F1 date-style options with a time part add HH:mm; midnight is 00:05, the zone can move the day', () => {
    expect(formatDate(instant, { dateStyle: 'medium', timeStyle: 'short', timeZone: zone }, 'ru')).toBe('10-11-2026 09:30')
    expect(formatDateTime('2026-11-09T19:05:00Z', { timeZone: zone }, 'kk')).toBe('10-11-2026 00:05')
    expect(formatDateTimeInZone('2026-11-09T23:30:00Z', { timeZone: zone, locale: 'ru' })).toBe('10-11-2026 04:30')
  })
  it('F1 a date-only string never shifts the day', () => {
    expect(formatDate('2026-11-10', undefined, 'ru')).toBe('10-11-2026')
  })
  it('F1 the UI language store drives the default', () => {
    useUiLocaleStore.getState().setLocaleTransient('ru')
    try {
      expect(formatDate(instant, { timeZone: zone })).toBe('10-11-2026')
    } finally {
      useUiLocaleStore.getState().reloadFromEnvironment()
    }
  })
  it('F2 en output is the pre-change output', () => {
    setLocale('en')
    expect(formatDate(sample, { timeZone: 'UTC' }, 'en')).toBe('1/15/2026')
    expect(formatDateTime(sample, { timeZone: 'UTC' }, 'en')).toBe('1/15/2026, 1:30:00 PM')
    expect(formatDateTimeInZone(instant, { timeZone: zone, locale: 'en', enStyle: 'iso' })).toBe('2026-11-10 09:30')
    expect(formatDateTimeInZone(instant, { timeZone: zone, locale: 'en', intlLocale: 'en' })).toBe('11/10/2026, 09:30')
    expect(formatDateTimeInZone(instant, { timeZone: zone, locale: 'en', intlLocale: 'en', seconds: true })).toBe('11/10/2026, 09:30:00')
  })
  it.each(['en', 'ru'])('F3 %s: null, undefined and empty give an empty string; garbage comes back as text', (loc) => {
    for (const fn of [
      (v: unknown) => formatDate(v as string, undefined, loc),
      (v: unknown) => formatTime(v as string, undefined, loc),
      (v: unknown) => formatDateTime(v as string, undefined, loc),
      (v: unknown) => formatDateTimeInZone(v as string, { timeZone: zone, locale: loc }),
    ]) {
      expect(fn(null)).toBe('')
      expect(fn(undefined)).toBe('')
      expect(fn('')).toBe('')
      expect(fn('not a date')).toBe('not a date')
    }
  })
  it('F4 formatLocalInput', () => {
    expect(formatLocalInput('2026-11-03', 'date', 'ru')).toBe('03-11-2026')
    expect(formatLocalInput('2026-11-03T09:05', 'datetime', 'kk')).toBe('03-11-2026 09:05')
    expect(formatLocalInput('2026-11-03T09:05', 'datetime', 'en')).toBe('2026-11-03 09:05')
    expect(formatLocalInput('2026-11-03', 'date', 'en')).toBe('2026-11-03')
    expect(formatLocalInput('2026-11-03', 'datetime', 'ru')).toBe('')
    expect(formatLocalInput('garbage', 'date', 'ru')).toBe('')
    expect(formatLocalInput('', 'date', 'ru')).toBe('')
    expect(formatLocalInput(null, 'date', 'ru')).toBe('')
  })
})
