/** Harness fixtures of the balances screen with the splitter and resizable columns (task T-1445). Invented data only.
 *  `stock-balances-layout`: nothing selected (the hint pane). `stock-balances-layout-open`: a row selected.
 *  `stock-balances-layout-saved`: a remembered layout (list 45 %, first column narrowed) seeded into the store. */
import { useState, type ReactElement } from 'react'
import BalancesPage from '@/modules/stock/register/BalancesPage'
import { LayoutPrefsProvider, useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import type { FixtureRoute, HarnessScreen } from '../types'
import { routes, withAuth } from './stockBalanceHistory'

const BALANCES = [
  { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1', quantity: '12.000' },
  { sku: 'i1', location: 'l2', org_unit: 'u1', responsible: 'e1', lot: 't1', unit_ref: 'm1', quantity: '5.000' },
  { sku: 'i1', location: 'l1', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: '240.500' },
  { sku: 'i1', location: 'l2', org_unit: 'u1', responsible: null, lot: null, unit_ref: 'm1', quantity: '1 200.000' },
]
const layoutRoutes: FixtureRoute[] = routes.map((r) =>
  r.match('/api/v1/modules/stock/balances', 'GET') ? { ...r, reply: (state) => ({ status: 200, body: { ledger_seq: 1041, next_cursor: null, rows: state === 'empty' ? [] : BALANCES } }) } : r,
)

/** Balances present, the movements route always empty: the history panel's own empty state (the balances empty state is `-open` with state `empty`). */
const historyEmptyRoutes: FixtureRoute[] = layoutRoutes.map((r) =>
  r.match('/api/v1/modules/stock/movements', 'GET') ? { ...r, reply: () => ({ status: 200, body: { next_cursor: null, rows: [] } }) } : r,
)

function Seeded({ children }: { children: ReactElement }) {
  const store = useLayoutPrefs()
  useState(() => {
    store.setPanes('stock.balances', 'list', [45])
    store.setCols('stock.balances', 'list', { sku: 14 })
    return null
  })
  return children
}

export const stockBalancesLayoutScreens: HarnessScreen[] = [
  { name: 'stock-balances-layout', routes: layoutRoutes, render: () => withAuth(<LayoutPrefsProvider><BalancesPage /></LayoutPrefsProvider>, true) },
  { name: 'stock-balances-layout-open', routes: layoutRoutes, render: () => withAuth(<LayoutPrefsProvider><BalancesPage initialSelectedId="i1|l1|u1|e1|t1|m1" /></LayoutPrefsProvider>, true) },
  { name: 'stock-balances-layout-history-empty', routes: historyEmptyRoutes, render: () => withAuth(<LayoutPrefsProvider><BalancesPage initialSelectedId="i1|l1|u1|e1|t1|m1" /></LayoutPrefsProvider>, true) },
  {
    name: 'stock-balances-layout-saved',
    routes: layoutRoutes,
    render: () => withAuth(<LayoutPrefsProvider><Seeded><BalancesPage initialSelectedId="i1|l1|u1|e1|t1|m1" /></Seeded></LayoutPrefsProvider>, true),
  },
]
