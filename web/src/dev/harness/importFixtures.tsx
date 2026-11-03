/** Harness fixtures of the master data import screen (style task S6). Dev only, plain data.
 *  `master-data-import`: the first step (type picker and drop zone); `master-data-import-result`: the same page
 *  after a file was chosen and checked, with one refused row (a small driver picks the file and presses Check). */
import { useEffect, type ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import MasterDataImportPage from '@/pages/admin/import/MasterDataImportPage'
import type { FixtureRoute, HarnessScreen } from './types'

const AUTH: AuthContextValue = {
  session: {
    token: 'fixture',
    display_name: 'Fixture Admin',
    loginSource: 'oidc',
    tenant_slug: 'fixture',
    tenant_display_name: 'Fixture',
    tenant_id: 'fixture-tenant',
    tenant_type: 'test',
  },
  isAuthenticated: true,
  isLoading: false,
  loginSource: 'oidc',
  login: async () => undefined,
  logout: () => undefined,
  setSession: () => undefined,
  switchTenant: async () => 'ok',
  switchingToTenantSlug: null,
}

const ACCESS = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['EntitiesRecordsImport', 'EntitiesRecordsExport'] },
} as const

const MODULES: FixtureRoute = {
  match: path => path === '/api/v1/me/modules',
  reply: state => ({
    status: 200,
    body: {
      installed_modules:
        state === 'empty'
          ? []
          : [
              { module_id: 'org', version: '1' },
              { module_id: 'catalog_items', version: '1' },
            ],
    },
  }),
}

const IMPORT: FixtureRoute = {
  match: (path, method) => method === 'POST' && path.endsWith('/import'),
  reply: () => ({
    status: 200,
    body: {
      dry_run: true,
      results: [
        { status: 'ok', line: 2, outcome: 'created', external_ref: { system: 'erp', id: 'ITM-GLOVES' } },
        {
          status: 'error',
          line: 3,
          external_ref: { system: 'erp', id: 'ITM-BAD' },
          reason: { type: 'reference_not_found', header: 'base_uom_id' },
        },
        { status: 'ok', line: 4, outcome: 'updated', external_ref: { system: 'erp', id: 'ITM-VEST' } },
        { status: 'ok', line: 5, outcome: 'unchanged', external_ref: { system: 'erp', id: 'ITM-HELMET-2' } },
      ],
    },
  }),
}

/** The page resolves its language from navigator.languages (resolveUiLocale), so the harness language is set there. */
function Shell({ lang, children }: { lang: string; children: ReactElement }) {
  Object.defineProperty(window.navigator, 'languages', { value: [lang], configurable: true })
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        {/* The app shell's content column, so the screenshot shows the page as it sits in the app. */}
        <main className="lf-content">{children}</main>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

/** Picks a small .xlsx and presses Check, as a user would; the fixture answers the dry run. */
function CheckedDriver() {
  useEffect(() => {
    let tries = 0
    const timer = window.setInterval(() => {
      const input = document.querySelector<HTMLInputElement>('[data-testid="dropzone-input"]')
      if (input) {
        window.clearInterval(timer)
        const dt = new DataTransfer()
        dt.items.add(new File([new Uint8Array(9216)], 'gate_a_items_with_error.xlsx'))
        input.files = dt.files
        input.dispatchEvent(new Event('change', { bubbles: true }))
        window.setTimeout(() => document.querySelector<HTMLButtonElement>('[data-testid="import-check"]')?.click(), 50)
      } else if (++tries > 100) window.clearInterval(timer)
    }, 50)
    return () => window.clearInterval(timer)
  }, [])
  return <MasterDataImportPage />
}

export const masterDataImport: HarnessScreen = {
  name: 'master-data-import',
  routes: [MODULES, IMPORT],
  render: ({ lang }) => (
    <Shell lang={lang}>
      <MasterDataImportPage />
    </Shell>
  ),
}

export const masterDataImportResult: HarnessScreen = {
  name: 'master-data-import-result',
  routes: [MODULES, IMPORT],
  render: ({ lang }) => (
    <Shell lang={lang}>
      <CheckedDriver />
    </Shell>
  ),
}
