/** Harness fixture of T-2752: Edit Tenant with Deactivate / Reactivate. Four screens: active tenant, inactive tenant,
 *  the confirm dialog open, and the 409 answer (platform tenant) shown in the dialog after confirm. */
import { useEffect } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import EditTenantPage from '@/pages/admin/tenants/EditTenantPage'
import { holdHarnessReady } from '../fixtureFetch'
import type { FixtureRoute, HarnessScreen } from '../types'

const tenant = (status: 'active' | 'inactive') => ({
  slug: 'known-co', display_name: 'Known Co', idp_realm_id: 'known-realm', tenant_type: 'production', status,
  hostname: 'known.example.com', redirect_uris: ['https://known.example.com/cb'],
})

const routes = (status: 'active' | 'inactive', conflict = false): FixtureRoute[] => [
  { match: (p, m) => m === 'GET' && p === '/api/v1/tenants/known-co', reply: () => ({ status: 200, body: tenant(status) }) },
  {
    match: (p, m) => m === 'POST' && p === '/api/v1/tenants/known-co/deactivate',
    reply: () => conflict
      ? { status: 409, body: { title: 'Conflict', status: 409 } }
      : { status: 200, body: tenant('inactive') },
  },
]

function click(testid: string, text: string, done: () => void): boolean {
  const host = document.querySelector(`[data-testid="${testid}"]`)
  const btn = host?.querySelector('button') ?? Array.from(document.querySelectorAll('button')).find(b => b.textContent === text)
  if (!btn) return false
  ;(btn as HTMLButtonElement).click()
  done()
  return true
}

/** After mount: press the status button, and optionally the dialog's confirm button. */
function Driver({ confirm }: { confirm: boolean }) {
  useEffect(() => {
    const release = holdHarnessReady()
    let stop = false
    const step = (n: number) => {
      if (stop) return
      if (n > 200) { release(); return }
      if (!click('edit-tenant-status-action', 'Deactivate', () => {})) { requestAnimationFrame(() => step(n + 1)); return }
      if (!confirm) { setTimeout(release, 300); return }
      setTimeout(() => {
        const btns = Array.from(document.querySelectorAll('[role="dialog"] button, dialog button'))
        const ok = btns.find(b => b.textContent === 'Deactivate') as HTMLButtonElement | undefined
        ok?.click()
        setTimeout(release, 500)
      }, 300)
    }
    step(0)
    return () => { stop = true; release() }
  }, [confirm])
  return null
}

function page(driver: 'none' | 'open' | 'confirm') {
  return () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    return (
      <QueryClientProvider client={qc}>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <EditTenantPage />
          {driver !== 'none' && <Driver confirm={driver === 'confirm'} />}
        </AccessStateProvider>
      </QueryClientProvider>
    )
  }
}

const base = { initialPath: '/admin/tenants/known-co/edit', routePattern: '/admin/tenants/:slug/edit' }

export const editTenantPageScreens: HarnessScreen[] = [
  { name: 'edit-tenant-active', ...base, routes: routes('active'), render: page('none') },
  { name: 'edit-tenant-inactive', ...base, routes: routes('inactive'), render: page('none') },
  { name: 'edit-tenant-confirm', ...base, routes: routes('active'), render: page('open') },
  { name: 'edit-tenant-conflict', ...base, routes: routes('active', true), render: page('confirm') },
]
