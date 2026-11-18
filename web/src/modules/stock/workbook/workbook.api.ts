/** workbook.api — REQ-887. Calls of the stock workbook import routes (REQ-884, REQ-885, REQ-886). */
import { client } from '@/api/client'

const BASE = '/api/v1/modules/stock'
const XLSX_CONTENT_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

export interface WorkbookChange {
  /** Row number in the file, or null when the place is in the book only (not in the file — emptied). */
  row: number | null
  item_code: string
  item_name: string
  place_code: string
  book_quantity: string
  file_quantity: string
  difference: string
}

/** A remark from the server: row number (or null for file-level remarks) and Russian text. */
export interface WorkbookRemark {
  row: number | null
  text: string
}

export interface WorkbookCheckResult {
  sheet: string
  rows_read: number
  remarks: WorkbookRemark[]
  changes: WorkbookChange[]
  unchanged_count: number
  too_many_changes: boolean
}

/** 200 when no balance differs; 201 shape (distinguish by `applied === false`). */
export interface WorkbookApplyNoChange {
  applied: false
  changes: number
  remarks: WorkbookRemark[]
}

export interface WorkbookApplyCreated {
  document_id: string
  number: string
  lines: number
  remarks: WorkbookRemark[]
  approve_task_id: string | null
}

export type WorkbookApplyResult = WorkbookApplyNoChange | WorkbookApplyCreated

export interface WorkbookImportRow {
  document_id: string
  number: string | null
  created_at: string
  created_by: string | null
  file_name: string | null
  sheet: string | null
  lines: number
  remarks_count: number | null
  state: string
  reversal_pending: boolean
}

export interface WorkbookImportsBody {
  rows: WorkbookImportRow[]
}

export interface WorkbookCancelResult {
  action: 'cancelled' | 'reverse_pending'
  lines: number
}

export const workbookApi = {
  /** POST /stock-workbook/check: check a Qoimeks-layout workbook against one org unit's stock. */
  check: (orgUnitId: string, file: Blob): Promise<WorkbookCheckResult> =>
    client.postRaw<WorkbookCheckResult>(
      `${BASE}/stock-workbook/check?org_unit_id=${encodeURIComponent(orgUnitId)}`,
      file,
      XLSX_CONTENT_TYPE,
    ),

  /** POST /stock-workbook/apply: load a checked workbook as a quick count document. */
  apply: (orgUnitId: string, file: Blob, fileName: string): Promise<WorkbookApplyResult> =>
    client.postRaw<WorkbookApplyResult>(
      `${BASE}/stock-workbook/apply?org_unit_id=${encodeURIComponent(orgUnitId)}&file_name=${encodeURIComponent(fileName)}`,
      file,
      XLSX_CONTENT_TYPE,
    ),

  /** GET /stock-workbook/imports: list the last 50 workbook loads newest first. */
  imports: (): Promise<WorkbookImportsBody> =>
    client.get<WorkbookImportsBody>(`${BASE}/stock-workbook/imports`),

  /** POST /stock-workbook/imports/:id/cancel: cancel or start reversal of a load. */
  cancel: (id: string, reason: string): Promise<WorkbookCancelResult> =>
    client.post<WorkbookCancelResult>(`${BASE}/stock-workbook/imports/${id}/cancel`, { reason }),
}
