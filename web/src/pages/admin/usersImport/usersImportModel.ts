/** usersImportModel -- T-1633 / REQ-791. Error classification, reason sentences and the refused-rows CSV of the
 *  users import screen. The answer shape and counts are shared with the master data import (importModel.ts). */
import type { UiLocale } from '@/i18n/uiLocaleStore'
import { classifyImportError, type ImportErrorKind, type ImportReason, type ImportResultRow } from '../import/importModel'
import { USERS_IMPORT_REASON_TYPES, usersImportMessages } from './usersImportMessages'

/** classifyImportError plus the one refusal it lacks: 422 with `code: xlsx_missing_header` and the missing headers
 *  (it keys on the detail text, which differs for this refusal). */
export function classifyUsersImportError(err: unknown): ImportErrorKind {
  const e = err as { status?: unknown; details?: unknown } | null | undefined
  if (e && typeof e === 'object' && e.status === 422) {
    const details = e.details as { code?: unknown; headers?: unknown } | undefined
    if (details?.code === 'xlsx_missing_header') {
      const headers = Array.isArray(details.headers) ? details.headers.filter((h): h is string => typeof h === 'string') : []
      return { kind: 'xlsx', code: 'xlsx_missing_header', ...(headers.length > 0 ? { headers } : {}) }
    }
  }
  return classifyImportError(err)
}

function fill(text: string, values: Record<string, string>): string {
  return text.replace(/\{(\w+)\}/g, (m, k: string) => values[k] ?? m)
}

/** True when the reason type has a localized sentence (else the generic one is used). */
export function isKnownUsersReason(type: string): boolean {
  return (USERS_IMPORT_REASON_TYPES as readonly string[]).includes(type)
}

/** The localized sentence of a refused row. The backend carries no cell text, so none is shown. */
export function usersReasonSentence(locale: UiLocale, reason: ImportReason): string {
  const cat = usersImportMessages[locale]
  if (reason.type === 'user_duplicate_in_file' && reason.header === 'email') return cat['usersImport.reason.user_duplicate_in_file_email'] ?? reason.type
  if (isKnownUsersReason(reason.type)) return cat[`usersImport.reason.${reason.type}`] ?? reason.type
  return fill(cat['usersImport.reason.unknown'] ?? reason.type, { type: reason.type })
}

/** Spreadsheet formula guard: a cell that starts like a formula gets a leading apostrophe. */
function csvCell(value: string): string {
  const safe = /^[=+\-@]/.test(value) ? `'${value}` : value
  return /[",\r\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe
}

const BOM = String.fromCharCode(0xfeff)

/** CSV of the refused rows (UTF-8 BOM, RFC 4180 quoting): row, column, reason. */
export function usersRefusedRowsCsv(locale: UiLocale, results: ImportResultRow[]): string {
  const cat = usersImportMessages[locale]
  const head = ['usersImport.csv.line', 'usersImport.csv.column', 'usersImport.csv.reason'].map((id) => cat[id] ?? id)
  const lines = [head.map(csvCell).join(',')]
  results.forEach((r, i) => {
    if (r.status !== 'error') return
    const reason = r.reason ? usersReasonSentence(locale, r.reason) : (cat['usersImport.error.other'] ?? '')
    lines.push([String(r.line ?? i + 1), r.reason?.header ?? '', reason].map(csvCell).join(','))
  })
  return `${BOM}${lines.join('\r\n')}\r\n`
}
