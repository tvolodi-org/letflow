/** Harness fixtures of T-1635 (REQ-799): the Replay view of the instance Graph tab, through the real component and
 *  hooks with fixture answers shaped like GET /instances/:id, GET /instances/:id/history?event_type=NODE_ENTERED and
 *  GET /definitions/:id. Invented data only. Screens: replay-middle (step 5 of 9 on the purchase request),
 *  replay-completed (last step, END), replay-join-waiting (k=4 of the T-793-3 parallel graph), replay-join-fired
 *  (k=6), replay-partial (first entry not START), replay-none (no entries: banner and Live view), replay-following (an
 *  ACTIVE instance on its last step), and the loading and error states (harness states of replay-completed). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { PageHeader } from '@/components/ui/PageHeader'
import { GraphModeSwitch, InstanceReplay } from '@/components/instances/InstanceReplay'
import type { DefinitionGraph, NodeEnteredItem, NodeType, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null) => ({ id, node_type, label, attributes: null })

const PURCHASE: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('submit', 'HUMAN_TASK', 'Submit purchase request'),
    n('check', 'SERVICE_TASK', 'Check budget'),
    n('amount', 'EXCLUSIVE_GATEWAY', 'Amount over limit?'),
    n('fork', 'PARALLEL_GATEWAY', 'Two approvals'),
    n('head', 'HUMAN_TASK', 'Approve as head of unit'),
    n('finance', 'HUMAN_TASK', 'Approve as finance'),
    n('join', 'PARALLEL_GATEWAY', 'Both approved'),
    n('order', 'SUB_PROCESS', 'Place order'),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'submit' },
    { id: 'e2', source: 'submit', target: 'check' },
    { id: 'e3', source: 'check', target: 'amount' },
    { id: 'e4', source: 'amount', target: 'fork', condition: 'amount > 100000' },
    { id: 'e5', source: 'amount', target: 'order', is_default: true },
    { id: 'e6', source: 'fork', target: 'head' },
    { id: 'e7', source: 'fork', target: 'finance' },
    { id: 'e8', source: 'head', target: 'join' },
    { id: 'e9', source: 'finance', target: 'join' },
    { id: 'e10', source: 'join', target: 'order' },
    { id: 'e11', source: 'order', target: 'end' },
  ],
}

// T-793-3 (test/letflow/engine/node_entered_test.exs): start→split e1, split→x e2, split→y e3, x→join e4, y→join e5, join→end e6.
const PARALLEL: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('split', 'PARALLEL_GATEWAY', 'Split'),
    n('x', 'HUMAN_TASK', 'Check stock'),
    n('y', 'HUMAN_TASK', 'Approve budget'),
    n('join', 'PARALLEL_GATEWAY', 'Join'),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'split' },
    { id: 'e2', source: 'split', target: 'x' },
    { id: 'e3', source: 'split', target: 'y' },
    { id: 'e4', source: 'x', target: 'join' },
    { id: 'e5', source: 'y', target: 'join' },
    { id: 'e6', source: 'join', target: 'end' },
  ],
}

const T0 = Date.parse('2026-11-09T09:00:00Z')
const at = (min: number, sec = 0) => new Date(T0 + min * 60_000 + sec * 1000).toISOString()
type Raw = [node: string, type: NodeType, via: string | null, at: string]
const items = (raw: Raw[], firstSeq = 1): NodeEnteredItem[] =>
  raw.map(([node_id, node_type, via_edge_id, created_at], i) => ({
    event_id: `ne-${firstSeq + i}`,
    event_type: 'NODE_ENTERED',
    sequence_number: firstSeq + i,
    created_at,
    actor_display_name: null,
    payload: { node_id, node_type, via_edge_id },
  }))

const PURCHASE_RUN: Raw[] = [
  ['start', 'START', null, at(0)],
  ['submit', 'HUMAN_TASK', 'e1', at(0)],
  ['check', 'SERVICE_TASK', 'e2', at(12, 40)],
  ['amount', 'EXCLUSIVE_GATEWAY', 'e3', at(12, 42)],
  ['fork', 'PARALLEL_GATEWAY', 'e4', at(12, 42)],
  ['head', 'HUMAN_TASK', 'e6', at(12, 42)],
  ['finance', 'HUMAN_TASK', 'e7', at(12, 42)],
  ['join', 'PARALLEL_GATEWAY', 'e8', at(95, 5)],
  ['join', 'PARALLEL_GATEWAY', 'e9', at(184, 30)],
  ['order', 'SUB_PROCESS', 'e10', at(184, 30)],
  ['end', 'END', 'e11', at(190, 2)],
]
const PARALLEL_RUN: Raw[] = [
  ['start', 'START', null, at(0)],
  ['split', 'PARALLEL_GATEWAY', 'e1', at(0)],
  ['x', 'HUMAN_TASK', 'e2', at(0)],
  ['y', 'HUMAN_TASK', 'e3', at(0)],
  ['join', 'PARALLEL_GATEWAY', 'e4', at(5, 30)],
  ['join', 'PARALLEL_GATEWAY', 'e5', at(70, 30)],
  ['end', 'END', 'e6', at(70, 30)],
]

interface Case {
  graph: DefinitionGraph
  status: string
  entries: NodeEnteredItem[]
}

function routes(c: Case): FixtureRoute[] {
  return [
    {
      match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/history$/.test(p) && m === 'GET',
      reply: () => ({ status: 200, body: { items: c.entries, next_cursor: null, count: c.entries.length } }),
    },
    {
      match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/timeline$/.test(p) && m === 'GET',
      reply: () => ({ status: 200, body: { items: [], next_cursor: null, count: 0 } }),
    },
    {
      match: (p, m) => /^\/api\/v1\/instances\/[^/]+$/.test(p) && m === 'GET',
      reply: () => ({
        status: 200,
        body: {
          id: 'inst-replay',
          instance_id: 'inst-replay',
          definition_id: 'def-replay',
          status: c.status,
          current_nodes: c.status === 'ACTIVE' ? ['finance'] : [],
          definition_snapshot: c.graph,
          error_detail: null,
          variables: {},
        },
      }),
    },
    {
      match: (p, m) => p.startsWith('/api/v1/definitions/') && m === 'GET',
      reply: () => ({ status: 200, body: { id: 'def-replay', name: 'Purchase request', version: '3', status: 'ACTIVE', graph: c.graph } }),
    },
  ]
}

const AUTH = {
  session: { token: 'h.e30.s', tenant_id: 'harness-tenant' } as unknown as UserSession,
  isAuthenticated: true,
} as unknown as AuthContextValue
const ACCESS = {
  status: 'ready' as const,
  info: { roles: [], platform_tenant: false, user_id: 'u-harness', permissions: ['InstancesRead', 'DefinitionsRead'] },
}

function page(initialStep?: number): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <div className="lf-main">
          <main className="lf-content">
            <PageHeader eyebrow="Instances" title="Purchase request · instance" lede="Step through the recorded path of this instance." />
            <GraphModeSwitch mode="replay" onChange={() => {}} />
            <InstanceReplay instanceId="inst-replay" initialStep={initialStep} />
          </main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

function screen(name: string, c: Case, initialStep?: number): HarnessScreen {
  return { name, routes: routes(c), render: () => page(initialStep) }
}

export const instanceReplayScreens: HarnessScreen[] = [
  screen('replay-middle', { graph: PURCHASE, status: 'COMPLETED', entries: items(PURCHASE_RUN) }, 4),
  screen('replay-completed', { graph: PURCHASE, status: 'COMPLETED', entries: items(PURCHASE_RUN) }),
  screen('replay-join-waiting', { graph: PARALLEL, status: 'COMPLETED', entries: items(PARALLEL_RUN) }, 4),
  screen('replay-join-fired', { graph: PARALLEL, status: 'COMPLETED', entries: items(PARALLEL_RUN) }, 6),
  screen('replay-partial', { graph: PURCHASE, status: 'COMPLETED', entries: items(PURCHASE_RUN.slice(5), 41) }),
  screen('replay-none', { graph: PURCHASE, status: 'COMPLETED', entries: [] }),
  screen('replay-following', { graph: PURCHASE, status: 'ACTIVE', entries: items(PURCHASE_RUN.slice(0, 7)) }),
]
