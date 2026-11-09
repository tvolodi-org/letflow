/** Harness fixtures of the import error report (T-1556). Dev only, plain data. The assets module is installed so the
 *  picker offers the asset types; three states of the page after a file was chosen and the buttons pressed:
 *  `import-report-refused` (check: refused rows with a named column and a localized violation),
 *  `import-report-not-applied` (check clean, import answered applied:false: nothing imported, would-be counts),
 *  `import-report-bad-header` (the 422 of a wrong header, naming the column). */
import { useEffect, type ReactElement } from 'react'
import { AuthContext } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import MasterDataImportPage from '@/pages/admin/import/MasterDataImportPage'
import { holdHarnessReady } from './fixtureFetch'
import { AUTH } from './importFixtures'
import type { FixtureRoute, HarnessScreen } from './types'

const ACCESS: AccessState = {
  status: 'ready',
  info: {
    roles: [],
    platform_tenant: false,
    permissions: ['EntitiesRecordsImport', 'EntitiesRecordsExport', 'AssetsCardWrite', 'AssetsPost'],
  },
}

const MODULES: FixtureRoute = {
  match: path => path === '/api/v1/me/modules',
  reply: () => ({ status: 200, body: { installed_modules: [{ module_id: 'assets', version: '1' }] } }),
}

const OK = (line: number, outcome: string, id: string) => ({ status: 'ok', line, outcome, external_ref: { system: 'erp', id } })
const DUPLICATE = {
  status: 'error',
  line: 4,
  external_ref: { system: 'erp', id: 'CARD-0003' },
  reason: { type: 'asset_inventory_number_taken', header: 'inventory_number' },
}
const NOT_A_NUMBER = {
  status: 'error',
  line: 6,
  external_ref: { system: 'erp', id: 'CARD-0005' },
  reason: { type: 'csv_invalid_decimal', header: 'purchase_value' },
}
const VIOLATION = {
  status: 'error',
  line: 7,
  external_ref: { system: 'erp', id: 'CARD-0006' },
  reason: {
    type: 'record_payload_invalid',
    violations: [{ code: 'unique', path: ['code'], message: 'this value has already been taken' }],
  },
}

function Shell({ children }: { children: ReactElement }) {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <main className="lf-content">{children}</main>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

/** Picks a small .xlsx, presses Check and, when `confirm`, presses Import once the check is clean. */
function Driver({ confirm }: { confirm: boolean }) {
  useEffect(() => {
    let tries = 0
    let started = false
    let confirmed = false
    const release = holdHarnessReady()
    const stop = (timer: number) => {
      window.clearInterval(timer)
      release()
    }
    const timer = window.setInterval(() => {
      const input = document.querySelector<HTMLInputElement>('[data-testid="dropzone-input"]')
      const ready = document.querySelector('[data-testid="import-not-applied"], [data-testid="import-error"]')
      const checked = document.querySelector('[data-testid="import-dry-run"]')
      if (ready || (checked && !confirm)) stop(timer)
      else if (checked && confirm && !confirmed) {
        confirmed = true
        document.querySelector<HTMLButtonElement>('[data-testid="import-confirm"]')?.click()
      } else if (input && !started) {
        started = true
        const dt = new DataTransfer()
        dt.items.add(new File([new Uint8Array(9216)], 'asset_cards.xlsx'))
        input.files = dt.files
        input.dispatchEvent(new Event('change', { bubbles: true }))
        window.setTimeout(() => document.querySelector<HTMLButtonElement>('[data-testid="import-check"]')?.click(), 50)
      } else if (++tries > 300) stop(timer)
    }, 50)
    return () => stop(timer)
  }, [confirm])
  return <MasterDataImportPage />
}

const REFUSED: FixtureRoute = {
  match: (path, method) => method === 'POST' && path.endsWith('/import'),
  reply: () => ({
    status: 200,
    body: { dry_run: true, results: [OK(2, 'created', 'CARD-0001'), OK(3, 'updated', 'CARD-0002'), DUPLICATE, OK(5, 'unchanged', 'CARD-0004'), NOT_A_NUMBER, VIOLATION] },
  }),
}

let calls = 0
/** First call is the check (clean), the second the import: rolled back by a row the check could not see. */
const NOT_APPLIED: FixtureRoute = {
  match: (path, method) => method === 'POST' && path.endsWith('/import'),
  reply: () => {
    calls += 1
    return calls % 2 === 1
      ? { status: 200, body: { dry_run: true, results: [OK(2, 'created', 'CARD-0001'), OK(3, 'created', 'CARD-0002')] } }
      : { status: 200, body: { applied: false, results: [OK(2, 'created', 'CARD-0001'), DUPLICATE, OK(5, 'updated', 'CARD-0004')] } }
  },
}

const BAD_HEADER: FixtureRoute = {
  match: (path, method) => method === 'POST' && path.endsWith('/import'),
  reply: () => ({
    status: 422,
    body: {
      title: 'Unprocessable Entity',
      status: 422,
      detail: 'xlsx header has a column that is not a field of the entity type',
      code: 'xlsx_unknown_header',
      headers: ['Inv no'],
    },
  }),
}

const screen = (name: string, route: FixtureRoute, confirm: boolean): HarnessScreen => ({
  name,
  routes: [MODULES, route],
  render: () => (
    <Shell>
      <Driver confirm={confirm} />
    </Shell>
  ),
})

export const importReportScreens: HarnessScreen[] = [
  screen('import-report-refused', REFUSED, false),
  screen('import-report-not-applied', NOT_APPLIED, true),
  screen('import-report-bad-header', BAD_HEADER, false),
]
