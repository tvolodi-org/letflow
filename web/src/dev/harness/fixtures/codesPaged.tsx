/** Harness fixture of the paged code list (task T-1802): 250 invented codes served 100 per request, so the notice
 *  and "Load more" show. The query route answers by entity type and the cursor (the offset of the next row). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import CodesPage from '@/modules/codes/CodesPage'
import type { EntityRecord, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const CODES: EntityRecord[] = Array.from({ length: 250 }, (_, i) => ({
  record_id: `c${i}`,
  entity_type: 'code_tag',
  field_values: { active: true, value: `GATEA-BC-${String(i + 1).padStart(4, '0')}`, kind: 'barcode', status: 'not_assigned' },
  deleted: false,
  entity_def_version: '1',
  last_event_global_seq: 1,
}))

function answer(body: unknown) {
  const b = (body ?? {}) as { entity_type?: string; cursor?: string; page_size?: number }
  const all = b.entity_type === 'code_tag' ? CODES : []
  const start = Number(b.cursor ?? 0)
  const size = Number(b.page_size ?? all.length)
  return {
    status: 200,
    body: { items: all.slice(start, start + size), next_cursor: start + size < all.length ? String(start + size) : null },
  }
}

const routes: FixtureRoute[] = [
  { match: (path, method) => path === '/api/v1/entities/query' && method === 'POST', reply: (_state, _p, body) => answer(body) },
]

const AUTH = {
  session: { token: 'harness', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['CodesWrite'] } }

export const codesPagedScreens: HarnessScreen[] = [
  {
    name: 'codes-paged',
    routes,
    render: ({ lang }): ReactElement => (
      <AuthContext.Provider value={AUTH}>
        <AccessStateProvider state={ACCESS}>
          <main className="lf-content">
            <CodesPage locale={lang} />
          </main>
        </AccessStateProvider>
      </AuthContext.Provider>
    ),
  },
]
