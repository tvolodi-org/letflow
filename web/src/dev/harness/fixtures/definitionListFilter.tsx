/** Harness fixture of T-3161: the process list with the word + status filter combined. Invented data.
 *  The page keeps both filters in local state, so a small wrapper types the word and picks the status
 *  after mount (the same DOM events a user makes); each screen's fake API answers what the server
 *  now answers for that combination (the status filter is part of the search). */
import { useEffect, type ReactElement } from 'react'
import type { ProcessDefinition } from '@/types/api'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import type { HarnessScreen } from '../types'

const AUTH = { session: { token: 'harness', tenant_id: 'harness-tenant' }, isAuthenticated: true } as unknown as AuthContextValue
const ACCESS: AccessState = { status: 'ready', info: { roles: [], platform_tenant: false, permissions: ['DefinitionsWrite', 'DefinitionsRead', 'MyAccessRead'] } }

const def = (id: string, name: string, version: string, status: ProcessDefinition['status']): ProcessDefinition => ({
  id,
  name,
  version,
  status,
  graph: { nodes: [], edges: [] },
  description: '',
  created_by: '7c1f0a52-3d0e-4b0a-9c3a-1f4d2e8b6a10',
  created_at: '2026-11-05T09:30:00Z',
  updated_at: '2026-11-05T09:30:00Z',
})

const ACTIVE = def('r2', 'platform.register_tenant', '2', 'ACTIVE')
const OLD = def('r1', 'platform.register_tenant', '1', 'DEPRECATED')
const OTHER = def('p1', 'purchase-request', '2', 'ACTIVE')
const hit = (d: ProcessDefinition, rank: number) => ({ definition: d, rank })

function Driver({ word, status }: { word: string; status: string }): ReactElement {
  useEffect(() => {
    const timer = setTimeout(() => {
      const input = document.querySelector<HTMLInputElement>('[data-testid="definition-search"]')
      const select = document.querySelector<HTMLSelectElement>('[data-testid="status-filter-select"]')
      if (input && word) {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set?.call(input, word)
        input.dispatchEvent(new Event('input', { bubbles: true }))
      }
      if (select && status) {
        Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')?.set?.call(select, status)
        select.dispatchEvent(new Event('change', { bubbles: true }))
      }
    }, 0)
    return () => clearTimeout(timer)
  }, [word, status])
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <div className="lf-main">
          <main className="lf-content">
            <DefinitionListPage />
          </main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

const screen = (name: string, word: string, status: string, listItems: ProcessDefinition[], searchItems: ProcessDefinition[]): HarnessScreen => ({
  name,
  routes: [
    {
      match: (p, m) => m === 'GET' && p === '/api/v1/definitions/search',
      reply: () => ({ status: 200, body: { items: searchItems.map((d, i) => hit(d, 1 - i * 0.1)), next_cursor: null } }),
    },
    {
      match: (p, m) => m === 'GET' && p === '/api/v1/definitions',
      reply: () => ({ status: 200, body: { items: listItems, next_cursor: null } }),
    },
  ],
  render: (): ReactElement => <Driver word={word} status={status} />,
})

export const definitionListFilterScreens: HarnessScreen[] = [
  // The shot is taken before the search debounce (300 ms) fires, so the fake list answers what the
  // search answers for the same state: the picture is the settled screen.
  // (a) word alone: the active version and its older version are both found.
  screen('pd-filter-word', 'register', '', [ACTIVE, OLD], [ACTIVE, OLD]),
  // (b) word + status Active: the same active row (the row that used to go missing).
  screen('pd-filter-word-active', 'register', 'ACTIVE', [ACTIVE], [ACTIVE]),
  // (c) status Active, word cleared: the active rows of every process.
  screen('pd-filter-active', '', 'ACTIVE', [ACTIVE, OTHER], [ACTIVE]),
]
