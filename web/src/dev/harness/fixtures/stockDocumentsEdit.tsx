/** Harness fixtures of the draft edit states of the stock document screens (task T-1438): the states of the
 *  STATE-TABLE that no other fixture reaches. Invented data only; reuses the routes of the sibling fixtures. */
import { useEffect, type ReactElement } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import type { FixtureRoute, HarnessScreen } from '../types'
import { ACCESS, AUTH, OpenInEdit, routes, withAuth } from './stockDocuments'
import { routes as openingRoutes } from './stockOpening'

const tabsRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path === '/api/v1/me/preferences' && method === 'GET',
    reply: () => ({
      status: 200,
      body: {
        preferences: { 'ui.document_layout': 'tabs' },
        effective: { 'ui.document_layout': 'tabs' },
        tenant_defaults: { 'ui.document_layout_default': 'row' },
      },
    }),
  },
  ...routes,
]

/** Harness only: opens the draft in edit mode, empties the first quantity and presses Save draft (bounded to 5 s). */
function EditThenInvalid({ children }: { children: ReactElement }): ReactElement {
  useEffect(() => {
    let stage = 0
    const started = Date.now()
    const id = window.setInterval(() => {
      if (stage > 1 || Date.now() - started > 5000) return window.clearInterval(id)
      const buttons = Array.from(document.querySelectorAll('button'))
      if (stage === 0) {
        const edit = buttons.find((b) => b.textContent?.trim() === 'Edit')
        if (edit) {
          edit.click()
          stage = 1
        }
        return
      }
      const qty = document.querySelector<HTMLInputElement>('[data-testid="line-editor-row"] input[aria-label="Quantity"]')
      const save = buttons.find((b) => b.textContent?.trim() === 'Save draft')
      if (qty && save) {
        const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set
        set?.call(qty, '')
        qty.dispatchEvent(new Event('input', { bubbles: true }))
        window.setTimeout(() => save.click(), 30)
        stage = 2
        window.clearInterval(id)
      }
    }, 40)
    return () => window.clearInterval(id)
  }, [])
  return children
}

const READ_ONLY = { ...ACCESS, info: { ...ACCESS.info, permissions: ['StockRead'] } }

export const stockDocumentsEditScreens: HarnessScreen[] = [
  { name: 'stock-document-opening-edit', routes: openingRoutes, initialPath: '/doc-open-draft', routePattern: '/:id', render: () => withAuth(<OpenInEdit><DocumentPage /></OpenInEdit>) },
  { name: 'stock-document-draft-validation', routes, initialPath: '/doc-draft', routePattern: '/:id', render: () => withAuth(<EditThenInvalid><DocumentPage /></EditThenInvalid>) },
  { name: 'doc-layout-tabs-edit', routes: tabsRoutes, initialPath: '/doc-draft', routePattern: '/:id', render: () => withAuth(<OpenInEdit><DocumentPage /></OpenInEdit>) },
  {
    name: 'stock-document-draft-noperm',
    routes,
    initialPath: '/doc-draft',
    routePattern: '/:id',
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={READ_ONLY}>
          <div className="lf-main"><main className="lf-content"><DocumentPage /></main></div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
