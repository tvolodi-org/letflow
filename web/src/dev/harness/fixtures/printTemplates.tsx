/** Harness fixture of the print templates screen (T-1926). Dev only, invented data.
 *  `print-templates-shell`: the list with the scope note; the list answers `empty` and `error` states. */
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import PrintTemplatesPage from '@/pages/admin/PrintTemplatesPage'
import type { FixtureRoute, HarnessScreen } from '../types'
import { inShell } from './listDetailSlice5'

const ACCESS: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['TenantAdmin'] } }

const row = (id: string, status: string, version: number) => ({
  id, type_key: 'invoice', locale: 'ru', version_no: version, status, layout_hash: `hash-${id}`, layout_schema_version: 1,
  created_by: 'Aida Nurova', activated_by: null, activated_at: null, retired_at: null, reason_code: null,
  inserted_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z',
})

const routes: FixtureRoute[] = [
  {
    match: (p, m) => m === 'GET' && p === '/api/v1/documents/print-overrides',
    reply: (s) => {
      if (s === 'error') return { status: 500, body: { title: 'internal_error', status: 500 } }
      if (s === 'empty') return { status: 200, body: { overrides: [] } }
      return { status: 200, body: { overrides: [row('o1', 'active', 2), row('o2', 'draft', 3)] } }
    },
  },
]

export const printTemplatesScreens: HarnessScreen[] = [
  { name: 'print-templates-shell', initialPath: '/admin/print-templates', routes, render: inShell(ACCESS, <PrintTemplatesPage />) },
]
