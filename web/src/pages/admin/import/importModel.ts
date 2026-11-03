/** importModel -- GH 3650 / REQ-675. Types of the import answer, the reason table and error classification. */

export const XLSX_CONTENT_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
export const MAX_FILE_BYTES = 2_097_152

/** Reason types a row result can carry (import_reason_json/1, the csv/xlsx cell reasons, REQ-654 functions). */
export const ROW_REASON_TYPES = [
  'record_payload_invalid',
  'record_size_exceeded',
  'definition_not_found',
  'payload_validation_failed',
  'idempotency_key_reuse',
  'entity_type_managed',
  'definition_changed',
  'external_ref_invalid',
  'external_ref_record_deleted',
  'external_ref_contention',
  'duplicate_external_ref_in_request',
  'field_restricted',
  'entity_append_only',
  'tenant_not_provisioned',
  'invalid_schema_name',
  'trigger_backlog_full',
  'reference_not_found',
  'reference_inactive',
  'cycle',
  'parent_inactive',
  'parent_not_found',
  'node_not_found',
  'field_not_allowed',
  'field_invalid',
  'unit_inactive',
  'unit_not_found',
  'legal_entity_inactive',
  'legal_entity_not_found',
  'site_inactive',
  'site_not_found',
  'position_inactive',
  'position_not_found',
  'position_not_in_unit',
  'user_not_found',
  'employee_inactive',
  'employee_not_found',
  'depth_exceeded',
  'node_has_grants',
  'item_inactive',
  'item_not_found',
  'lot_not_found',
  'internal_error',
  'csv_cell_count',
  'xlsx_cell_count',
  'csv_invalid_integer',
  'csv_invalid_decimal',
  'csv_invalid_boolean',
  'csv_invalid_date',
  'csv_invalid_datetime',
  'csv_invalid_json',
  'csv_invalid_localized_text',
] as const

export interface ImportViolation {
  code?: string
  path?: string | string[]
  message?: string
}

export interface ImportReason {
  type: string
  header?: string
  violations?: ImportViolation[]
  limit?: string
}

export interface ImportResultRow {
  status: 'ok' | 'error'
  line?: number
  outcome?: 'created' | 'updated' | 'unchanged'
  external_ref?: { system?: string; id?: string }
  reason?: ImportReason
}

export interface ImportAnswer {
  results: ImportResultRow[]
  dry_run?: boolean
}

export interface ImportCounts {
  created: number
  updated: number
  unchanged: number
  refused: number
}

export function countResults(results: ImportResultRow[]): ImportCounts {
  const counts: ImportCounts = { created: 0, updated: 0, unchanged: 0, refused: 0 }
  for (const row of results) {
    if (row.status === 'error') counts.refused += 1
    else if (row.outcome === 'created') counts.created += 1
    else if (row.outcome === 'updated') counts.updated += 1
    else if (row.outcome === 'unchanged') counts.unchanged += 1
  }
  return counts
}

/** Detail texts of the 422 answers (@xlsx_refusal_details and the dry run refusal) to a message id suffix. */
export const UNPROCESSABLE_DETAILS: Record<string, string> = {
  'xlsx file is not readable': 'xlsx_unreadable',
  'xlsx file is too large when uncompressed': 'xlsx_too_large',
  'xlsx file has no header row': 'xlsx_header_missing',
  'xlsx header has a duplicate column': 'xlsx_duplicate_header',
  'xlsx header has a column that is not a field of the entity type': 'xlsx_unknown_header',
  'external_ref_system and external_ref_id must be given together': 'xlsx_external_ref_pair',
  'dry_run unavailable: too many rows refused by the database': 'dry_run_unavailable',
}

export type ImportErrorKind =
  | { kind: 'limits' }
  | { kind: 'xlsx'; code: string }
  | { kind: 'unprocessable'; detail: string }
  | { kind: 'notAvailable' }
  | { kind: 'forbidden' }
  | { kind: 'busy' }
  | { kind: 'other' }

export function classifyImportError(err: unknown): ImportErrorKind {
  const e = err as { status?: unknown; details?: unknown } | null | undefined
  const status = e && typeof e === 'object' ? e.status : undefined
  if (status === 413) return { kind: 'limits' }
  if (status === 404) return { kind: 'notAvailable' }
  if (status === 403) return { kind: 'forbidden' }
  if (status === 503) return { kind: 'busy' }
  if (status === 422) {
    const details = e?.details as { detail?: unknown } | undefined
    const detail = typeof details?.detail === 'string' ? details.detail : ''
    const code = Object.hasOwn(UNPROCESSABLE_DETAILS, detail) ? UNPROCESSABLE_DETAILS[detail] : undefined
    return code ? { kind: 'xlsx', code } : { kind: 'unprocessable', detail }
  }
  return { kind: 'other' }
}

/** Violation path as one field label. */
export function violationField(v: ImportViolation): string {
  if (Array.isArray(v.path)) return v.path.join('.')
  return v.path ?? ''
}
