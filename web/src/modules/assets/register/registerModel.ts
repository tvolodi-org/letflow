/** registerModel — T-1334 / C14. Pure helpers of the balances and movements screens: the query keys of the routes
 *  (a closed set on the server), the cause and document-kind words, the posting range check, error classes, the name
 *  ids a page needs and the mapping of movement rows to journal operations. */
import type { ReactNode } from 'react'
import { formatDateTimeInZone } from '@/i18n/format'
import { getUiLocale } from '@/i18n/uiLocaleStore'
import { formatQuantity } from '@/lib/formatQuantity'
import type { JournalLeg, JournalOp, JournalSign, JournalStatus } from '@/components/ui/journal'
import type { ReferenceType } from '@/lib/references/referenceLabel'
import type { AssetBalanceRow, AssetMovementLeg, AssetMovementRow } from './assetRegister.api'

/** Tenant time zone of every assets screen: the REQ-703 server default (`TenantTimezone.default/0`). The web has no
 *  read route for the tenant setting, so this one constant is the single place that names the zone. */
export const ASSETS_TIME_ZONE = 'Asia/Almaty'

/** The one date-time formatter of the assets screens: tenant zone, the UI language's single format. */
export function formatAssetsDateTime(iso: string | null | undefined, o: { locale?: string } = {}): string {
  return formatDateTimeInZone(iso, { timeZone: ASSETS_TIME_ZONE, locale: o.locale ?? getUiLocale() })
}

export const CAUSES = ['commission', 'change', 'handover', 'writeoff', 'reversal'] as const
export const DOCUMENT_TYPES = ['assets_commission', 'assets_change', 'assets_handover', 'assets_writeoff'] as const

export type MasterType = ReferenceType

export interface BalanceFilters {
  asset: string
  org_unit: string
  location: string
  material_responsible: string
  actual_user: string
  scope_subtree: string
}
export interface MovementFilters {
  cause: string
  document_id: string
  from_seq: string
  to_seq: string
}

export const EMPTY_BALANCE_FILTERS: BalanceFilters = {
  asset: '',
  org_unit: '',
  location: '',
  material_responsible: '',
  actual_user: '',
  scope_subtree: '',
}

function nonEmpty(entries: [string, string][]): Record<string, string> {
  return Object.fromEntries(entries.filter(([, v]) => v.trim() !== '').map(([k, v]) => [k, v.trim()]))
}

/** Exactly the keys the balances route takes from a filter: never basis, cutoff_seq, as_of, format, limit or a tenant.
 *  An empty value is never sent. */
export function balanceParams(f: BalanceFilters): Record<string, string> {
  return nonEmpty([
    ['asset', f.asset],
    ['org_unit', f.org_unit],
    ['location', f.location],
    ['material_responsible', f.material_responsible],
    ['actual_user', f.actual_user],
    ['scope_subtree', f.scope_subtree],
  ])
}

/** True when both bounds are numbers and from is above to: the range is not sent and the field is marked. */
export function rangeError(from: string, to: string): boolean {
  return /^\d+$/.test(from) && /^\d+$/.test(to) && BigInt(from) > BigInt(to)
}

/** Exactly the keys of the movements route this screen offers. */
export function movementParams(f: MovementFilters): Record<string, string> {
  const bad = rangeError(f.from_seq, f.to_seq)
  return nonEmpty([
    ['cause', f.cause],
    ['document_id', f.document_id],
    ['from_seq', bad ? '' : f.from_seq],
    ['to_seq', bad ? '' : f.to_seq],
  ])
}

/** The Movements screen narrowed to one document (used by the document view). */
export function movementsLinkFor(documentId: string): string {
  return `/admin/assets/movements?document_id=${encodeURIComponent(documentId)}`
}

export function isMasked(leg: AssetMovementLeg): boolean {
  return leg.masked === true
}

export type RegisterErrorKind = 'invalid' | 'notFound' | 'forbidden' | 'generic'

export function errorKind(err: unknown): RegisterErrorKind {
  const status = (err as { status?: unknown } | null | undefined)?.status
  if (status === 422) return 'invalid'
  if (status === 404) return 'notFound'
  if (status === 403) return 'forbidden'
  return 'generic'
}

export type NameIds = Partial<Record<MasterType, string[]>>

function add(out: NameIds, type: MasterType, id: string | null | undefined) {
  if (typeof id === 'string' && id !== '') (out[type] ??= []).push(id)
}

export function balanceNameIds(rows: AssetBalanceRow[]): NameIds {
  const out: NameIds = {}
  for (const r of rows) {
    add(out, 'assets_card', r.asset)
    add(out, 'org_unit', r.org_unit)
    add(out, 'location_node', r.location)
    add(out, 'org_employee', r.material_responsible)
    add(out, 'org_employee', r.actual_user)
  }
  return out
}

/** A masked leg contributes no slot ids (INV-2: the client never asks for a name it may not see). */
export function movementNameIds(rows: AssetMovementRow[]): NameIds {
  const out: NameIds = {}
  for (const row of rows) {
    for (const l of row.legs) {
      if (isMasked(l)) continue
      add(out, 'assets_card', l.asset)
      add(out, 'org_unit', l.org_unit)
      add(out, 'location_node', l.location)
      add(out, 'org_employee', l.material_responsible)
      add(out, 'org_employee', l.actual_user)
    }
  }
  return out
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export function isDocumentUuid(v: string | null | undefined): v is string {
  return typeof v === 'string' && UUID.test(v)
}

/** The document cell of Movements and the balance history: the kind word linked to the document (the movement view
 *  carries no document number). Null without a document type. */
export function documentCell(
  row: Pick<AssetMovementRow, 'document_type' | 'document_id'>,
  kindLabel: (documentType: string) => string,
): { text: string; to: string | null } | null {
  if (!row.document_type) return null
  return {
    text: kindLabel(row.document_type),
    to: row.document_id ? `/admin/assets/documents/${encodeURIComponent(row.document_id)}` : null,
  }
}

// ---- journal mapping -----------------------------------------------------------------------------------

export interface MovementsMapContext {
  name: (type: ReferenceType, id: string | null | undefined) => string
  t: (id: string, values?: Record<string, string | number>) => string
  when: (iso: string | null | undefined) => string
  kindIcon: (cause: string) => ReactNode
}

/** `reversal` when the row points at the entry it reverses; `reversed` when another LOADED row points at this one. */
export function statusOf(row: AssetMovementRow, all: AssetMovementRow[]): JournalStatus {
  if (row.reverses_entry_id) return 'reversal'
  if (all.some((r) => r.reverses_entry_id === row.entry_id)) return 'reversed'
  return 'posted'
}

export function signOf(quantity: string): JournalSign {
  const q = quantity.trim()
  if (/^-/.test(q) && /[1-9]/.test(q)) return 'neg'
  return /[1-9]/.test(q) ? 'pos' : ''
}

export function absQuantity(quantity: string): string {
  return formatQuantity(quantity.trim().replace(/^-/, ''))
}

function uniq<T>(a: T[]): T[] {
  return a.filter((x, i) => a.indexOf(x) === i)
}

function kindWord(row: AssetMovementRow, t: MovementsMapContext['t']): string {
  if (!row.document_type) return ''
  return (DOCUMENT_TYPES as readonly string[]).includes(row.document_type) ? t(`assets.docType.${row.document_type}`) : row.document_type
}

function legOf(l: AssetMovementLeg, c: MovementsMapContext): JournalLeg {
  const hidden = isMasked(l)
  const unit = l.unit_ref
  const qty = [absQuantity(l.quantity), unit].filter((x) => x !== '').join(' ')
  const place = hidden ? '' : [c.name('location_node', l.location), c.name('org_unit', l.org_unit)].filter((x) => x !== '').join(' · ')
  const holder = hidden ? '' : [c.name('org_employee', l.material_responsible), c.name('org_employee', l.actual_user)].filter((x) => x !== '').join(' / ')
  return {
    id: String(l.leg_no),
    location: place,
    item: hidden ? '' : c.name('assets_card', l.asset),
    holder,
    qty,
    sign: signOf(l.quantity),
    hidden,
  }
}

export function toJournalOps(rows: AssetMovementRow[], c: MovementsMapContext): JournalOp[] {
  return rows.map((row) => {
    const status = statusOf(row, rows)
    const open = row.legs.filter((l) => !isMasked(l))
    const assetIds = uniq(open.map((l) => l.asset ?? ''))
    const places = uniq(open.map((l) => l.location ?? l.org_unit ?? '').filter((x) => x !== ''))
    const unitOf = row.legs[0]?.unit_ref ?? ''
    const sum = row.legs.reduce((s, l) => s + (Number(l.quantity) || 0), 0)
    const kind = kindWord(row, c.t)
    const known = (CAUSES as readonly string[]).includes(row.cause)
    const pos = row.legs.filter((l) => signOf(l.quantity) === 'pos')
    const neg = row.legs.filter((l) => signOf(l.quantity) === 'neg')
    // a move between holders (legs cancel out) shows the amount that moved, without a sign
    const moved = pos.length > 0 && neg.length > 0
    const amount = moved ? absQuantity(pos[0].quantity) : absQuantity(String(sum))
    const qty = assetIds.length > 1 ? c.t('assets.journal.lines', { n: row.legs.length }) : row.legs.length > 0 ? [amount, unitOf].filter((x) => x !== '').join(' ') : ''
    return {
      id: row.entry_id,
      time: c.when(row.event_time),
      kind: row.cause,
      kindLabel: known ? c.t(`assets.cause.${row.cause}`) : row.cause,
      kindIcon: c.kindIcon(row.cause),
      docText: kind,
      docKind: kind || undefined,
      docHref: row.document_id ? `/admin/assets/documents/${encodeURIComponent(row.document_id)}` : undefined,
      item: assetIds.length > 0 ? c.name('assets_card', assetIds[0]) : '',
      itemMore: Math.max(0, assetIds.length - 1),
      location: places.length > 0 ? (open[0]?.location ? c.name('location_node', open[0].location) : c.name('org_unit', open[0]?.org_unit)) : '',
      locationMore: Math.max(0, places.length - 1),
      qty,
      qtySign: assetIds.length > 1 || moved ? '' : sum > 0 ? 'pos' : sum < 0 ? 'neg' : '',
      status,
      statusLabel: c.t(`assets.journal.status.${status}`),
      statusNote: '',
      legs: row.legs.map((l) => legOf(l, c)),
    }
  })
}
