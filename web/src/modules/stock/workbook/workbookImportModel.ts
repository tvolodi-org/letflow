/** workbookImportModel — REQ-887. Pure helpers for the workbook import screen. */

export interface CancelDialogState {
  id: string
  lines: number
  reason: string
  busy: boolean
  error: string | null
}

/** Maps a check/apply API error to a message id. */
export function workbookCheckErrorId(err: unknown): string {
  const e = err as { status?: unknown; details?: { reason?: unknown; held_by?: unknown } } | null
  if (!e || typeof e !== 'object') return 'stock.wb.err.generic'
  const reason = e.details?.reason
  if (typeof reason === 'string') {
    switch (reason) {
      case 'org_unit_required': return 'stock.wb.err.org_unit_required'
      case 'org_unit_not_found': return 'stock.wb.err.org_unit_not_found'
      case 'xlsx_unreadable': return 'stock.wb.err.xlsx_unreadable'
      case 'header_missing': return 'stock.wb.err.header_missing'
      case 'workbook_too_large': return 'stock.wb.err.workbook_too_large'
      case 'too_many_changes': return 'stock.wb.err.too_many_changes'
      case 'count_in_progress': return 'stock.wb.err.count_in_progress'
    }
  }
  if ((e as { message?: unknown }).message === 'org_unit_required') return 'stock.wb.err.orgUnitRequired'
  if ((e as { message?: unknown }).message === 'file_required') return 'stock.wb.err.fileRequired'
  if ((e as { message?: unknown }).message === 'check_first') return 'stock.wb.err.checkFirst'
  return 'stock.wb.err.generic'
}

/** Maps a cancel API error to a message id. */
export function workbookCancelErrorId(err: unknown): string {
  const e = err as { status?: unknown; details?: { reason?: unknown } } | null
  if (!e || typeof e !== 'object') return 'stock.wb.err.generic'
  const reason = e.details?.reason
  if (typeof reason === 'string') {
    switch (reason) {
      case 'import_already_cancelled': return 'stock.wb.err.import_already_cancelled'
      case 'reason_required': return 'stock.wb.err.reason_required'
      case 'reason_too_long': return 'stock.wb.err.reason_too_long'
      case 'reversal_pending': return 'stock.wb.err.reversal_pending'
    }
  }
  if (typeof e.status === 'number' && e.status === 409) return 'stock.wb.err.reversal_pending'
  return 'stock.wb.err.generic'
}

import type { WorkbookImportRow } from './workbook.api'

/** Localized state label for a load row. */
export function formatState(row: WorkbookImportRow, t: (id: string) => string): string {
  if (row.reversal_pending) return t('stock.wb.loads.reversalPending')
  const key = `stock.wb.loads.state.${row.state}`
  return t(key)
}
