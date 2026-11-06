/** Harness fixtures of the remembered layout on the stock document screen (task T-1443). Invented data only.
 *  The real screen with a stored layout: panes and line columns narrower than the defaults, and a collapsed list.
 *  The store is the local one (localStorage), seeded before the first render. */
import { useState, type ReactElement } from 'react'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import { LAYOUT_STORAGE_KEY } from '@/lib/layoutStore'
import { resetDefaultLayoutStore } from '@/hooks/useLayoutPrefs'
import type { HarnessScreen } from '../types'
import { routes, withAuth } from './stockDocuments'

const REMEMBERED = { v: 1, shell: {}, screens: { 'stock.documents': { panes: { row: [16, 30] }, cols: { lines: { item: 24, lot: 12, qty: 10, price: 12 } } } } }
const COLLAPSED = { v: 1, shell: {}, screens: { 'stock.documents': { collapsed: { row: [0] } } } }

function Seeded({ layout, children }: { layout: object; children: ReactElement }): ReactElement {
  useState(() => {
    localStorage.setItem(`${LAYOUT_STORAGE_KEY}.anon`, JSON.stringify(layout))
    resetDefaultLayoutStore()
    return null
  })
  return children
}

export const stockDocumentsLayoutScreens: HarnessScreen[] = [
  { name: 'stock-docs-layout-remembered', routes, initialPath: '/doc-posted', routePattern: '/:id', render: () => withAuth(<Seeded layout={REMEMBERED}><DocumentPage /></Seeded>) },
  { name: 'stock-docs-layout-collapsed', routes, initialPath: '/doc-posted', routePattern: '/:id', render: () => withAuth(<Seeded layout={COLLAPSED}><DocumentPage /></Seeded>) },
]
