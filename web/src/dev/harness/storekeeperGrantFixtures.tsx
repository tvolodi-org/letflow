/** Harness screens of the storekeeper asset-grant card (T-1570, D-097). `default` = read and post on, `empty` =
 *  grant off, `error` = load error with retry; `storekeeper-grant-missing` = assets module not installed (404). */
import { useEffect, useRef } from 'react'
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

/** Clicks the post box and then Save once the card has drawn, so the harness can shoot the write states. */
function Driver() {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const t = window.setInterval(() => {
      const root = ref.current
      const box = root?.querySelector<HTMLInputElement>('[data-testid=grant-post]')
      if (!root || !box) return
      window.clearInterval(t)
      box.click()
      window.setTimeout(() => root.querySelector<HTMLButtonElement>('button:not([disabled])')?.click(), 100)
    }, 50)
    return () => window.clearInterval(t)
  }, [])
  return <div ref={ref}>{card}</div>
}

const getRoute = {
  match: (p: string, m: string) => isGrants(p) && m === 'GET',
  reply: () => ({ status: 200, body: body(['AssetsRead', 'AssetsPost']) }),
}

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
  {
    name: 'storekeeper-grant-saving',
    routes: [getRoute, { match: (p, m) => isGrants(p) && m === 'PUT', pending: true, reply: () => ({ status: 200, body: {} }) }],
    render: () => <Driver />,
  },
  {
    name: 'storekeeper-grant-saveerror',
    routes: [getRoute, { match: (p, m) => isGrants(p) && m === 'PUT', reply: () => ({ status: 500, body: { title: 'Error', status: 500 } }) }],
    render: () => <Driver />,
  },
  {
    name: 'storekeeper-grant-saved',
    routes: [getRoute, { match: (p, m) => isGrants(p) && m === 'PUT', reply: (_s, _p, req) => ({ status: 200, body: body((req as { storekeeper: string[] }).storekeeper) }) }],
    render: () => <Driver />,
  },
]
