/** documentForm — T-1469 / C14 part 2. Pure model of the asset document draft form: the state, the checks made before
 *  a save (they mirror the server so the user is told early; the server stays the authority), the request body for
 *  create (POST) and replace (PUT: the whole header and the whole line list), and where a refusal is shown.
 *  A side holds the four values of a kind's place and people; commission and write off use `from` only, change shares
 *  the org unit and location of `from`, hand over has two full sides (`Kinds.sides/2`). */
import { ASSETS_TIME_ZONE } from '../register/registerModel'
import type { AssetDocument } from './assetDocuments.api'
import {
  buildKindChangeLines, emptyKindChangeLine, kindChangeLinesFromDocument, kindChangeRefusalField,
  validateKindChangeLines, type KindChangeLine,
} from './kindChangeForm'
import {
  TEXT_MAX, WRITEOFF_REASONS, documentErrorInfo, documentErrorMessageId, isTwoSide, sidesOf,
  type DocKind,
} from './documentsModel'

/** `Shape.max_lines`. */
export const MAX_LINES = 100

export interface LineForm {
  assetId: string
  quantity: string
}
export interface SideForm {
  orgUnitId: string
  locationId: string
  responsibleId: string
  userId: string
}
export interface FormState {
  kind: DocKind
  from: SideForm
  to: SideForm
  eventTime: string
  reasonCode: string
  reasonText: string
  note: string
  lines: LineForm[]
  /** The lines of a change of kind (another shape); only the list of the form's kind is validated and sent. */
  kcLines: KindChangeLine[]
}

export const emptyLine = (): LineForm => ({ assetId: '', quantity: '1' })
export const emptySide = (): SideForm => ({ orgUnitId: '', locationId: '', responsibleId: '', userId: '' })

// ---- numbers -----------------------------------------------------------------------------------------------

/** The server's quantity text: up to 15 integer digits, up to 9 decimals, no sign, no exponent, no leading zeros. */
const DECIMAL = /^(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?$/
export const isDecimalAboveZero = (v: string): boolean => DECIMAL.test(v) && /[1-9]/.test(v)

// ---- time zone (a small copy of the stock helpers: the assets module does not import modules/stock) ---------

function offsetMinutes(ms: number, tz: string): number {
  const parts = new Intl.DateTimeFormat('en', {
    timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(ms))
  const g = (t: string) => Number(parts.find((p) => p.type === t)?.value)
  const asUtc = Date.UTC(g('year'), g('month') - 1, g('day'), g('hour'), g('minute'), g('second'))
  return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / 60000)
}
const pad = (n: number): string => String(Math.abs(n)).padStart(2, '0')

/** `2026-11-04T10:00` in the tenant zone -> ISO 8601 with that zone's offset (`2026-11-04T10:00:00+05:00`). */
export function zonedLocalToIso(local: string, tz: string = ASSETS_TIME_ZONE): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(local)
  if (!m) return null
  const asUtc = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5])
  let off = offsetMinutes(asUtc, tz)
  off = offsetMinutes(asUtc - off * 60000, tz)
  const sign = off < 0 ? '-' : '+'
  return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:00${sign}${pad(Math.trunc(off / 60))}:${pad(off % 60)}`
}

/** An ISO instant -> `YYYY-MM-DDTHH:mm` in the tenant zone (the value of the date-time field). */
export function isoToZonedLocal(iso: string | null | undefined, tz: string = ASSETS_TIME_ZONE): string {
  if (!iso) return ''
  const ms = Date.parse(iso)
  if (Number.isNaN(ms)) return ''
  const d = new Date(ms + offsetMinutes(ms, tz) * 60000)
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`
}
export const nowZonedLocal = (tz: string = ASSETS_TIME_ZONE): string => isoToZonedLocal(new Date().toISOString(), tz)

// ---- state -------------------------------------------------------------------------------------------------

export function emptyForm(kind: DocKind, eventTime: string = nowZonedLocal()): FormState {
  return { kind, from: emptySide(), to: emptySide(), eventTime, reasonCode: '', reasonText: '', note: '', lines: [emptyLine()], kcLines: [emptyKindChangeLine()] }
}

const s = (v: string | null | undefined): string => v ?? ''

/** The form of a loaded draft: every header value and every line (a PUT replaces the whole document). */
export function formFromDocument(doc: AssetDocument): FormState {
  const kind = (doc.kind as DocKind)
  const sides = sidesOf(doc)
  const side = (v: ReturnType<typeof sidesOf>['from']): SideForm => ({
    orgUnitId: s(v.orgUnitId), locationId: s(v.locationId), responsibleId: s(v.responsibleId), userId: s(v.userId),
  })
  const isKc = kind === 'kind_change'
  const lines = isKc ? [] : [...doc.lines].sort((a, b) => a.line_no - b.line_no).map((l) => ({ assetId: l.asset_id, quantity: trimZeros(l.quantity) }))
  const kcLines = isKc ? kindChangeLinesFromDocument(doc.lines) : []
  return {
    kind,
    from: side(sides.from),
    to: isTwoSide(kind) ? side(sides.to) : emptySide(),
    eventTime: isoToZonedLocal(doc.event_time),
    reasonCode: s(doc.reason_code),
    reasonText: s(doc.reason_text),
    note: s(doc.note),
    lines: lines.length > 0 ? lines : [emptyLine()],
    kcLines: kcLines.length > 0 ? kcLines : [emptyKindChangeLine()],
  }
}

/** `1.000000000` -> `1`: the server stores nine decimals; the editor shows the short form. */
export function trimZeros(q: string): string {
  return q.includes('.') ? q.replace(/\.?0+$/, '') || '0' : q
}

// ---- checks ------------------------------------------------------------------------------------------------

export interface LineCard {
  /** The card's kind (`fixed`, `intangible`, ...) when the card is loaded. */
  kind?: string
}

/** Message ids of one line by field (`assetId`, `quantity`). `cardOf` finds the loaded card; an unknown card skips the
 *  card-dependent check (the server decides at issue time). */
export function validateLine(l: LineForm, cardOf: (id: string) => LineCard | undefined = () => undefined): Record<string, string> {
  const out: Record<string, string> = {}
  if (l.assetId === '') out['assetId'] = 'assets.doc.error.assetRequired'
  const q = l.quantity.trim()
  if (q === '') out['quantity'] = 'assets.doc.error.quantityRequired'
  else if (!isDecimalAboveZero(q)) out['quantity'] = 'assets.doc.error.quantity_invalid'
  else {
    const kind = l.assetId === '' ? undefined : cardOf(l.assetId)?.kind
    if (kind === 'fixed' || kind === 'intangible') {
      if (!/^1(\.0+)?$/.test(q)) out['quantity'] = 'assets.doc.error.quantityOne'
    } else if (kind !== undefined && q.includes('.') && !/^[0-9]+(\.0+)?$/.test(q)) out['quantity'] = 'assets.doc.error.quantityWhole'
  }
  return out
}

/** Keys: `side.<side>.<field>`, `sides`, `header.<field>`, `lines`, `lines.<i>.<field>`; values are message ids. */
export function validateForm(f: FormState, cardOf?: (id: string) => LineCard | undefined): { errors: Record<string, string> } {
  const errors: Record<string, string> = {}
  const required = 'assets.doc.error.field_required'
  if (zonedLocalToIso(f.eventTime) === null) errors['header.eventTime'] = 'assets.doc.error.eventTimeRequired'
  if (f.kind === 'kind_change') {
    // Header: org unit, event time, optional reason text and note; the people and places are per line.
    if (f.from.orgUnitId === '') errors['side.from.orgUnitId'] = required
    if (f.reasonText.length > TEXT_MAX) errors['header.reasonText'] = 'assets.doc.error.textTooLong'
    if (f.note.length > TEXT_MAX) errors['header.note'] = 'assets.doc.error.textTooLong'
    if (f.kcLines.length < 1 || f.kcLines.length > MAX_LINES) errors['lines'] = 'assets.doc.error.lines_count'
    return { errors: { ...errors, ...validateKindChangeLines(f.kcLines) } }
  }
  if (f.from.orgUnitId === '') errors['side.from.orgUnitId'] = required
  if (f.from.responsibleId === '') errors['side.from.responsibleId'] = required
  if (f.kind === 'change') {
    if (f.to.responsibleId === '') errors['side.to.responsibleId'] = required
    if (f.from.responsibleId !== '' && f.to.responsibleId !== '' && f.from.responsibleId === f.to.responsibleId && f.from.userId === f.to.userId) {
      errors['sides'] = 'assets.doc.error.sides_equal'
    }
  }
  if (f.kind === 'handover') {
    if (f.to.orgUnitId === '') errors['side.to.orgUnitId'] = required
    if (f.to.responsibleId === '') errors['side.to.responsibleId'] = required
    if (f.from.orgUnitId !== '' && f.from.orgUnitId === f.to.orgUnitId && f.from.locationId === f.to.locationId) {
      errors['sides'] = 'assets.doc.error.sides_equal'
    }
  }
  if (f.kind === 'writeoff') {
    if (f.reasonCode === '') errors['header.reasonCode'] = 'assets.doc.error.reasonCodeRequired'
    else if (!(WRITEOFF_REASONS as readonly string[]).includes(f.reasonCode)) errors['header.reasonCode'] = 'assets.doc.error.field_invalid'
    if (f.reasonCode === 'other' && f.reasonText.trim() === '') errors['header.reasonText'] = 'assets.doc.error.reasonTextRequired'
    if (f.reasonText.length > TEXT_MAX) errors['header.reasonText'] = 'assets.doc.error.textTooLong'
  }
  if (f.note.length > TEXT_MAX) errors['header.note'] = 'assets.doc.error.textTooLong'
  if (f.lines.length < 1 || f.lines.length > MAX_LINES) errors['lines'] = 'assets.doc.error.lines_count'
  const seen = new Set<string>()
  f.lines.forEach((l, i) => {
    for (const [field, id] of Object.entries(validateLine(l, cardOf))) errors[`lines.${i}.${field}`] = id
    if (l.assetId !== '') {
      if (seen.has(l.assetId)) errors[`lines.${i}.assetId`] = 'assets.doc.error.duplicate_asset'
      seen.add(l.assetId)
    }
  })
  return { errors }
}

// ---- request body ------------------------------------------------------------------------------------------

/** The body of POST (with `kind`) and PUT (the kind is not sent again): the header keys of the kind, the event time and
 *  every line. A cleared optional value is left out, which the server reads as cleared. */
export function buildBody(f: FormState, withKind = true): Record<string, unknown> {
  const body: Record<string, unknown> = {}
  const opt = (key: string, v: string) => {
    if (v.trim() !== '') body[key] = v
  }
  if (withKind) body['kind'] = f.kind
  const { from, to } = f
  body['org_unit_id'] = from.orgUnitId
  if (f.kind === 'kind_change') {
    opt('reason_text', f.reasonText)
    body['event_time'] = zonedLocalToIso(f.eventTime)
    opt('note', f.note)
    body['lines'] = buildKindChangeLines(f.kcLines)
    return body
  }
  switch (f.kind) {
    case 'change':
      opt('location_id', from.locationId)
      body['from_material_responsible_id'] = from.responsibleId
      opt('from_actual_user_id', from.userId)
      body['to_material_responsible_id'] = to.responsibleId
      opt('to_actual_user_id', to.userId)
      break
    case 'handover':
      opt('from_location_id', from.locationId)
      body['from_material_responsible_id'] = from.responsibleId
      opt('from_actual_user_id', from.userId)
      body['to_org_unit_id'] = to.orgUnitId
      opt('to_location_id', to.locationId)
      body['to_material_responsible_id'] = to.responsibleId
      opt('to_actual_user_id', to.userId)
      break
    default:
      opt('location_id', from.locationId)
      body['material_responsible_id'] = from.responsibleId
      opt('actual_user_id', from.userId)
  }
  if (f.kind === 'writeoff') {
    body['reason_code'] = f.reasonCode
    opt('reason_text', f.reasonText)
  }
  body['event_time'] = zonedLocalToIso(f.eventTime)
  opt('note', f.note)
  body['lines'] = f.lines.map((l) => ({ asset_id: l.assetId, quantity: l.quantity.trim() }))
  return body
}

// ---- where a refusal is shown ------------------------------------------------------------------------------

const FIELD_KEYS: Record<string, string> = {
  event_time: 'header.eventTime', note: 'header.note', reason_code: 'header.reasonCode', reason_text: 'header.reasonText',
  org_unit_id: 'side.from.orgUnitId', location_id: 'side.from.locationId', from_location_id: 'side.from.locationId',
  material_responsible_id: 'side.from.responsibleId', from_material_responsible_id: 'side.from.responsibleId',
  actual_user_id: 'side.from.userId', from_actual_user_id: 'side.from.userId',
  to_org_unit_id: 'side.to.orgUnitId', to_location_id: 'side.to.locationId',
  to_material_responsible_id: 'side.to.responsibleId', to_actual_user_id: 'side.to.userId',
}
const LINE_FIELD_KEYS: Record<string, string> = { asset_id: 'assetId', quantity: 'quantity' }

/** `{ key, messageId }` for a save refusal; `key` is null when it belongs to the whole form (banner). */
export function placeError(err: unknown, form?: DocKind): { key: string | null; messageId: string } {
  const info = documentErrorInfo(err)
  const messageId = documentErrorMessageId(err)
  if (info.reason === 'sides_equal') return { key: 'sides', messageId }
  if (info.reason === 'lines_count') return { key: 'lines', messageId }
  if (form === 'kind_change' && info.lineNo === undefined && info.reason === 'org_unit_not_active') return { key: 'side.from.orgUnitId', messageId }
  if (info.lineNo !== undefined && form === 'kind_change') {
    const field = kindChangeRefusalField(info.reason, info.field, info.side)
    const i = info.lineNo - 1
    return { key: field ? `lines.${i}.${field}` : `lines.${i}`, messageId: info.reason === 'not_linked' && (info.side === 'asset' || info.side === 'stock') ? `${messageId}_${info.side}` : messageId }
  }
  if (info.lineNo !== undefined) {
    const field = info.field !== undefined ? (LINE_FIELD_KEYS[info.field] ?? 'assetId') : info.reason === 'quantity_invalid' ? 'quantity' : undefined
    const i = info.lineNo - 1
    return { key: field ? `lines.${i}.${field}` : `lines.${i}`, messageId }
  }
  if (info.field !== undefined && FIELD_KEYS[info.field]) return { key: FIELD_KEYS[info.field], messageId }
  return { key: null, messageId }
}
