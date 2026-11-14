/** documentsModel — T-1334 / C14. Pure helpers of the asset document screens: kinds, states, reverse reasons, the
 *  closed list of refusals, what each state allows, the sides of a document and the tenant-zone time. */
import { formatDateTimeInZone } from '@/i18n/format'
import { ASSETS_POST, ASSETS_REVERSE } from '../assetsPermissions'
import { ASSETS_TIME_ZONE } from '../register/registerModel'
import type { AssetDocument } from './assetDocuments.api'

export const DOC_KINDS = ['commission', 'change', 'handover', 'writeoff', 'kind_change', 'opening'] as const
export type DocKind = (typeof DOC_KINDS)[number]
export const DOC_STATES = ['draft', 'issued', 'posted', 'reversed', 'cancelled'] as const
/** `Posting.@reasons` (lib/letflow/modules/assets/documents/posting.ex). */
export const REVERSE_REASONS = ['wrong_document', 'wrong_quantity', 'wrong_master_data', 'other'] as const
/** `Shape.@reason_codes` (documents/shape.ex). */
export const WRITEOFF_REASONS = ['disposed', 'lost', 'broken', 'expired', 'other'] as const
export const TEXT_MAX = 500

/** Every reason the document routes answer on the actions of this screen (router `@doc_conflicts`, `doc_refuse/2`, the
 *  issue-time checks of `checks.ex` and the shape reasons). Each has its own message; a reason outside the list is
 *  shown with the generic text. */
export const DOC_REASONS = [
  'document_not_draft', 'document_not_posted', 'document_reversed', 'reversal_pending', 'posting_inconsistent',
  'definition_not_active', 'busy', 'reason_invalid', 'invalid_filter', 'not_found',
  'event_time_too_old', 'event_time_in_future', 'org_unit_not_active', 'employee_not_active', 'card_not_active',
  'duplicate_asset', 'quantity_invalid', 'org_unit_mismatch', 'location_not_allowed', 'location_required',
  'not_linked', 'asset_already_in_register', 'sides_equal',
  'unknown_kind', 'field_not_allowed', 'field_required', 'field_invalid', 'lines_count', 'reason_required',
  'event_time_invalid',
  // Change of kind (REQ-759): the reasons of kind_change_checks.ex and of the stock tracking check (`tracking_reason`).
  'item_not_active', 'unit_not_valid', 'lot_not_valid', 'lot_required', 'lot_not_allowed', 'lot_expiry_missing',
  'tracking_invalid', 'location_not_active', 'inventory_number_taken',
  // Opening (decision 0083): the issue-time refusals that are not line checks, and the external reference pair.
  'register_unreadable', 'external_ref_taken', 'external_ref_pair',
] as const

export interface DocumentsErrorInfo {
  status?: number
  reason?: string
  field?: string
  lineNo?: number
  /** `stock` | `asset`: which side of a change of kind a `not_linked` refusal names. */
  side?: string
}

/** The reason, field and line number of a refusal (RFC 9457 members arrive in ApiError.details). */
export function documentErrorInfo(err: unknown): DocumentsErrorInfo {
  const e = err as { status?: unknown; details?: Record<string, unknown> } | null | undefined
  const info: DocumentsErrorInfo = {}
  if (e && typeof e === 'object') {
    if (typeof e.status === 'number') info.status = e.status
    const d = e.details
    if (d && typeof d === 'object') {
      if (typeof d['reason'] === 'string') info.reason = d['reason']
      if (typeof d['field'] === 'string') info.field = d['field']
      if (typeof d['line_no'] === 'number') info.lineNo = d['line_no']
      if (typeof d['side'] === 'string') info.side = d['side']
    }
  }
  return info
}

/** Message id of a refusal; lookup in a closed list, never the server's free text. */
export function documentErrorMessageId(err: unknown): string {
  const info = documentErrorInfo(err)
  if (info.status === 403) return 'assets.doc.error.forbidden'
  if (info.status === 404) return 'assets.doc.error.notFound'
  if (info.reason !== undefined && (DOC_REASONS as readonly string[]).includes(info.reason)) return `assets.doc.error.${info.reason}`
  if (info.status === 422 || info.status === 409) return 'assets.doc.error.unknown'
  return 'assets.doc.error.generic'
}

export const PRINT_KINDS = ['commission', 'change', 'handover', 'writeoff'] as const
export const PRINT_STATES = ['issued', 'posted', 'reversed'] as const
export const PRINT_REASONS = ['document_not_issued', 'print_not_available', 'print_unsupported_character', 'invalid_lang', 'invalid_form', 'invalid_format'] as const

/** T-1915: the plain act exists for an issued, posted or reversed commission, change, hand over or write-off. */
export function documentPrintable(doc: { kind: string; state: string }): boolean {
  return (PRINT_KINDS as readonly string[]).includes(doc.kind) && (PRINT_STATES as readonly string[]).includes(doc.state)
}

/** Message id of a refused print: its own 422 reason, 404 not found, anything else (403 included) the generic message. */
export function printErrorMessageId(err: unknown): string {
  const info = documentErrorInfo(err)
  if (info.status === 422 && info.reason !== undefined && (PRINT_REASONS as readonly string[]).includes(info.reason)) return `assets.doc.print.reason.${info.reason}`
  if (info.status === 404) return 'assets.doc.error.notFound'
  return 'assets.doc.error.generic'
}

export function formatEventTime(iso: string | null | undefined, locale: string, dash: string, tz: string = ASSETS_TIME_ZONE): string {
  if (!iso) return dash
  return formatDateTimeInZone(iso, { timeZone: tz, locale })
}

/** Kinds whose reversal the server refuses: `Posting.reverse/6` answers `posting_inconsistent` for a change of kind
 *  (`not_kind_change/1`, posting.ex) until the pair reversal (REQ-760 part B) exists. Remove the entry when it lands. */
export const REVERSE_KINDS_CLOSED: readonly string[] = ['kind_change']

export interface DocActions {
  edit: boolean
  discard: boolean
  issue: boolean
  reverse: boolean
}

/** Buttons by state and by the access atom of the route (convenience only: the server enforces). Edit is the draft form
 *  (replace route, T-1469); there is no Retry posting or Cancel: the assets router has no such routes (post is the inbox step). */
export function actionsFor(state: string, can: (atom: string) => boolean, kind?: string): DocActions {
  const post = can(ASSETS_POST)
  const rev = can(ASSETS_REVERSE)
  return {
    edit: state === 'draft' && post,
    discard: state === 'draft' && post,
    issue: state === 'draft' && post,
    reverse: state === 'posted' && rev && !(kind !== undefined && REVERSE_KINDS_CLOSED.includes(kind)),
  }
}

/** Reverse dialog check: a message id or null. `other` needs a text; at most TEXT_MAX characters. */
export function reasonTextError(code: string, text: string): string | null {
  if (code === 'other' && text.trim() === '') return 'assets.doc.error.reasonTextRequired'
  if (text.length > TEXT_MAX) return 'assets.doc.error.textTooLong'
  return null
}

export interface SideView {
  orgUnitId: string | null | undefined
  locationId: string | null | undefined
  responsibleId: string | null | undefined
  userId: string | null | undefined
}

/** The from and to side of a document, from the header keys of its kind (mirrors `Kinds.sides/2`): change moves the
 *  responsible and the user inside one org unit and location; handover moves between two org units and locations;
 *  commission and writeoff have one side (the same on both). */
export function sidesOf(doc: AssetDocument): { from: SideView; to: SideView } {
  switch (doc.kind) {
    case 'opening': {
      // No sides: the place and the people are per line (0083 D3); only the org unit is on the header.
      const none = { orgUnitId: doc.org_unit_id, locationId: null, responsibleId: null, userId: null }
      return { from: none, to: none }
    }
    case 'kind_change': {
      // No sides: the stock side and the asset side are per line (never read for this kind).
      const none = { orgUnitId: doc.org_unit_id, locationId: null, responsibleId: null, userId: null }
      return { from: none, to: none }
    }
    case 'change':
      return {
        from: { orgUnitId: doc.org_unit_id, locationId: doc.location_id, responsibleId: doc.from_material_responsible_id, userId: doc.from_actual_user_id },
        to: { orgUnitId: doc.org_unit_id, locationId: doc.location_id, responsibleId: doc.to_material_responsible_id, userId: doc.to_actual_user_id },
      }
    case 'handover':
      return {
        from: { orgUnitId: doc.org_unit_id, locationId: doc.from_location_id, responsibleId: doc.from_material_responsible_id, userId: doc.from_actual_user_id },
        to: { orgUnitId: doc.to_org_unit_id, locationId: doc.to_location_id, responsibleId: doc.to_material_responsible_id, userId: doc.to_actual_user_id },
      }
    default: {
      const side = { orgUnitId: doc.org_unit_id, locationId: doc.location_id, responsibleId: doc.material_responsible_id, userId: doc.actual_user_id }
      return { from: side, to: side }
    }
  }
}

/** Two-side kinds show a From and a To group in the header card. */
export const isTwoSide = (kind: string): boolean => kind === 'change' || kind === 'handover'

/** The header keys each kind carries, copied from `Kinds.header_keys` (a test pins a drift). */
export const HEADER_KEYS: Record<DocKind, readonly string[]> = {
  commission: ['org_unit_id', 'location_id', 'material_responsible_id', 'actual_user_id', 'event_time', 'note'],
  change: ['org_unit_id', 'location_id', 'from_material_responsible_id', 'from_actual_user_id', 'to_material_responsible_id', 'to_actual_user_id', 'event_time', 'note'],
  handover: ['org_unit_id', 'from_location_id', 'from_material_responsible_id', 'from_actual_user_id', 'to_org_unit_id', 'to_location_id', 'to_material_responsible_id', 'to_actual_user_id', 'event_time', 'note'],
  writeoff: ['org_unit_id', 'location_id', 'material_responsible_id', 'actual_user_id', 'reason_code', 'reason_text', 'event_time', 'note'],
  kind_change: ['org_unit_id', 'event_time', 'reason_text', 'note'],
  opening: ['org_unit_id', 'note', 'external_ref_system', 'external_ref_id'],
}
