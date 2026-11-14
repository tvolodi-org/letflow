/** useTaskDocuments — T-1380 / GATE B R3. For each task's instance: the stock document (or count order) it is about and the
 *  person who started the flow, so a row and the detail panel can show the document, not a bare node name. One cached
 *  read per instance (capped like useTaskSubjects). The core inbox cannot import a module (lint rule), so the document
 *  reads go through the client by route. A read that fails gives `null` (the screen shows "Document not available"). */
import { useQueries } from '@tanstack/react-query'
import { instancesApi } from '@/api/instances'
import { client } from '@/api/client'
import { useAuth } from '@/auth/AuthContext'
import { referenceQueryKeys } from '@/lib/references/referenceQueryKeys'

const STOCK_DOCUMENTS = '/api/v1/modules/stock/documents'
const STOCK_COUNTS = '/api/v1/modules/stock/counts'
const ASSET_DOCUMENTS = '/api/v1/modules/assets/documents'
const CAP = 50

export interface TaskDocLine {
  line_no: number
  catalog_item_id: string
  catalog_uom_id: string
  catalog_lot_id?: string | null
  quantity: string
  /** Asset documents (assets_*): the line names a card (resolved to "inventory number - name" by the reference labels), not a catalog item. */
  assetId?: string
  locationId?: string | null
}

/** The part of a stock document / count order the inbox shows. */
export interface TaskDoc {
  type: 'document' | 'count'
  /** `document_type` process variable (`stock_*`, `assets_*`); selects the kind word. */
  typeKey?: string
  kind: string
  state: string
  number: string
  orgUnitId: string | null
  locationIds: string[]
  locationId: string | null
  fromLocationId: string | null
  toOrgUnitId: string | null
  toLocationId: string | null
  eventTime: string | null
  plannedStart: string | null
  plannedEnd: string | null
  note: string | null
  lines: TaskDocLine[]
}

export interface TaskContext {
  doc: TaskDoc | null
  issuerId: string | null
}

type Raw = Record<string, unknown>
const s = (v: unknown): string => (typeof v === 'string' ? v : '')
const sn = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null)

function toDoc(type: 'document' | 'count', r: Raw): TaskDoc {
  const lines = Array.isArray(r['lines']) ? (r['lines'] as TaskDocLine[]) : []
  const isCount = type === 'count'
  return {
    type,
    kind: isCount ? 'count' : s(r['kind']),
    state: s(isCount ? r['status'] : r['state']),
    number: s(r['number']),
    orgUnitId: sn(r['org_unit_id']),
    locationIds: isCount && Array.isArray(r['location_ids']) ? (r['location_ids'] as string[]) : [],
    locationId: sn(r['location_id']),
    fromLocationId: sn(r['from_location_id']),
    toOrgUnitId: sn(r['to_org_unit_id']),
    toLocationId: sn(r['to_location_id']),
    eventTime: sn(r['event_time']),
    plannedStart: sn(r['planned_start']),
    plannedEnd: sn(r['planned_end']),
    note: sn(r['note']),
    lines,
  }
}

/** An asset document (opening, commission, ...): the lines name asset cards. Same TaskDoc shape as a stock document. */
function toAssetDoc(typeKey: string, r: Raw): TaskDoc {
  const raw = Array.isArray(r['lines']) ? (r['lines'] as Raw[]) : []
  const lines: TaskDocLine[] = raw.map((l, i) => {
    return {
      line_no: typeof l['line_no'] === 'number' ? (l['line_no'] as number) : i + 1,
      catalog_item_id: '',
      catalog_uom_id: '',
      quantity: s(l['quantity']),
      assetId: s(l['asset_id']),
      locationId: sn(l['location_id']),
    }
  })
  return { ...toDoc('document', r), typeKey, lines }
}

async function issuerOf(instanceId: string): Promise<string | null> {
  try {
    // Read by route: the instance history route, first event (the one that started the flow).
    const res = (await client.get<unknown>(`/api/v1/instances/${encodeURIComponent(instanceId)}/history`, { limit: 1 })) as unknown
    const list = Array.isArray(res) ? res : ((res as { items?: unknown[] } | null)?.items ?? [])
    return sn((list[0] as { actor_id?: unknown } | undefined)?.actor_id)
  } catch {
    return null
  }
}

async function contextOf(instanceId: string): Promise<TaskContext> {
  const inst = await instancesApi.get(instanceId)
  const vars = (inst?.variables ?? {}) as Record<string, unknown>
  const type = s(vars['document_type'])
  const docId = s(vars['document_id'])
  const orderId = s(vars['count_order_id'])
  let doc: TaskDoc | null = null
  try {
    if (orderId !== '') doc = toDoc('count', (await client.get<Raw>(`${STOCK_COUNTS}/${encodeURIComponent(orderId)}`)) ?? {})
    else if (type.startsWith('assets_') && docId !== '') doc = toAssetDoc(type, (await client.get<Raw>(`${ASSET_DOCUMENTS}/${encodeURIComponent(docId)}`)) ?? {})
    else if (type.startsWith('stock_') && docId !== '') doc = toDoc('document', (await client.get<Raw>(`${STOCK_DOCUMENTS}/${encodeURIComponent(docId)}`)) ?? {})
  } catch {
    doc = null
  }
  return { doc, issuerId: await issuerOf(instanceId) }
}

/** instance id -> context; `undefined` while loading, `null` when the instance cannot be read. */
export function useTaskContexts(instanceIds: string[]): (instanceId: string) => TaskContext | null | undefined {
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const ids = [...new Set(instanceIds)].slice(0, CAP)
  const results = useQueries({
    queries: ids.map((id) => ({
      queryKey: referenceQueryKeys.taskDocument(tenantId, id),
      queryFn: () => contextOf(id),
      retry: false,
    })),
  })
  const byId = new Map(ids.map((id, i) => [id, results[i]]))
  return (instanceId) => {
    const r = byId.get(instanceId)
    if (!r || r.isPending) return undefined
    return r.data ?? null
  }
}
