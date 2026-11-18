/** REQ-838 harness states: one real issue draft at the exact balance and one above it, both opened in edit mode. */
import { useEffect, type ReactElement } from 'react'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import type { StockDocument } from '@/modules/stock/documents/documents.api'
import { holdHarnessReady } from '../fixtureFetch'
import type { FixtureRoute, HarnessScreen } from '../types'
import { OpenInEdit, routes, withAuth } from './stockDocuments'

function draft(quantity: string): StockDocument {
  return {
    id: 'negative-doc', kind: 'issue', state: 'draft', number: null, issued_at: null,
    org_unit_id: 'u1', location_id: 'l1', responsible_id: 'e1', counterparty_id: null,
    event_time: '2026-11-03T09:15:00Z', note: 'Negative balance warning demonstration',
    lines: [{ line_id: 'ln1', line_no: 1, catalog_item_id: 'i1', catalog_uom_id: 'm1', catalog_lot_id: null, quantity }],
    posted_at: null, posted_by: null, reversed_at: null, reversed_by: null, posting_check: null,
  }
}

function fixtureRoutes(doc: StockDocument): FixtureRoute[] {
  return [
    {
      match: (path, method) => path === '/api/v1/me/preferences' && method === 'GET',
      reply: () => ({
        status: 200,
        body: {
          preferences: { 'ui.document_layout': 'row' },
          effective: { 'ui.document_layout': 'row' },
          tenant_defaults: { 'ui.document_layout_default': 'row' },
        },
      }),
    },
    {
      match: (path, method) => path === '/api/v1/modules/stock/documents/negative-doc' && method === 'GET',
      reply: () => ({ status: 200, body: doc }),
    },
    {
      match: (path, method) => path === '/api/v1/modules/stock/posting-rules' && method === 'GET',
      reply: () => ({ status: 200, body: { negative_balance: 'allowed' } }),
    },
    {
      match: (path, method) => path === '/api/v1/modules/stock/balances' && method === 'GET',
      reply: () => ({
        status: 200,
        body: {
          next_cursor: null,
          rows: [{ sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: null, unit_ref: 'm1', quantity: '5' }],
        },
      }),
    },
    ...routes,
  ]
}

function screen(name: string, quantity: string): HarnessScreen {
  const doc = draft(quantity)
  return {
    name,
    routes: fixtureRoutes(doc),
    initialPath: '/negative-doc',
    routePattern: '/:id',
    render: () => withAuth(<OpenNegativeBalance warning={quantity === '7'}><DocumentPage /></OpenNegativeBalance>),
  }
}

/** Hold the shot until the asynchronous rule + balance reads have reached their visible state (bounded at 5 s). */
function OpenNegativeBalance({ warning, children }: { warning: boolean; children: ReactElement }): ReactElement {
  useEffect(() => {
    const release = holdHarnessReady()
    const started = Date.now()
    let clearSince = 0
    const id = window.setInterval(() => {
      const elapsed = Date.now() - started
      const warned = document.querySelector('[data-testid="negative-balance-warning"]') !== null
      const editing = document.querySelector('[data-testid="document-form"]') !== null
      if (!warning && editing && clearSince === 0) clearSince = elapsed
      if ((warning && warned) || (!warning && clearSince > 0 && elapsed - clearSince >= 500) || elapsed > 5000) {
        window.clearInterval(id)
        release()
      }
    }, 40)
    return () => {
      window.clearInterval(id)
      release()
    }
  }, [warning])
  return <OpenInEdit>{children}</OpenInEdit>
}

export const stockNegativeBalanceScreens: HarnessScreen[] = [
  screen('stock-document-negative-warning', '7'),
  screen('stock-document-negative-clear', '5'),
]
