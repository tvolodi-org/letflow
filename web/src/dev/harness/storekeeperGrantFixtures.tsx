/** Harness screens of the storekeeper asset-grant card (T-1570, D-097). `default` = read and post on, `empty` =
 *  grant off, `error` = load error with retry; `storekeeper-grant-missing` = assets module not installed (404). */
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import StorekeeperAssetsGrantCard from '@/pages/admin/StorekeeperAssetsGrantCard'
import type { HarnessScreen } from './types'

const AUTH = {
  session: { tenant_id: 'harness-tenant' },
  isAuthenticated: true,
} as unknown as AuthContextValue

const card = (
  <AuthContext.Provider value={AUTH}>
    <div style={{ padding: 'var(--space-6)' }}>
      <StorekeeperAssetsGrantCard />
    </div>
  </AuthContext.Provider>
)

const isGrants = (p: string) => p === '/api/v1/tenant/role-grants'
const body = (storekeeper: string[]) => ({ storekeeper, grantable: { storekeeper: ['AssetsRead', 'AssetsPost'] } })

export const storekeeperGrantScreens: HarnessScreen[] = [
  {
    name: 'storekeeper-grant',
    routes: [
      {
        match: (p) => isGrants(p),
        reply: (state, _p, req) => {
          if (req && typeof req === 'object' && 'storekeeper' in req) return { status: 200, body: body((req as { storekeeper: string[] }).storekeeper) }
          return { status: 200, body: body(state === 'empty' ? [] : ['AssetsRead', 'AssetsPost']) }
        },
      },
    ],
    render: () => card,
  },
  {
    name: 'storekeeper-grant-missing',
    routes: [
      { match: (p) => isGrants(p), reply: () => ({ status: 404, body: { title: 'Not Found', status: 404 } }) },
    ],
    render: () => card,
  },
]
