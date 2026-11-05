/** format — REQ-285
 *
 *  Locale-aware date/time formatting helpers, built on react-intl's imperative
 *  API (decision 0021: `docs/migration/decisions/0021-web-i18n-library.md`).
 *  Plain functions, not hooks -- callable uniformly from module-scope helper
 *  functions and from inside component bodies/JSX alike, which is why
 *  react-intl's `createIntl()` was chosen over a hook-only API (most of the
 *  call sites this module replaces are module-scope helpers, not JSX-inline
 *  expressions -- see the design doc §d).
 */

import { createIntl, createIntlCache, type IntlShape } from 'react-intl'
import { FALLBACK_LOCALE, getSessionLocale } from './sessionLocale'
import { getUiLocale } from './uiLocaleStore'

const intlCache = createIntlCache()

let memoizedIntl: IntlShape | null = null
let memoizedLocale: string | null = null

/** Returns a memoized `IntlShape` for the current session locale. The session
 *  locale does not change after SPA bootstrap in this requirement's scope (see
 *  sessionLocale.ts), so this is effectively a session-lifetime singleton, not
 *  re-created per call -- but it re-derives if the session locale ever does
 *  change (e.g. under test, across resets), rather than caching once forever. */
export function getIntl(): IntlShape {
  const locale = getSessionLocale()
  if (memoizedIntl && memoizedLocale === locale) {
    return memoizedIntl
  }
  memoizedIntl = createIntl(
    {
      locale,
      defaultLocale: FALLBACK_LOCALE,
      // No translation catalogue exists yet -- REQ-285's scope is date/time
      // formatting only (see docs/frontend/frontend-requirements.md's Locale
      // policy section); none of this module's usage calls formatMessage.
      messages: {},
    },
    intlCache,
  )
  memoizedLocale = locale
  return memoizedIntl
}

/** Test-only: forces the next getIntl() call to rebuild rather than reuse the
 *  memoized shape. Needed because getSessionLocale() is read once and cached;
 *  tests that flip the session locale between assertions call this to avoid
 *  observing a stale cached IntlShape. */
export function _resetIntlCacheForTests(): void {
  memoizedIntl = null
  memoizedLocale = null
}

/** Languages whose dates are shown `DD-MM-YYYY` (date-time `DD-MM-YYYY HH:mm`), owner rule of 2026-11-05.
 *  `uz` is honoured when passed as `locale`; it is not a switcher language (`UI_LOCALES` is unchanged). */
export const DDMMYYYY_LANGS: readonly string[] = ['ru', 'kk', 'uz']

/** True when `locale` (default: the UI language, read now) uses the `DD-MM-YYYY` family. */
export function usesDayFirstDashes(locale?: string): boolean {
  const base = (locale ?? getUiLocale()).split('-')[0].toLowerCase()
  return DDMMYYYY_LANGS.includes(base)
}

type Parts = { year: string; month: string; day: string; hour: string; minute: string; second: string }

const DATE_ONLY = /^(\d{4})-(\d{2})-(\d{2})$/

function partsOf(value: Date | string | number, timeZone?: string): Parts | null {
  if (typeof value === 'string') {
    const m = DATE_ONLY.exec(value)
    if (m) return { year: m[1], month: m[2], day: m[3], hour: '00', minute: '00', second: '00' }
  }
  const d = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(d.getTime())) return null
  const out: Record<string, string> = {}
  for (const p of new Intl.DateTimeFormat('en-GB', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(d))
    out[p.type] = p.value
  return out as Parts
}

const isBlank = (v: unknown): boolean => v === null || v === undefined || v === ''

function hasTimeOptions(o?: Intl.DateTimeFormatOptions): boolean {
  return !!o && (o.timeStyle !== undefined || o.hour !== undefined || o.minute !== undefined || o.second !== undefined)
}

function dayFirst(
  value: Date | string | number,
  withDate: boolean,
  withTime: boolean,
  seconds: boolean,
  timeZone?: string,
): string {
  const p = partsOf(value, timeZone)
  if (!p) return String(value)
  const date = `${p.day}-${p.month}-${p.year}`
  const time = `${p.hour}:${p.minute}${seconds ? `:${p.second}` : ''}`
  return withDate && withTime ? `${date} ${time}` : withDate ? date : time
}

/** Date. In ru, kk, uz: `DD-MM-YYYY` (with ` HH:mm` when `options` ask for a time part); other languages: react-intl.
 *  null, undefined and '' give ''; a value that is not a date comes back as text. */
export function formatDate(
  value: Date | string | number | null | undefined,
  options?: Intl.DateTimeFormatOptions,
  locale?: string,
): string {
  if (isBlank(value)) return ''
  const v = value as Date | string | number
  if (usesDayFirstDashes(locale)) {
    return dayFirst(v, true, hasTimeOptions(options), options?.second !== undefined, options?.timeZone)
  }
  return safeIntl(() => getIntl().formatDate(v, options), v)
}

export function formatTime(
  value: Date | string | number | null | undefined,
  options?: Intl.DateTimeFormatOptions,
  locale?: string,
): string {
  if (isBlank(value)) return ''
  const v = value as Date | string | number
  if (usesDayFirstDashes(locale)) {
    return dayFirst(v, false, true, options?.second !== undefined, options?.timeZone)
  }
  return safeIntl(() => getIntl().formatTime(v, options), v)
}

/** Combines date and time, locale-aware. react-intl's `IntlShape` has no
 *  single combined method the way `Date.prototype.toLocaleString()` does;
 *  this composes a single `formatDate` call carrying both date and time
 *  component options (decision left open by the design doc §d.2 -- either
 *  composition satisfies the behavioural contract). In ru, kk, uz:
 *  `DD-MM-YYYY HH:mm` (seconds only when `options.second` is set). */
export function formatDateTime(
  value: Date | string | number | null | undefined,
  options?: Intl.DateTimeFormatOptions,
  locale?: string,
): string {
  if (isBlank(value)) return ''
  const v = value as Date | string | number
  if (usesDayFirstDashes(locale)) {
    return dayFirst(v, true, true, options?.second !== undefined, options?.timeZone)
  }
  return safeIntl(
    () =>
      getIntl().formatDate(v, {
        year: 'numeric',
        month: 'numeric',
        day: 'numeric',
        hour: 'numeric',
        minute: 'numeric',
        second: 'numeric',
        ...options,
      }),
    v,
  )
}

/** react-intl logs and returns the input for an invalid date, but can throw for odd values; never throw to a screen. */
function safeIntl(run: () => string, fallback: Date | string | number): string {
  if (!DATE_ONLY.test(String(fallback)) && Number.isNaN(new Date(fallback).getTime())) return String(fallback)
  try {
    return run()
  } catch {
    return String(fallback)
  }
}

export interface ZonedOptions {
  timeZone: string
  seconds?: boolean
  locale?: string
  /** What `en` (and other languages) show: `intl` = `Intl.DateTimeFormat(locale)` as before, `iso` = `YYYY-MM-DD HH:mm`. */
  enStyle?: 'intl' | 'iso'
  /** Locale tag handed to `Intl.DateTimeFormat` in the `intl` style (the page's react-intl locale). */
  intlLocale?: string
}

/** A date-time in a fixed zone (the tenant zone of the stock screens). One formatter for the stock tables. */
export function formatDateTimeInZone(value: Date | string | number | null | undefined, o: ZonedOptions): string {
  if (isBlank(value)) return ''
  const v = value as Date | string | number
  const p = partsOf(v, o.timeZone)
  if (!p) return String(value)
  if (usesDayFirstDashes(o.locale)) {
    return `${p.day}-${p.month}-${p.year} ${p.hour}:${p.minute}${o.seconds ? `:${p.second}` : ''}`
  }
  if (o.enStyle === 'iso') return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`
  const d = v instanceof Date ? v : new Date(v)
  return new Intl.DateTimeFormat(o.intlLocale ?? o.locale ?? getUiLocale(), {
    timeZone: o.timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    ...(o.seconds ? { second: '2-digit' as const } : {}),
    hourCycle: 'h23',
  }).format(d)
}

/** The raw value of a native date / datetime-local input (`YYYY-MM-DD`, `YYYY-MM-DDTHH:mm`, already local) shown
 *  in the UI language's format. Regex, no `Date`: the day never moves. Empty or malformed -> ''. For en the value is
 *  returned as `YYYY-MM-DD[ HH:mm]`. */
export function formatLocalInput(value: string | null | undefined, kind: 'date' | 'datetime', locale?: string): string {
  if (!value) return ''
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/.exec(value)
  if (!m) return ''
  if (kind === 'datetime' && m[4] === undefined) return ''
  const dayFirstFmt = usesDayFirstDashes(locale)
  const date = dayFirstFmt ? `${m[3]}-${m[2]}-${m[1]}` : `${m[1]}-${m[2]}-${m[3]}`
  return kind === 'datetime' ? `${date} ${m[4]}:${m[5]}` : date
}
