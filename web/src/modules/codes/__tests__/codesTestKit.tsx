/** Shared helpers of the codes tests (GH 3606 / REQ-672): access state, a fake server over a mocked client, render. */
import { render } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useRoutes } from 'react-router-dom'
import { vi } from 'vitest'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import type { AccessState } from '@/auth/access/types'
import type { EntityRecord } from '@/types/api'
import { codesRouteObjects } from '../codesRoutes'

export const withAtom: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: ['CodesWrite'] },
}
export const withoutAtom: AccessState = {
  status: 'ready',
  info: { roles: [], platform_tenant: false, permissions: [] },
}

export type ClientMock = { post: ReturnType<typeof vi.fn>; patch: ReturnType<typeof vi.fn>; get: ReturnType<typeof vi.fn> }

export function rec(id: string, type: string, fields: Record<string, unknown>): EntityRecord {
  return {
    record_id: id,
    entity_type: type,
    field_values: { active: true, ...fields },
    deleted: false,
    entity_def_version: '1',
    last_event_global_seq: 1,
  }
}

type Clause = { field: string; op: string; value?: unknown }

/** A fake server: /entities/query answers from `data` honouring the active and deleted filters; every other
 *  post/patch goes to `onWrite` (default: answers an empty object). */
export function fakeServer(
  client: ClientMock,
  data: Record<string, EntityRecord[]>,
  onWrite: (method: 'post' | 'patch', path: string, body: Record<string, unknown>) => unknown = () => ({}),
) {
  client.post.mockImplementation(async (path: string, body: Record<string, unknown>) => {
    if (path === '/api/v1/entities/query') {
      const filters = (body['filters'] ?? []) as Clause[]
      const onlyActive = filters.some((f) => f.field === 'active' && f.value === true)
      const eqs = filters.filter((f) => f.op === 'eq' && f.field !== 'active' && f.field !== 'deleted')
      const items = (data[body['entity_type'] as string] ?? []).filter(
        (r) =>
          !r.deleted &&
          (!onlyActive || r.field_values['active'] === true) &&
          eqs.every((f) => r.field_values[f.field] === f.value),
      )
      return { items, next_cursor: null }
    }
    return onWrite('post', path, body)
  })
  client.patch.mockImplementation(async (path: string, body: Record<string, unknown>) => onWrite('patch', path, body))
}

export function queryBodies(client: ClientMock, type: string): Record<string, unknown>[] {
  return client.post.mock.calls
    .filter(([p, b]) => p === '/api/v1/entities/query' && (b as { entity_type: string }).entity_type === type)
    .map(([, b]) => b as Record<string, unknown>)
}

export function writeCalls(client: ClientMock) {
  const calls: { order: number; method: string; path: string; body: Record<string, unknown> }[] = []
  client.post.mock.calls.forEach(([p, b], i) => {
    if (p !== '/api/v1/entities/query') calls.push({ order: client.post.mock.invocationCallOrder[i], method: 'POST', path: p as string, body: b as Record<string, unknown> })
  })
  client.patch.mock.calls.forEach(([p, b], i) => {
    calls.push({ order: client.patch.mock.invocationCallOrder[i], method: 'PATCH', path: p as string, body: b as Record<string, unknown> })
  })
  return calls.sort((a, b) => a.order - b.order)
}

function Routes() {
  return useRoutes(codesRouteObjects)
}

export function renderCodes(path: string, access: AccessState = withAtom, queryClient?: QueryClient) {
  const qc = queryClient ?? new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const result = render(
    <QueryClientProvider client={qc}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
  return { ...result, queryClient: qc }
}

export function problem(status: number, body: Record<string, unknown>) {
  return { status, message: 'x', code: String(status), details: body }
}
