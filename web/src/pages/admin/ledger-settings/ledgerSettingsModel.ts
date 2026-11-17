/** Pure helpers of the Negative balances screen (REQ-839): readable names, error mapping. */
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { ledgerSettingsMessages } from './ledgerSettingsMessages'

/** Register display name: the catalog name of a known module, else the registration name itself. */
export function registrationName(registration: string, locale: UiLocale): string {
  const m = ledgerSettingsMessages[locale]
  const id = `ledgerSettings.registration.${registration}`
  return Object.hasOwn(m, id) ? m[id] : registration
}

/** Message id of a failed save. The server's code is `details.detail` (RFC 9457 body kept by the client). */
export function saveErrorKey(err: unknown): string {
  const e = err as { status?: unknown; details?: { detail?: unknown } } | null
  const detail = typeof e?.details?.detail === 'string' ? e.details.detail : null
  if (detail === 'invalid_reason' || detail === 'not_switchable' || detail === 'concurrent_change') {
    return `ledgerSettings.error.${detail}`
  }
  if (e?.status === 409) return 'ledgerSettings.error.concurrent_change'
  if (e?.status === 403) return 'ledgerSettings.error.forbidden'
  return 'ledgerSettings.error.generic'
}
