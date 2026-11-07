/** movementsModel — T-1422 (GATE B R12). Pure mapping of the movement rows of the route to the operations of the
 *  journal component: status, quantity cell, legs. No ids reach the screen: names come in through `name`. */
import type { ReactNode } from 'react'
import { formatQuantity } from '@/lib/formatQuantity'
import type { JournalLeg, JournalOp, JournalSign, JournalStatus } from '@/components/ui/journal'
import type { ReferenceType } from '@/lib/references/referenceLabel'
import type { MovementLeg, MovementRow } from './stock.api'
import { CAUSES, DOCUMENT_TYPES, isMasked } from './stockRegisterModel'

export interface MovementsMapContext {
  name: (type: ReferenceType, id: string | null | undefined) => string
  /** Message lookup by id with `{n}` / `{d}` style values. */
  t: (id: string, values?: Record<string, string | number>) => string
  when: (iso: string | null | undefined) => string
  kindIcon: (cause: string) => ReactNode
}

/** `reversal` when the row points at the entry it reverses; `reversed` when another LOADED row points at this one
 *  (honest limit: a reversal on a page that is not loaded yet is not known); else `posted`. */
export function statusOf(row: MovementRow, all: MovementRow[]): JournalStatus {
  if (row.reverses_entry_id) return 'reversal'
  if (all.some((r) => r.reverses_entry_id === row.entry_id)) return 'reversed'
  return 'posted'
}

export function signOf(quantity: string): JournalSign {
  const q = quantity.trim()
  if (/^-/.test(q) && /[1-9]/.test(q)) return 'neg'
  return /[1-9]/.test(q) ? 'pos' : ''
}

/** The quantity text without its sign ("12.5"). */
export function absQuantity(quantity: string): string {
  return formatQuantity(quantity.trim().replace(/^-/, ''))
}

function documentKind(row: MovementRow, t: MovementsMapContext['t']): string {
  if (!row.document_type) return ''
  return (DOCUMENT_TYPES as readonly string[]).includes(row.document_type) ? t(`stock.docType.${row.document_type}`) : row.document_type
}

/** "number - kind" ("RCP-2026-000001 - Receipt"); the kind alone when there is no number; empty when no type. */
export function documentText(row: MovementRow, t: MovementsMapContext['t']): string {
  const kind = documentKind(row, t)
  return row.document_number && kind !== '' ? `${row.document_number} - ${kind}` : kind
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export function isDocumentUuid(v: string | null | undefined): v is string {
  return typeof v === 'string' && UUID.test(v)
}

/** The route `/admin/stock/documents/:id`; the harness and older rows use short ids, so any non-empty id links. */
export function documentHref(row: MovementRow): string | undefined {
  return row.document_id ? `/admin/stock/documents/${row.document_id}` : undefined
}

function uniq<T>(a: T[]): T[] {
  return a.filter((x, i) => a.indexOf(x) === i)
}

function legOf(l: MovementLeg, c: MovementsMapContext): JournalLeg {
  const unit = c.name('catalog_uom', l.unit_ref)
  const hidden = isMasked(l)
  const qty = [absQuantity(l.quantity), unit].filter((x) => x !== '').join(' ')
  return {
    id: String(l.leg_no),
    location: hidden ? '' : c.name('location_node', l.location),
    item: hidden ? '' : c.name('catalog_item', l.sku),
    holder: hidden ? '' : c.name('org_employee', l.responsible),
    qty,
    sign: signOf(l.quantity),
    hidden,
  }
}

export function toJournalOps(rows: MovementRow[], c: MovementsMapContext): JournalOp[] {
  const byId = new Map(rows.map((r) => [r.entry_id, r]))
  return rows.map((row) => {
    const status = statusOf(row, rows)
    const open = row.legs.filter((l) => !isMasked(l))
    const itemIds = uniq(open.map((l) => l.sku ?? ''))
    const pos = row.legs.filter((l) => signOf(l.quantity) === 'pos')
    const neg = row.legs.filter((l) => signOf(l.quantity) === 'neg')
    const unitOf = (l: MovementLeg) => c.name('catalog_uom', l.unit_ref)
    const join = (l: MovementLeg, q: string) => [q, unitOf(l)].filter((x) => x !== '').join(' ')
    let qty = ''
    let qtySign: JournalSign = ''
    if (itemIds.length > 1) {
      qty = c.t('stock.journal.lines', { n: row.legs.length })
    } else if (row.legs.length > 0 && pos.length > 0 && neg.length > 0) {
      // a move between places (legs cancel out): the amount without a sign
      qty = join(pos[0], absQuantity(pos[0].quantity))
    } else if (row.legs.length > 0) {
      const sum = row.legs.reduce((s, l) => s + (Number(l.quantity) || 0), 0)
      qty = join(row.legs[0], absQuantity(String(sum)))
      qtySign = sum > 0 ? 'pos' : sum < 0 ? 'neg' : ''
    }
    let statusNote = ''
    if (status === 'reversal') {
      const orig = byId.get(row.reverses_entry_id ?? '')
      if (orig?.document_number) statusNote = c.t('stock.journal.reversalOf', { d: orig.document_number })
    } else if (status === 'reversed') {
      const rev = rows.find((r) => r.reverses_entry_id === row.entry_id)
      if (rev?.document_number) statusNote = c.t('stock.journal.reversedBy', { d: rev.document_number })
    }
    const places = uniq(open.map((l) => l.location ?? '').filter((x) => x !== ''))
    const known = (CAUSES as readonly string[]).includes(row.cause)
    return {
      id: row.entry_id,
      time: c.when(row.event_time),
      kind: row.cause,
      kindLabel: known ? c.t(`stock.cause.${row.cause}`) : row.cause,
      kindIcon: c.kindIcon(row.cause),
      docText: documentText(row, c.t),
      docNumber: row.document_number ?? undefined,
      docKind: documentKind(row, c.t) || undefined,
      docHref: documentHref(row),
      item: itemIds.length > 0 ? c.name('catalog_item', itemIds[0]) : '',
      itemMore: Math.max(0, itemIds.length - 1),
      location: places.length > 0 ? c.name('location_node', places[0]) : '',
      locationMore: Math.max(0, places.length - 1),
      qty,
      qtySign,
      status,
      statusLabel: c.t(`stock.journal.status.${status}`),
      statusNote,
      legs: row.legs.map((l) => legOf(l, c)),
    }
  })
}
