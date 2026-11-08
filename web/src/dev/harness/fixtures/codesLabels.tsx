/** Harness fixtures of the codes label printing (task T-1355, E3b). Invented data only. The query route answers
 *  by entity type and the equality filters the screen sends; the label route answers a small PDF stand-in. */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import CodesPage, { type CodesInitial } from '@/modules/codes/CodesPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

function rec(id: string, fields: Record<string, unknown>): EntityRecord {
  return {
    record_id: id,
    entity_type: 'code_tag',
    field_values: { active: true, ...fields },
    deleted: false,
    entity_def_version: '1',
    last_event_global_seq: 1,
  }
}

const CODES: EntityRecord[] = [
  rec('c1', { value: 'GATEA-BC-0001', kind: 'barcode', status: 'not_assigned' }),
  rec('c2', { value: 'GATEA-BC-0002', kind: 'barcode', status: 'assigned' }),
  rec('c3', { value: 'GATEA-QR-0001', kind: 'qr', status: 'not_assigned' }),
  rec('c4', { value: 'GATEA-QR-0002', kind: 'qr', status: 'not_assigned' }),
  rec('c5', { value: 'E280116061B9D57E00000001', kind: 'epc', status: 'not_assigned' }),
  rec('c6', { value: 'GATEA-BC-0003', kind: 'barcode', status: 'retired' }),
]

type Clause = { field: string; op: string; value?: unknown }

function answer(state: string, body: unknown) {
  const b = (body ?? {}) as { entity_type?: string; filters?: Clause[] }
  const eqs = (b.filters ?? []).filter((f) => f.op === 'eq' && f.field !== 'deleted')
  const items =
    state === 'empty' || b.entity_type !== 'code_tag'
      ? []
      : CODES.filter((r) => eqs.every((f) => r.field_values[f.field] === f.value))
  return { status: 200, body: { items, next_cursor: null } }
}

const routes: FixtureRoute[] = [
  { match: (path, method) => path === '/api/v1/entities/query' && method === 'POST', reply: (state, _p, body) => answer(state, body) },
  { match: (path, method) => path === '/api/v1/modules/codes/labels' && method === 'POST', reply: () => ({ status: 200, body: {} }) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['CodesWrite'] } }

function screen(name: string, initial?: CodesInitial): HarnessScreen {
  return {
    name,
    routes,
    render: ({ lang }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <main className="lf-content">
            <CodesPage locale={lang} initial={initial} />
          </main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  }
}

export const codesLabelScreens: HarnessScreen[] = [
  screen('codes-select', { labelIds: ['c1', 'c3'] }),
  screen('codes-select-all', { labelIds: ['c1', 'c2', 'c3', 'c4'] }),
  screen('codes-labels-error', { labelIds: ['c1', 'c3'], labelFailure: 'entry' }),
  screen('codes-labels-gone', { labelIds: ['c1', 'c3'], labelFailure: 'notFound' }),
  screen('codes-limit-hint', { labelIds: ['c1', 'c2', 'c3', 'c4'], labelLimit: true }),
  screen('codes-detail-print', { selectedId: 'c1' }),
]
