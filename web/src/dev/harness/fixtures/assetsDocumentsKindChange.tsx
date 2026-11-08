/** Harness fixtures of the change of kind document screens (T-1336 / C16). Invented data only. Own file (one registry
 *  line). Masters of the stock side (item, unit, lot) are answered here; the rest comes from the asset documents routes. */
import type { EntityRecord } from '@/types/api'
import DocumentNewPage from '@/modules/assets/documents/DocumentNewPage'
import DocumentPage from '@/modules/assets/documents/DocumentPage'
import type { FixtureRoute, HarnessScreen } from '../types'
import { ClickButton, EDIT_LABELS, SAVE_LABELS, routes as baseRoutes, withAuth } from './assetsDocuments'

const rec = (id: string, type: string, fields: Record<string, unknown>): EntityRecord => ({
  record_id: id, entity_type: type, field_values: { active: true, ...fields }, deleted: false, entity_def_version: '1', last_event_global_seq: 1,
})
const MASTERS: Record<string, EntityRecord[]> = {
  catalog_item: [
    rec('i1', 'catalog_item', { code: 'CH-01', name: 'Office chair', base_uom_id: 'm1', tracking_policy: 'none' }),
    rec('i2', 'catalog_item', { code: 'MON-27', name: 'Monitor 27 inch', base_uom_id: 'm1', tracking_policy: 'lot' }),
  ],
  catalog_uom: [rec('m1', 'catalog_uom', { code: 'pcs' })],
  catalog_lot: [rec('lot1', 'catalog_lot', { code: 'LOT-2026-07', item_id: 'i2' })],
}

const line = (n: number, over: Record<string, unknown>) => ({
  line_id: `kc${n}`, line_no: n, quantity: '5.000000000', catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null,
  stock_location_id: 'l1', stock_responsible_id: 'e1', target_kind: 'low_value', asset_org_unit_id: null, asset_location_id: 'l1',
  material_responsible_id: 'e2', actual_user_id: 'e2', inventory_number: `LV-0${200 + n}`, asset_name: 'Office chair for the open space', ...over,
})
const head = {
  kind: 'kind_change', org_unit_id: 'u1', event_time: '2026-11-03T09:15:00Z', reason_text: 'Chairs moved from stock to the asset register', note: null,
}
const KC_LINES = [line(1, {}), line(2, { catalog_item_id: 'i2', catalog_lot_id: 'lot1', quantity: '1.000000000', target_kind: 'fixed', inventory_number: 'FA-0301', asset_name: 'Monitor 27 inch', asset_org_unit_id: 'u2' })]
const DOCS: Record<string, Record<string, unknown>> = {
  'kc-draft': { id: 'kc-draft', state: 'draft', number: null, ...head, lines: KC_LINES },
  'kc-issued': { id: 'kc-issued', state: 'issued', number: 'AKC-2026-000004', issued_at: '2026-11-03T09:30:00Z', ...head, lines: KC_LINES },
  'kc-posted': {
    id: 'kc-posted', state: 'posted', number: 'AKC-2026-000004', issued_at: '2026-11-03T09:30:00Z', posted_at: '2026-11-03T10:00:00Z',
    posted_by: '5c1f0d2e-7a3b-4c4d-8e9f-0a1b2c3d4e5f', ...head,
    lines: [{ ...KC_LINES[0], asset_card_id: 'a3' }, { ...KC_LINES[1], asset_card_id: 'a1' }],
  },
  'kc-empty': { id: 'kc-empty', state: 'draft', number: null, ...head, lines: [] },
}

const routes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/entities/query' && method === 'POST',
    reply: (state, p, body) => {
      const b = (body ?? {}) as { entity_type?: string; filters?: { field: string; op: string; value?: unknown }[] }
      const items = MASTERS[b.entity_type ?? '']
      if (items === undefined) return baseRoutes[0]!.reply(state, p, body)
      const ids = b.filters?.find((f) => f.field === 'record_id')?.value
      const own = Array.isArray(ids) ? items.filter((r) => ids.includes(r.record_id)) : state === 'empty' ? [] : items
      return { status: 200, body: { items: own, next_cursor: null } }
    },
  },
  {
    match: (path, method) => path.startsWith('/api/v1/modules/assets/documents/kc-') && method === 'GET',
    reply: (_s, path) => {
      const doc = DOCS[decodeURIComponent(path.split('/').pop() ?? '')]
      return doc ? { status: 200, body: doc } : { status: 404, body: { error: 'not_found' } }
    },
  },
  ...baseRoutes,
]

const creating = (name: string, extra?: (el: React.ReactElement) => React.ReactElement): HarnessScreen => ({
  name, routes, initialPath: '/new?kind=kind_change', routePattern: '/new', render: () => withAuth((extra ?? ((e) => e))(<DocumentNewPage />)),
})
const view = (name: string, id: string, extra?: (el: React.ReactElement) => React.ReactElement): HarnessScreen => ({
  name, routes, initialPath: `/${id}`, routePattern: '/:id', render: () => withAuth((extra ?? ((e) => e))(<DocumentPage />)),
})

export const assetsKindChangeScreens: HarnessScreen[] = [
  creating('asset-document-kc-new'),
  creating('asset-document-kc-errors', (e) => <ClickButton labels={SAVE_LABELS}>{e}</ClickButton>),
  view('asset-document-kc-draft', 'kc-draft'),
  view('asset-document-kc-edit', 'kc-draft', (e) => <ClickButton labels={EDIT_LABELS}>{e}</ClickButton>),
  view('asset-document-kc-issued', 'kc-issued'),
  view('asset-document-kc-posted', 'kc-posted'),
  view('asset-document-kc-empty-lines', 'kc-empty'),
]
