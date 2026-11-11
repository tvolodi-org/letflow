/** Harness fixtures of T-1705 (REQ-812): the "Waiting since" block of the instance page, through the real component and
 *  hook with fixture answers shaped like GET /instances/:id/history?event_type=NODE_ENTERED. Invented data only.
 *  Screens: waiting-since (two waiting steps; its harness states give loading and error), waiting-truncated (the history
 *  never ends), waiting-none (no entries), waiting-partial (first entry not START), waiting-empty (recorded, nothing waits). */
import type { ReactElement } from 'react'
import { AuthContext, type AuthContextValue } from '@/auth/AuthContext'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { PageHeader } from '@/components/ui/PageHeader'
import { InstanceWaitingSince } from '@/components/instances/InstanceWaitingSince'
import type { DefinitionGraph, NodeEnteredItem, NodeType, UserSession } from '@/types/api'
import type { FixtureRoute, HarnessScreen } from '../types'

const n = (id: string, node_type: NodeType, label: string | null) => ({ id, node_type, label, attributes: null })

const GRAPH: DefinitionGraph = {
  nodes: [
    n('start', 'START', null),
    n('fork', 'PARALLEL_GATEWAY', 'Two approvals'),
    n('head', 'HUMAN_TASK', 'Approve as head of unit'),
    n('finance', 'HUMAN_TASK', 'Approve as finance'),
    n('join', 'PARALLEL_GATEWAY', 'Both approved'),
    n('end', 'END', null),
  ],
  edges: [
    { id: 'e1', source: 'start', target: 'fork' },
    { id: 'e2', source: 'fork', target: 'head' },
    { id: 'e3', source: 'fork', target: 'finance' },
    { id: 'e4', source: 'head', target: 'join' },
    { id: 'e5', source: 'finance', target: 'join' },
    { id: 'e6', source: 'join', target: 'end' },
  ],
}

const NOW = Date.now()
const ago = (min: number) => new Date(NOW - min * 60_000).toISOString()
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

// Head approved 40 min ago and reached the join; finance has waited 3 h 5 min.
const WAITING: Raw[] = [
  ['start', 'START', null, ago(185)],
  ['fork', 'PARALLEL_GATEWAY', 'e1', ago(185)],
  ['head', 'HUMAN_TASK', 'e2', ago(185)],
  ['finance', 'HUMAN_TASK', 'e3', ago(185)],
  ['join', 'PARALLEL_GATEWAY', 'e4', ago(40)],
]
const FINISHED: Raw[] = [
  ['start', 'START', null, ago(60)],
  ['fork', 'PARALLEL_GATEWAY', 'e1', ago(60)],
  ['head', 'HUMAN_TASK', 'e2', ago(60)],
  ['finance', 'HUMAN_TASK', 'e3', ago(60)],
  ['join', 'PARALLEL_GATEWAY', 'e4', ago(30)],
  ['join', 'PARALLEL_GATEWAY', 'e5', ago(20)],
  ['end', 'END', 'e6', ago(20)],
]

function routes(entries: NodeEnteredItem[], endless = false): FixtureRoute[] {
  return [
    {
      match: (p, m) => /^\/api\/v1\/instances\/[^/]+\/history$/.test(p) && m === 'GET',
      reply: (state) =>
        state === 'error'
          ? { status: 500, body: { title: 'Internal error', status: 500 } }
          : { status: 200, body: { items: entries, next_cursor: endless ? 'more' : null, count: entries.length } },
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

function page(): ReactElement {
  return (
    <AuthContext.Provider value={AUTH}>
      <AccessStateProvider state={ACCESS}>
        <div className="lf-main">
          <main className="lf-content">
            <PageHeader eyebrow="Instances" title="Purchase request · instance" lede="What this running instance is waiting for." />
            <section>
              <InstanceWaitingSince instanceId="inst-waiting" status="ACTIVE" graph={GRAPH} />
            </section>
          </main>
        </div>
      </AccessStateProvider>
    </AuthContext.Provider>
  )
}

function screen(name: string, entries: NodeEnteredItem[], endless = false): HarnessScreen {
  return { name, routes: routes(entries, endless), render: () => page() }
}

export const waitingSinceScreens: HarnessScreen[] = [
  screen('waiting-since', items(WAITING)),
  screen('waiting-truncated', items(WAITING), true),
  screen('waiting-none', []),
  screen('waiting-partial', items(WAITING.slice(2), 41)),
  screen('waiting-empty', items(FINISHED)),
]
