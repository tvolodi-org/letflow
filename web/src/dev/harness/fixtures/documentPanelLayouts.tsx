/** T-2006: real document families inside AppShell, with each effective document layout. */
import { lazy, Suspense, useEffect, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'
import { DOC_LAYOUT_NAMES } from '@/components/ui/doc/docLayouts'
import { stockDocumentsScreens } from './stockDocuments'
import { assetsDocumentsScreens } from './assetsDocuments'
import { stockCountScreens } from './stockCounts'
import { assetsCountsScreens } from './assetsCounts'
import { AUTH, makeRoutes } from './layoutBase'
import StockDocumentPage from '@/modules/stock/documents/DocumentPage'
import AssetDocumentPage from '@/modules/assets/documents/DocumentPage'
import CountsPage from '@/modules/stock/counts/CountsPage'
import type { HarnessScreen } from '../types'

const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))
const families = [
  ['stock', stockDocumentsScreens, 'stock-document-posted'],
  ['assets', assetsDocumentsScreens, 'asset-document-draft'],
  ['stock-count', stockCountScreens, 'stock-count-sheet'],
  ['asset-count', assetsCountsScreens, 'assets-counts-ordered'],
] as const

export const documentPanelLayoutScreens: HarnessScreen[] = families.flatMap(([family, screens, name]) => {
  const base = screens.find((s) => s.name === name)
  if (!base) throw new Error(`Missing document layout fixture: ${name}`)
  return DOC_LAYOUT_NAMES.map((layout): HarnessScreen => ({
    ...base,
    name: `panels-${family}-${layout}`,
    routes: [
      { match: (p) => p === '/api/v1/me/preferences', reply: () => ({ status: 200, body: { effective: { 'ui.document_layout': layout } } }) },
      ...base.routes,
      ...makeRoutes(null),
    ],
    render: (ctx) => (
      <AuthContext.Provider value={AUTH}>
        <BrandingProvider>
          <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'AssetsRead'] } }}>
            <LayoutPrefsProvider>
              <Suspense fallback={null}>
                <Routes><Route element={<AppShell fluid />}><Route path="*" element={base.render(ctx)} /></Route></Routes>
              </Suspense>
            </LayoutPrefsProvider>
          </AccessStateProvider>
        </BrandingProvider>
      </AuthContext.Provider>
    ),
  }))
})

function CountState({ action, children }: { action: 'new' | 'edit' | 'validation'; children: ReactElement }) {
  useEffect(() => {
    const selectors = action === 'edit' ? ['count-edit'] : action === 'validation' ? ['count-new', 'count-save'] : ['count-new']
    let step = 0
    const timer = window.setInterval(() => {
      const button = document.querySelector<HTMLElement>(`[data-testid="${selectors[step]}"]`)
      if (!button) return
      button.click()
      if (++step === selectors.length) window.clearInterval(timer)
    }, 20)
    return () => window.clearInterval(timer)
  }, [action])
  return children
}

const count = stockCountScreens.find((s) => s.name === 'stock-counts')!
documentPanelLayoutScreens.push(
  { ...count, name: 'panels-stock-count-list', initialPath: '/admin/stock/counts', routePattern: '/admin/stock/counts' },
  ...(['new', 'edit', 'validation'] as const).map((action): HarnessScreen => ({
    ...count, name: `panels-stock-count-${action}`, render: (ctx) => <CountState action={action}>{count.render(ctx)}</CountState>,
  })),
)

for (const [family, page] of [['stock', <StockDocumentPage />], ['assets', <AssetDocumentPage />], ['stock-count', <CountsPage />]] as const) {
  const base = documentPanelLayoutScreens.find((s) => s.name === `panels-${family}-row`)!
  documentPanelLayoutScreens.push({
    ...base, name: `panels-${family}-readonly`,
    render: () => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['StockRead', 'AssetsRead'] } }}>
          <div className="lf-main"><main className="lf-content">{page}</main></div>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  })
  documentPanelLayoutScreens.push({
    ...base, name: `panels-${family}-no-lines`,
    routes: base.routes.map((r) => ({
      ...r,
      reply: (state, path, body) => {
        const result = r.reply(state, path, body)
        if (typeof result.body !== 'object' || result.body === null) return result
        if ('lines' in result.body && Array.isArray(result.body.lines)) return { ...result, body: { ...result.body, lines: [] } }
        if (path.endsWith('/lines')) return { ...result, body: { ...result.body, rows: [] } }
        return result
      },
    })),
  })
}
