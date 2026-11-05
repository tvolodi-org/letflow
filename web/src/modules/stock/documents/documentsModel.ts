/** documentsModel — GH 3769 / REQ-722. Pure logic of the stock document screens: kinds, states and reasons, the form
 *  state and the exact request body, the checks done before sending, tenant-time-zone conversion, the action matrix
 *  and the mapping of a refusal to a message id.
 *
 *  Assumptions (owner may change at GATE B): buttons by permission atom and state; the tenant time zone is the
 *  constant of the register screens; a line's unit is the item's base unit; cancel needs a typed reason. */
import { STOCK_TIME_ZONE } from '../register/stockRegisterModel'
import { STOCK_POST, STOCK_REVERSE } from '../stockPermissions'
import type { DocumentLine, StockDocument } from './documents.api'

export const DOC_KINDS = ['receipt', 'issue', 'write_off'] as const
export type DocKind = (typeof DOC_KINDS)[number]
export const DOC_STATES = ['draft', 'issued', 'posted', 'reversed', 'cancelled'] as const
export const WRITE_OFF_REASONS = ['lost', 'damaged', 'used_up', 'other'] as const
export const REVERSE_REASONS = ['wrong_document', 'wrong_quantity', 'wrong_master_data', 'other'] as const
export const MAX_LINES = 100
export const TEXT_MAX = 500
export const REF_MAX = 200

/** The reasons of REQ-712..715 the screens show (criterion 5 of REQ-722). */
export const DOC_REASONS = [
  'unknown_kind', 'field_not_allowed', 'field_required', 'lines_count', 'quantity_invalid', 'price_invalid',
  'reason_invalid', 'document_not_draft', 'not_linked', 'employee_not_active', 'counterparty_not_active',
  'unit_not_valid', 'lot_not_valid', 'lot_required', 'lot_not_allowed', 'lot_expiry_missing',
  'tracking_policy_not_supported', 'received_on_after_event', 'event_time_too_old', 'event_time_in_future',
  'busy', 'posting_pending', 'document_posted', 'document_cancelled', 'document_not_posted', 'document_reversed',
  'reversal_pending', 'document_not_issued',
] as const
/** Real answers of main that the entry does not list (assumption: shown with their own message too). */
export const DOC_EXTRA_REASONS = ['field_invalid', 'event_time_invalid', 'definition_not_active', 'posting_inconsistent'] as const
const ALL_REASONS: readonly string[] = [...DOC_REASONS, ...DOC_EXTRA_REASONS]

// ---- refusals ----------------------------------------------------------------------------------------------

export interface DocumentsErrorInfo {
  status?: number
  reason?: string
  field?: string
  lineNo?: number
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
    }
  }
  return info
}

export function documentErrorMessageId(err: unknown): string {
  const info = documentErrorInfo(err)
  if (info.status === 403) return 'stock.doc.error.forbidden'
  if (info.status === 404) return 'stock.doc.error.notFound'
  if (info.reason !== undefined && ALL_REASONS.includes(info.reason)) return `stock.doc.error.${info.reason}`
  if (info.reason === 'invalid_filter') return 'stock.doc.error.invalid_filter'
  if (info.status === 422 || info.status === 409) return 'stock.doc.error.unknown'
  return 'stock.doc.error.generic'
}

// ---- numbers -----------------------------------------------------------------------------------------------

/** The server's quantity text: up to 15 integer digits, up to 9 decimals, no sign, no exponent, no leading zeros. */
const DECIMAL = /^(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?$/
export const isDecimalNonNegative = (v: string): boolean => DECIMAL.test(v)
export const isDecimalAboveZero = (v: string): boolean => DECIMAL.test(v) && /[1-9]/.test(v)

// ---- time zone ---------------------------------------------------------------------------------------------

function offsetMinutes(ms: number, tz: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(ms))
  const g = (t: string) => Number(parts.find((p) => p.type === t)?.value)
  const asUtc = Date.UTC(g('year'), g('month') - 1, g('day'), g('hour'), g('minute'), g('second'))
  return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / 60000)
}

function pad(n: number): string {
  return String(Math.abs(n)).padStart(2, '0')
}

/** `2026-11-04T10:00` in the tenant zone -> ISO 8601 with that zone's offset (`2026-11-04T10:00:00+05:00`). */
export function zonedLocalToIso(local: string, tz: string = STOCK_TIME_ZONE): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(local)
  if (!m) return null
  const asUtc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])
  let off = offsetMinutes(asUtc, tz)
  off = offsetMinutes(asUtc - off * 60000, tz)
  const sign = off < 0 ? '-' : '+'
  return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:00${sign}${pad(Math.trunc(off / 60))}:${pad(off % 60)}`
}

/** An ISO instant -> `YYYY-MM-DDTHH:mm` in the tenant zone (the value of a datetime-local input). */
export function isoToZonedLocal(iso: string | null | undefined, tz: string = STOCK_TIME_ZONE): string {
  if (!iso) return ''
  const ms = Date.parse(iso)
  if (Number.isNaN(ms)) return ''
  const d = new Date(ms + offsetMinutes(ms, tz) * 60000)
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`
}

export function nowZonedLocal(tz: string = STOCK_TIME_ZONE): string {
  return isoToZonedLocal(new Date().toISOString(), tz)
}

export function formatEventTime(iso: string | null | undefined, locale: string, dash: string, tz: string = STOCK_TIME_ZONE): string {
  if (!iso) return dash
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  return new Intl.DateTimeFormat(locale, {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).format(d)
}

// ---- actions -----------------------------------------------------------------------------------------------

export interface DocActions {
  edit: boolean
  discard: boolean
  issue: boolean
  retry: boolean
  cancel: boolean
  reverse: boolean
  /** The text that posting waits for the post task (shown to any reader of an issued document). */
  waiting: boolean
}

/** Buttons by state and by the access atom of the route (convenience only: the server enforces). */
export function actionsFor(state: string, can: (atom: string) => boolean, kind: string = 'receipt'): DocActions {
  const post = can(STOCK_POST)
  const rev = can(STOCK_REVERSE)
  const editable = (DOC_KINDS as readonly string[]).includes(kind)
  return {
    edit: state === 'draft' && post && editable,
    discard: state === 'draft' && post,
    issue: state === 'draft' && post,
    retry: state === 'issued' && post,
    cancel: (state === 'issued' || state === 'reversed') && rev,
    reverse: state === 'posted' && rev,
    waiting: state === 'issued',
  }
}

/** Reason dialog check (reverse and cancel): a message id or null. */
export function reasonTextError(code: string, text: string): string | null {
  if (code === 'other' && text.trim() === '') return 'stock.doc.error.reasonTextRequired'
  if (text.length > TEXT_MAX) return 'stock.doc.error.textTooLong'
  return null
}

// ---- form --------------------------------------------------------------------------------------------------

export interface LineForm {
  itemId: string
  uomId: string
  lotId: string
  quantity: string
  unitPrice: string
  lineValue: string
}
export interface FormState {
  kind: DocKind
  eventTime: string
  orgUnitId: string
  locationId: string
  responsibleId: string
  counterpartyId: string
  note: string
  supplierRef: string
  receivedOn: string
  reasonCode: string
  reasonText: string
  lines: LineForm[]
}

export const emptyLine = (): LineForm => ({ itemId: '', uomId: '', lotId: '', quantity: '', unitPrice: '', lineValue: '' })

export function emptyForm(kind: DocKind, eventTime: string = nowZonedLocal()): FormState {
  return {
    kind, eventTime, orgUnitId: '', locationId: '', responsibleId: '', counterpartyId: '', note: '',
    supplierRef: '', receivedOn: '', reasonCode: '', reasonText: '', lines: [emptyLine()],
  }
}

const s = (v: string | null | undefined): string => v ?? ''

export function lineFromDocument(l: DocumentLine): LineForm {
  return {
    itemId: s(l.catalog_item_id), uomId: s(l.catalog_uom_id), lotId: s(l.catalog_lot_id),
    quantity: s(l.quantity), unitPrice: s(l.unit_price), lineValue: s(l.line_value),
  }
}

export function formFromDocument(doc: StockDocument): FormState {
  const kind = (DOC_KINDS as readonly string[]).includes(doc.kind) ? (doc.kind as DocKind) : 'receipt'
  const lines = [...doc.lines].sort((a, b) => a.line_no - b.line_no).map(lineFromDocument)
  return {
    kind,
    eventTime: isoToZonedLocal(doc.event_time),
    orgUnitId: s(doc.org_unit_id), locationId: s(doc.location_id), responsibleId: s(doc.responsible_id),
    counterpartyId: s(doc.counterparty_id), note: s(doc.note),
    supplierRef: s(doc.supplier_document_ref), receivedOn: s(doc.received_on),
    reasonCode: s(doc.reason_code), reasonText: s(doc.reason_text),
    lines: lines.length > 0 ? lines : [emptyLine()],
  }
}

/** Header fields shown per kind (the form and the tests read the same table). */
export function headerFields(kind: DocKind): string[] {
  const base = ['eventTime', 'orgUnitId', 'locationId', 'responsibleId', 'note']
  if (kind === 'receipt') return [...base, 'counterpartyId', 'supplierRef', 'receivedOn']
  if (kind === 'write_off') return [...base, 'reasonCode', 'reasonText']
  return [...base, 'reasonText']
}

export interface FormCheck {
  /** Keys: `header.<field>`, `lines`, `lines.<i>.<field>`; values are message ids. */
  errors: Record<string, string>
}

export function validateForm(f: FormState): FormCheck {
  const errors: Record<string, string> = {}
  const req = (key: string, v: string) => {
    if (v.trim() === '') errors[`header.${key}`] = 'stock.doc.error.field_required'
  }
  if (zonedLocalToIso(f.eventTime) === null) errors['header.eventTime'] = 'stock.doc.error.field_required'
  req('orgUnitId', f.orgUnitId)
  req('locationId', f.locationId)
  req('responsibleId', f.responsibleId)
  if (f.note.length > TEXT_MAX) errors['header.note'] = 'stock.doc.error.textTooLong'
  if (f.kind === 'receipt') {
    if (f.supplierRef.length > REF_MAX) errors['header.supplierRef'] = 'stock.doc.error.textTooLong'
    if (f.receivedOn !== '' && f.eventTime.length >= 10 && f.receivedOn > f.eventTime.slice(0, 10)) {
      errors['header.receivedOn'] = 'stock.doc.error.received_on_after_event'
    }
  }
  if (f.kind === 'write_off') {
    if (!(WRITE_OFF_REASONS as readonly string[]).includes(f.reasonCode)) errors['header.reasonCode'] = 'stock.doc.error.field_required'
    else if (f.reasonCode === 'other' && f.reasonText.trim() === '') errors['header.reasonText'] = 'stock.doc.error.reasonTextRequired'
  }
  if (f.kind !== 'receipt' && f.reasonText.length > TEXT_MAX) errors['header.reasonText'] = 'stock.doc.error.textTooLong'
  if (f.lines.length < 1 || f.lines.length > MAX_LINES) errors['lines'] = 'stock.doc.error.lines_count'
  f.lines.forEach((l, i) => {
    const k = `lines.${i}`
    if (l.itemId === '') errors[`${k}.itemId`] = 'stock.doc.error.field_required'
    else if (l.uomId === '') errors[`${k}.itemId`] = 'stock.doc.error.unit_not_valid'
    if (!isDecimalAboveZero(l.quantity)) errors[`${k}.quantity`] = 'stock.doc.error.quantity_invalid'
    if (f.kind === 'receipt') {
      if (l.unitPrice !== '' && !isDecimalNonNegative(l.unitPrice)) errors[`${k}.unitPrice`] = 'stock.doc.error.price_invalid'
      if (l.lineValue !== '' && !isDecimalNonNegative(l.lineValue)) errors[`${k}.lineValue`] = 'stock.doc.error.price_invalid'
    }
  })
  return { errors }
}

/** The exact body of a create (POST) and of an edit (PUT): `kind`, the whole header, the whole line list; an empty
 *  optional value is left out; nothing the server sets (line_id, line_no, header_id, number, state). */
export function buildBody(f: FormState): Record<string, unknown> {
  const body: Record<string, unknown> = {
    kind: f.kind,
    event_time: zonedLocalToIso(f.eventTime),
    org_unit_id: f.orgUnitId,
    location_id: f.locationId,
    responsible_id: f.responsibleId,
  }
  const opt = (key: string, v: string) => {
    if (v.trim() !== '') body[key] = v
  }
  opt('note', f.note)
  if (f.kind === 'receipt') {
    opt('counterparty_id', f.counterpartyId)
    opt('supplier_document_ref', f.supplierRef)
    opt('received_on', f.receivedOn)
  } else {
    if (f.kind === 'write_off') body['reason_code'] = f.reasonCode
    opt('reason_text', f.reasonText)
  }
  body['lines'] = f.lines.map((l) => {
    const line: Record<string, unknown> = {
      catalog_item_id: l.itemId,
      catalog_uom_id: l.uomId,
      quantity: l.quantity,
    }
    if (l.lotId !== '') line['catalog_lot_id'] = l.lotId
    if (f.kind === 'receipt') {
      if (l.unitPrice !== '') line['unit_price'] = l.unitPrice
      if (l.lineValue !== '') line['line_value'] = l.lineValue
    }
    return line
  })
  return body
}

/** Where an error from the server is shown: a header field, a line, or the banner. */
const FIELD_KEYS: Record<string, string> = {
  event_time: 'header.eventTime', org_unit_id: 'header.orgUnitId', location_id: 'header.locationId',
  responsible_id: 'header.responsibleId', counterparty_id: 'header.counterpartyId', note: 'header.note',
  supplier_document_ref: 'header.supplierRef', received_on: 'header.receivedOn', reason_code: 'header.reasonCode',
  reason_text: 'header.reasonText',
}
const LINE_FIELD_KEYS: Record<string, string> = {
  catalog_item_id: 'itemId', catalog_uom_id: 'itemId', catalog_lot_id: 'lotId', quantity: 'quantity',
  unit_price: 'unitPrice', line_value: 'lineValue',
}

/** `{ key, messageId }` for a save refusal; `key` is null when it belongs to the whole form (banner). */
export function placeError(err: unknown): { key: string | null; messageId: string } {
  const info = documentErrorInfo(err)
  const messageId = documentErrorMessageId(err)
  if (info.lineNo !== undefined) {
    const field = info.field !== undefined ? (LINE_FIELD_KEYS[info.field] ?? 'itemId') : undefined
    const i = info.lineNo - 1
    return { key: field ? `lines.${i}.${field}` : `lines.${i}`, messageId }
  }
  if (info.field !== undefined && FIELD_KEYS[info.field]) return { key: FIELD_KEYS[info.field], messageId }
  return { key: null, messageId }
}
