/** Harness fixtures of the resizable layout base (task T-1442, I1). Invented data only. The REAL AppShell (collapsible side
 *  nav with its splitter) around three registered layouts: `lf-doc` (list | header | lines, two splitters, column handles),
 *  `lf-jrn` (list | details, splitter sized after) and `lf-reg` (list | details). The preferences route answers from an
 *  in-memory object (per screen). `layout-base-collapsed` and `layout-base-remembered` start from a stored layout:
 *  collapsed side nav; side nav 320 px, panes 22 % / 18 %, narrower first columns. */
import { lazy, Suspense, useEffect, useRef, type ReactElement } from 'react'
import { Route, Routes } from 'react-router-dom'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { BrandingProvider } from '@/theming/BrandingProvider'
import { LayoutPrefsProvider, useLayoutPrefs } from '@/hooks/useLayoutPrefs'
import { SplitWrap, useSplit } from '@/components/ui/layout/Splitter'
import { useColResize } from '@/components/ui/layout/ColumnResize'
import { isWideHost } from '@/components/ui/layout/isWideHost'
import { layoutMessages } from '@/components/ui/layout/layoutMessages'
import { PageHeader } from '@/components/ui/PageHeader'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import type { UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

// Lazy: the real shell pulls the OIDC manager, which reads `window` at import; the harness registry is also imported in
// node-environment tests (harness.build.test.ts).
const AppShell = lazy(() => import('@/components/layout/AppShell').then((m) => ({ default: m.AppShell })))

type Kind = 'doc' | 'jrn' | 'reg'

const TXT = {
  en: { eyebrow: 'Stock', title: 'Receipts', lede: 'Drag the edges between panes, or focus one and press the arrow keys.', list: 'Documents', header: 'Header', lines: 'Lines', details: 'Details', item: 'Item', lot: 'Lot', qty: 'Quantity', value: 'Value', field: 'Warehouse', fieldValue: 'Almaty central warehouse', row: 'Receipt' },
  ru: { eyebrow: 'Склад', title: 'Поступления', lede: 'Перетащите границу между панелями или выберите её и нажимайте стрелки.', list: 'Документы', header: 'Шапка', lines: 'Строки', details: 'Подробности', item: 'Номенклатура', lot: 'Партия', qty: 'Количество', value: 'Сумма', field: 'Склад', fieldValue: 'Центральный склад, Алматы', row: 'Поступление' },
  kk: { eyebrow: 'Қойма', title: 'Түсімдер', lede: 'Панельдер арасындағы шекараны сүйреңіз немесе таңдап, көрсеткі пернелерін басыңыз.', list: 'Құжаттар', header: 'Тақырып', lines: 'Жолдар', details: 'Толығырақ', item: 'Тауар', lot: 'Партия', qty: 'Саны', value: 'Сомасы', field: 'Қойма', fieldValue: 'Алматы орталық қоймасы', row: 'Түсім' },
}

const COLS = [
  { id: 'item', w: 36, min: 120 },
  { id: 'lot', w: 18, min: 80 },
  { id: 'qty', w: 16, min: 80 },
  { id: 'value', w: 0, min: 80 },
]

/** A stored layout the screen starts with (what the preferences route answers until the first PUT). */
const SEED_COLLAPSED = { v: 1, shell: { sidenav: { collapsed: true } }, screens: {} }
/** T-1873: the pane that trapped users, a stored collapse of the first pane (its restore control must stay visible). */
const SEED_PANE_COLLAPSED = { v: 1, shell: {}, screens: { 'harness.layout': { collapsed: { 'doc-panes': [0], 'reg-panes': [0] } } } }
const SEED_REMEMBERED = {
  v: 1,
  shell: { sidenav: { w: 320 } },
  screens: { 'harness.layout': { panes: { 'doc-panes': [22, 18], 'jrn-panes': [30], 'reg-panes': [30] }, cols: { lines: { item: 24, lot: 14, qty: 12 } } } },
}

export function makeRoutes(seed: object | null): FixtureRoute[] {
  let stored: string | null = seed ? JSON.stringify(seed) : null
  const answer = () => ({ status: 200, body: { preferences: stored ? { 'ui.layout': stored } : {}, effective: {}, tenant_defaults: {} } })
  return [
    { match: (path) => path === '/health', reply: () => ({ status: 200, body: { status: 'ok' } }) },
    { match: (path, method) => path === '/api/v1/me/preferences' && method === 'GET', reply: answer },
    {
      match: (path, method) => path === '/api/v1/me/preferences' && method === 'PUT',
      reply: (_s, _p, body) => {
        stored = (body as { preferences?: Record<string, string | null> } | undefined)?.preferences?.['ui.layout'] ?? null
        return answer()
      },
    },
  ]
}

export const AUTH = {
  session: { token: 'harness', display_name: 'Aigerim Sarsenova', tenant_id: 'harness-tenant', tenant_slug: 'demo', tenant_display_name: 'Demo Holding', tenant_type: 'production' } as unknown as UserSession,
  isAuthenticated: true,
  isLoading: false,
  loginSource: null,
  login: async () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
  switchTenant: async () => 'ok',
  switchingToTenantSlug: null,
} as AuthContextValue

const SCREEN = 'harness.layout'
const wide = isWideHost

function Lines({ kind }: { kind: Kind }) {
  const t = TXT[useUiLocale()]
  const tableRef = useRef<HTMLTableElement>(null)
  useColResize(tableRef, {
    id: 'lines',
    screen: SCREEN,
    cols: COLS,
    enabled: () => wide(tableRef.current?.closest('main') as HTMLElement | null),
  })
  const rows = [
    ['Laptop 14 inch, aluminium case', 'LOT-2026-001', '12.000', '5 400 000.00'],
    ['Safety helmet', '—', '250.000', '875 000.00'],
    ['Cable 3 m, shielded, black', 'LOT-2026-014', '1 200.000', '360 000.00'],
  ]
  return (
    <div className="lf-table-wrap">
      <table className="lf-table" ref={tableRef} data-kind={kind}>
        <thead>
          <tr>
            <th data-col="item">{t.item}</th>
            <th data-col="lot">{t.lot}</th>
            <th data-col="qty">{t.qty}</th>
            <th data-col="value">{t.value}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r[0]}>
              <td>{r[0]}</td>
              <td className="mono">{r[1]}</td>
              <td className="mono">{r[2]}</td>
              <td className="mono">{r[3]}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
function Content({ kind }: { kind: Kind }) {
  const locale = useUiLocale()
  const t = TXT[locale]
  const lm = layoutMessages[locale]
  const store = useLayoutPrefs()
  const gridRef = useRef<HTMLDivElement>(null)
  const layerRef = useRef<HTMLDivElement>(null)
  // the design's pane rule: list | header | lines from 1440 px of container width, list | header below
  const kids = () => {
    const all = Array.from(gridRef.current?.children ?? []).filter((c) => c.hasAttribute('data-pane')) as HTMLElement[]
    return kind === 'doc' && (gridRef.current?.clientWidth ?? 0) < 1440 ? all.slice(0, 2) : all
  }
  useSplit(gridRef, layerRef, {
    id: `${kind}-panes`,
    screen: SCREEN,
    vars: kind === 'doc' ? ['--lf-pane-1', '--lf-pane-2'] : ['--lf-pane-1'],
    unit: 'pct',
    sized: kind === 'jrn' ? 'after' : 'before',
    min: kind === 'doc' ? [200, 260] : [320],
    flexMin: kind === 'doc' ? 320 : 360,
    collapsible: kind === 'jrn' ? [] : [0],
    labels: kind === 'doc' ? [t.list, t.header] : kind === 'jrn' ? [t.details] : [t.list],
    panes: kids,
    enabled: () => wide(gridRef.current),
  })
  const cardHead = (s: string) => (
    <div className="lf-card__head">
      <h2 className="lf-card__title">{s}</h2>
    </div>
  )
  const body = (children: ReactElement) => <div className="lf-card__body">{children}</div>
  const fields = body(
    <div className="lf-field">
      <label className="lf-field__label">{t.field}</label>
      <input className="lf-control" readOnly value={t.fieldValue} aria-label={t.field} />
    </div>,
  )
  return (
    <>
      <PageHeader
        eyebrow={t.eyebrow}
        title={t.title}
        lede={t.lede}
        actions={
          <button type="button" className="lf-btn lf-btn--ghost" data-testid="reset-layout" onClick={() => store.resetScreen(SCREEN)}>
            {lm.resetLayout}
          </button>
        }
      />
      <SplitWrap layerRef={layerRef}>
        {kind === 'doc' && (
          <div ref={gridRef} className="lf-doc">
            <section className="lf-card lf-doc__list" data-pane aria-label={t.list}>
              {cardHead(t.list)}
              {body(<p>{t.row} RC-000042</p>)}
            </section>
            <section className="lf-card lf-doc__header" data-pane aria-label={t.header}>
              {cardHead(t.header)}
              {fields}
            </section>
            <section className="lf-card lf-doc__lines" data-pane aria-label={t.lines}>
              {cardHead(t.lines)}
              <Lines kind={kind} />
            </section>
          </div>
        )}
        {kind === 'jrn' && (
          <div ref={gridRef} className="lf-jrn">
            <section className="lf-card lf-jrn__list" data-pane aria-label={t.list}>
              {cardHead(t.list)}
              <Lines kind={kind} />
            </section>
            <aside className="lf-card lf-jrn__details" data-pane aria-label={t.details}>
              {cardHead(t.details)}
              {fields}
            </aside>
          </div>
        )}
        {kind === 'reg' && (
          <div ref={gridRef} className="lf-reg">
            <section className="lf-card lf-reg__list" data-pane aria-label={t.list}>
              {cardHead(t.list)}
              {body(<p>{t.row} RC-000042</p>)}
            </section>
            <section className="lf-card" data-pane aria-label={t.details}>
              {cardHead(t.details)}
              {fields}
            </section>
          </div>
        )}
      </SplitWrap>
    </>
  )
}

/** T-1873: opens the phone drawer (the hamburger) once the shell is mounted, so the sidenav footer is shot at 390 px. */
function OpenDrawer(): null {
  useEffect(() => {
    if (window.innerWidth >= 900) return undefined
    // The headless shot is taken right after load: no transition, so the drawer is settled and fully opaque.
    const style = document.createElement('style')
    style.textContent = '.lf-sidenav, .lf-scrim { transition: none !important; animation: none !important; }'
    document.head.appendChild(style)
    const id = window.setInterval(() => {
      const b = document.querySelector<HTMLButtonElement>('[data-testid="topbar-menu"]')
      if (b && b.getAttribute('aria-expanded') !== 'true') b.click()
      if (b) window.clearInterval(id)
    }, 50)
    return () => {
      window.clearInterval(id)
      style.remove()
    }
  }, [])
  return null
}

function page(kind: Kind, drawer = false): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <LayoutPrefsProvider>
            <Suspense fallback={null}>
              <Routes>
                <Route element={<AppShell fluid />}>
                  <Route path="*" element={<><Content kind={kind} />{drawer && <OpenDrawer />}</>} />
                </Route>
              </Routes>
            </Suspense>
          </LayoutPrefsProvider>
        </AccessStateProvider>
      </BrandingProvider>
    </AuthContext.Provider>
  )
}

export const layoutBaseScreens: HarnessScreen[] = [
  { name: 'layout-base', routes: makeRoutes(null), render: () => page('doc') },
  { name: 'layout-base-drawer', routes: makeRoutes(null), render: () => page('doc', true) },
  { name: 'layout-base-journal', routes: makeRoutes(null), render: () => page('jrn') },
  { name: 'layout-base-registry', routes: makeRoutes(null), render: () => page('reg') },
  { name: 'layout-base-collapsed', routes: makeRoutes(SEED_COLLAPSED), render: () => page('doc') },
  { name: 'layout-base-pane-collapsed', routes: makeRoutes(SEED_PANE_COLLAPSED), render: () => page('doc') },
  { name: 'layout-base-remembered', routes: makeRoutes(SEED_REMEMBERED), render: () => page('doc') },
]
