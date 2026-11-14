/** Stateful codes fixtures: Items, Locations and Codes use the same invented records and assignments. */
import { useState } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { Button } from '@/components/ui/Button'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import ItemsPage from '@/modules/catalog_items/items/ItemsPage'
import LocationTreePage from '@/modules/locations/LocationTreePage'
import CodesPage from '@/modules/codes/CodesPage'
import type { EntityRecord } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'
import { AUTH, makeRoutes } from './layoutBase'
import { catalogItemsDataRoutes, catalogItemsSelectedId } from './catalogItems'
import { locationsDataRoutes } from './locations'

export const recordCodesItemId = catalogItemsSelectedId
const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({ record_id: id, entity_type: type, field_values: fields, deleted: false, entity_def_version: '1', last_event_global_seq: 1 })
const kinds = ['barcode', 'qr', 'epc', 'barcode', 'qr', 'tid', 'barcode']
const values = ['GATEA-BC-0001', 'GATEA-QR-0002', 'GATEA-EPC-0003', 'GATEA-FREE-0004', 'GATEA-FREE-0005', 'GATEA-FREE-0006', 'GATEA-OLD-0007']
const codes = kinds.map((kind, i) => rec(`c-${i + 1}`, 'code_tag', { value: values[i], kind, status: i < 3 ? 'assigned' : i === 6 ? 'retired' : 'not_assigned' }))
const assignments = codes.slice(0, 3).map((c, i) => rec(`a-${i}`, 'code_assignment', { code_id: c.record_id, target_type: i === 2 ? 'location_node' : 'catalog_item', target_id: i === 2 ? 'n-a' : recordCodesItemId, assigned_at: '2026-11-14T06:00:00Z', released_at: null }))
const replay = new Map<string, unknown>()
type Body = { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[]; sort?: { field: string; dir: string }[]; page_size?: number; cursor?: string; entries?: { value: string; kind: string }[]; idempotency_key?: string; target_type?: string; target_id?: string }
const ok = (body: unknown, status = 200) => ({ status, body })
const refused = (reason: string, entry_reason?: string) => ok({ reason, entry_reason }, 422)
function query(body: Body) {
  const type = body.entity_type
  if (type !== 'code_tag' && type !== 'code_assignment') {
    const source = type === 'location_node' ? locationsDataRoutes : catalogItemsDataRoutes
    return source.find((r) => r.match('/api/v1/entities/query', 'POST'))!.reply('default', '/api/v1/entities/query', body)
  }
  const rows = (type === 'code_tag' ? codes : assignments).filter((r) => (body.filters ?? []).every((f) => {
    const value = f.field === 'record_id' ? r.record_id : f.field === 'deleted' ? r.deleted : r.field_values[f.field]
    if (f.op === 'is_null') return value == null
    if (f.op === 'in') return Array.isArray(f.value) && f.value.includes(value)
    return f.op !== 'eq' || value === f.value
  }))
  const sort = body.sort?.[0]
  if (sort) rows.sort((a, b) => String(a.field_values[sort.field] ?? '').localeCompare(String(b.field_values[sort.field] ?? '')) * (sort.dir === 'desc' ? -1 : 1))
  const offset = Number(body.cursor ?? 0)
  const end = offset + (body.page_size ?? 200)
  return ok({ items: rows.slice(offset, end), next_cursor: end < rows.length ? String(end) : null })
}
function write(path: string, body: Body) {
  const key = body.idempotency_key ?? ''
  if (replay.has(key)) return ok(replay.get(key))
  if (path.endsWith('/receive')) {
    const entry = body.entries?.[0]
    if (!entry) return refused('entry_invalid', 'value_invalid')
    if (codes.some((r) => r.field_values['value'] === entry.value)) return refused('entry_invalid', 'value_taken')
    const tag = rec(`c-${codes.length + 1}`, 'code_tag', { ...entry, status: 'not_assigned' })
    codes.push(tag)
    const answer = [{ code_id: tag.record_id, ...tag.field_values }]
    replay.set(key, answer)
    return ok(answer, 201)
  }
  const id = path.split('/').at(-2)
  const tag = codes.find((r) => r.record_id === id)
  if (!tag) return ok({}, 404)
  if (path.endsWith('/assign')) {
    if (tag.field_values['status'] === 'assigned') return refused('code_assigned')
    if (tag.field_values['status'] === 'retired') return refused('code_retired')
    tag.field_values['status'] = 'assigned'
    assignments.push(rec(`a-${assignments.length}`, 'code_assignment', { code_id: id, target_type: body.target_type, target_id: body.target_id, assigned_at: '2026-11-14T07:00:00Z', released_at: null }))
  } else if (path.endsWith('/release')) {
    if (tag.field_values['status'] !== 'assigned') return refused('code_not_assigned')
    tag.field_values['status'] = 'not_assigned'
    assignments.filter((a) => a.field_values['code_id'] === id && !a.field_values['released_at']).forEach((a) => { a.field_values['released_at'] = '2026-11-14T07:30:00Z' })
  }
  replay.set(key, {})
  return ok({})
}
const routes: FixtureRoute[] = [
  { match: (p) => p === '/api/v1/me/modules', reply: () => ok({ installed_modules: [{ module_id: 'codes', version: '0.4.0' }] }) },
  { match: (p, m) => p === '/api/v1/entities/query' && m === 'POST', reply: (_s, _p, b) => query(b as Body) },
  { match: (p, m) => p.startsWith('/api/v1/modules/codes/') && m === 'POST', reply: (_s, p, b) => write(p, b as Body) },
  ...makeRoutes(null), ...catalogItemsDataRoutes, ...locationsDataRoutes,
]
type Preset = { location?: boolean; item?: string; dialog?: 'new' | 'pick'; readonly?: boolean; tab?: 'details' | 'codes'; roundtrip?: boolean }
function Screen({ preset }: { preset: Preset }) {
  const [page, setPage] = useState(preset.location ? 'locations' : 'items')
  const permissions = ['StockRead', 'LocationsWrite', 'CodesRead', ...(preset.readonly ? [] : ['CodesWrite'])]
  return <AuthContext.Provider value={AUTH}><AccessStateProvider state={{ status: 'ready', info: { permissions, roles: [], platform_tenant: false } }}><LayoutPrefsProvider>
    <div className="lf-main"><main className="lf-content lf-content--fluid">
      {preset.roundtrip && <div className="lf-btn-row">{['items', 'locations', 'codes'].map((name) => <Button key={name} data-testid={`roundtrip-${name}`} variant="secondary" size="sm" onClick={() => setPage(name)}>{name}</Button>)}</div>}
      {page === 'items' ? <ItemsPage initialItemId={preset.item ?? recordCodesItemId} initialCodesDialog={preset.dialog} /> : page === 'locations' ? <LocationTreePage initialSelectedId="n-a" initialTab={preset.tab ?? 'codes'} initialCodesDialog={preset.dialog} /> : <CodesPage />}
    </main></div>
  </LayoutPrefsProvider></AccessStateProvider></AuthContext.Provider>
}
const screen = (name: string, preset: Preset = {}, special?: 'error'): HarnessScreen => ({ name,
  routes: special ? [{ match: (p, m) => p === '/api/v1/entities/query' && m === 'POST', reply: (_s, _p, b) => {
    const body = b as Body
    if (body.entity_type?.startsWith('code_')) return ok({}, 500)
    return query(body)
  } }, ...routes] : routes,
  render: () => <Screen preset={preset} />,
})
export const recordCodesScreens: HarnessScreen[] = [
  screen('item-codes'), screen('item-codes-empty', { item: '00000000-0000-4000-8000-000000000103' }),
  screen('item-codes-new', { dialog: 'new' }), screen('item-codes-pick', { dialog: 'pick' }),
  screen('item-codes-readonly', { readonly: true }), screen('item-codes-retired', { item: '00000000-0000-4000-8000-000000000106' }),
  screen('item-codes-error', {}, 'error'),
  screen('location-codes', { location: true }), screen('location-codes-new', { location: true, dialog: 'new' }),
  screen('location-details-tab', { location: true, tab: 'details' }), screen('codes-roundtrip', { roundtrip: true }),
]
