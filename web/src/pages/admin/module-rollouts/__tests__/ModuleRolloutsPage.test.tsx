// @vitest-environment jsdom
/** T-1660: the module rollout operator screen. T1 list, T2 outcomes, T3 halted, T4 start, T5 resume, T7 catalogs. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { queryKeys } from '@/api/queryKeys'
import ModuleRolloutsPage from '../ModuleRolloutsPage'
import { STALE_RUNNING_MINUTES, canResume } from '../moduleRolloutsModel'
import { moduleRolloutsMessages } from '../moduleRolloutsMessages'

expect.extend(jestDomMatchers)

const clientMock = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))
vi.mock('@/api/useTenantScopedQueryKeys', async () => {
  const { queryKeys: qk } = await import('@/api/queryKeys')
  return { useTenantScopedQueryKeys: () => ({ moduleRollouts: { all: () => qk.moduleRollouts.all('t1'), list: () => qk.moduleRollouts.list('t1'), status: (id: string) => qk.moduleRollouts.status('t1', id) } }) }
})

const BASE = '/api/v1/platform-module-rollouts'
const rollout = (over: Record<string, unknown> = {}) => ({
  id: 'r1', module_id: 'assets', to_version: '1.4.0', status: 'running', halt_after: 3, consecutive_failures: 0,
  started_at: '2026-11-10T09:00:00Z', completed_at: null, halted_at: null, ...over,
})
const outcome = (tenant_id: string, status: string, over: Record<string, unknown> = {}) => ({
  tenant_id, status, error_code: null, plan_hash: null, attempted_at: null, completed_at: null, ...over,
})

interface Setup {
  list?: unknown
  detail?: unknown
  detailError?: { status: number }
  tenants?: unknown
}
function setup(s: Setup) {
  clientMock.get.mockImplementation((path: string) => {
    if (path === BASE) return Promise.resolve(s.list ?? { rollouts: [] })
    if (path.startsWith(`${BASE}/`)) return s.detailError ? Promise.reject({ ...s.detailError, message: 'x', code: 'x' }) : Promise.resolve(s.detail)
    if (path === '/api/v1/tenants') return Promise.resolve(s.tenants ?? { items: [] })
    return Promise.reject(new Error(`unexpected ${path}`))
  })
}

function renderPage(initial = '/admin/module-rollouts') {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[initial]}>
        <ModuleRolloutsPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  clientMock.get.mockReset()
  clientMock.post.mockReset()
})
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().setLocaleTransient('en')
})

describe('T1 list', () => {
  it('lists rollouts with module, version, status and counts', async () => {
    setup({ list: { rollouts: [{ rollout: rollout({ status: 'halted' }), counts: { succeeded: 2, failed: 1, outside_window: 3, pending: 0 } }] } })
    renderPage()
    const list = await screen.findByTestId('module-rollouts-list')
    await waitFor(() => expect(list).toHaveTextContent('assets'))
    expect(list).toHaveTextContent('1.4.0')
    expect(list).toHaveTextContent('Succeeded 2 · Failed 1 · Outside window 3')
    expect(list).not.toHaveTextContent('Pending 0')
    expect(screen.getByTestId('module-rollout-status-halted')).toBeInTheDocument()
  })
  it('empty list says so', async () => {
    setup({})
    renderPage()
    expect(await screen.findByText('No rollouts yet')).toBeInTheDocument()
  })
  it('error shows a retry that reloads', async () => {
    clientMock.get.mockRejectedValueOnce({ status: 500, message: 'x', code: 'x' }).mockResolvedValue({ rollouts: [] })
    renderPage()
    expect(await screen.findByText('The rollouts could not be loaded.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(await screen.findByText('No rollouts yet')).toBeInTheDocument()
  })
})

describe('T2 outcomes', () => {
  it('shows each company, outside_window with its own badge and note, and falls back to the tenant id', async () => {
    setup({
      list: { rollouts: [{ rollout: rollout(), counts: {} }] },
      detail: { rollout: rollout(), outcomes: [outcome('ten-1', 'succeeded'), outcome('ten-2', 'outside_window'), outcome('ten-3', 'failed', { error_code: 'migration_failed' })] },
      tenants: { items: [{ tenant_id: 'ten-1', slug: 'a', display_name: 'Acme' }] },
    })
    renderPage('/admin/module-rollouts?rollout=r1')
    const table = await screen.findByTestId('module-rollouts-outcomes')
    await waitFor(() => expect(table).toHaveTextContent('Acme'))
    expect(table).toHaveTextContent('ten-2')
    expect(screen.getByTestId('module-outcome-outside_window')).toHaveTextContent('Outside window')
    expect(screen.getByTestId('module-outcome-outside-window-note')).toHaveTextContent('retried by the next Start or Resume')
    expect(table).toHaveTextContent('migration_failed')
  })
  it('renders the detail inside ListDetail; Back and Escape close it', async () => {
    setup({ list: { rollouts: [{ rollout: rollout(), counts: {} }] }, detail: { rollout: rollout(), outcomes: [outcome('ten-1', 'succeeded')] } })
    renderPage('/admin/module-rollouts?rollout=r1')
    const md = await screen.findByTestId('registry')
    expect(md).toHaveAttribute('data-detail', 'open')
    expect(await screen.findByTestId('module-rollouts-detail')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('list-detail-back'))
    await waitFor(() => expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed'))
    expect(screen.getByTestId('module-rollouts-detail-empty')).toBeInTheDocument()
  })

  it('Escape closes the open detail', async () => {
    setup({ list: { rollouts: [{ rollout: rollout(), counts: {} }] }, detail: { rollout: rollout(), outcomes: [] } })
    renderPage('/admin/module-rollouts?rollout=r1')
    await screen.findByTestId('module-rollouts-detail')
    fireEvent.keyDown(screen.getByTestId('registry'), { key: 'Escape' })
    await waitFor(() => expect(screen.getByTestId('registry')).toHaveAttribute('data-detail', 'closed'))
  })

  it('the start failure text does not promise that nothing changed', () => {
    expect(moduleRolloutsMessages.en['moduleRollouts.start.failed']).not.toMatch(/Nothing was changed/)
  })

  it('zero outcomes: no companies and no Resume', async () => {
    setup({ detail: { rollout: rollout({ status: 'completed' }), outcomes: [] } })
    renderPage('/admin/module-rollouts?rollout=r1')
    expect(await screen.findByText('No companies')).toBeInTheDocument()
    expect(screen.queryByTestId('module-rollouts-resume')).toBeNull()
  })
  it('unknown rollout id renders the not-found text', async () => {
    setup({ detailError: { status: 404 } })
    renderPage('/admin/module-rollouts?rollout=nope')
    expect(await screen.findByText('This rollout was not found.')).toBeInTheDocument()
  })
})

describe('T3 halted', () => {
  it('shows the banner with the failure count and Resume', async () => {
    setup({ detail: { rollout: rollout({ status: 'halted', consecutive_failures: 3, halted_at: '2026-11-10T10:00:00Z' }), outcomes: [outcome('ten-1', 'failed')] } })
    renderPage('/admin/module-rollouts?rollout=r1')
    expect(await screen.findByTestId('module-rollouts-halted')).toHaveTextContent('Stopped after 3 failures in a row. Remaining companies were not touched.')
    expect(screen.getByTestId('module-rollouts-failures')).toHaveTextContent('3 of 3')
    expect(screen.getByTestId('module-rollouts-resume')).toBeInTheDocument()
  })
})

describe('T4 start', () => {
  it('is disabled while the module id is empty, posts the trimmed id and selects the returned rollout', async () => {
    const started = { rollout: rollout({ id: 'r9', module_id: 'assets' }), outcomes: [outcome('ten-1', 'succeeded')] }
    setup({ detail: started })
    clientMock.post.mockResolvedValue(started)
    renderPage()
    const start = screen.getByTestId('module-rollouts-start')
    expect(start).toBeDisabled()
    fireEvent.change(screen.getByTestId('module-rollouts-module-input'), { target: { value: '  assets ' } })
    expect(start).toBeEnabled()
    fireEvent.click(start)
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledWith(BASE, { module_id: 'assets' }))
    expect(await screen.findByTestId('module-rollouts-detail')).toBeInTheDocument()
  })
  it('404 renders Unknown module', async () => {
    setup({})
    clientMock.post.mockRejectedValue({ status: 404, message: 'x', code: 'x' })
    renderPage()
    fireEvent.change(screen.getByTestId('module-rollouts-module-input'), { target: { value: 'nope' } })
    fireEvent.click(screen.getByTestId('module-rollouts-start'))
    expect(await screen.findByText('Unknown module.')).toBeInTheDocument()
  })
})

describe('T5 resume', () => {
  const NOW = new Date('2026-11-11T12:00:00Z')
  const ago = (min: number) => new Date(NOW.getTime() - min * 60_000).toISOString()
  const cases: [string, string, Parameters<typeof outcome>[], boolean][] = [
    ['halted', 'halted', [['a', 'succeeded']], true],
    ['completed + failed', 'completed', [['a', 'failed']], true],
    ['completed + succeeded/skipped', 'completed', [['a', 'succeeded'], ['b', 'skipped']], false],
    ['running + only outside_window', 'running', [['a', 'outside_window']], true],
    ['running + pending', 'running', [['a', 'pending']], true],
    ['running + stale running (16 min)', 'running', [['a', 'running', { attempted_at: ago(16) }]], true],
    ['running + fresh running (14 min)', 'running', [['a', 'running', { attempted_at: ago(14) }]], false],
    ['running + running without attempted_at', 'running', [['a', 'running']], false],
    ['zero outcomes', 'completed', [], false],
  ]
  it.each(cases)('visibility: %s', (_name, status, outs, expected) => {
    const outcomes = outs.map(([id, st, over]) => outcome(id as string, st as string, over as Record<string, unknown>))
    expect(canResume({ status: status as 'running' }, outcomes as never, NOW)).toBe(expected)
  })
  it('the stale limit is the 15 minutes of Fleet', () => {
    expect(STALE_RUNNING_MINUTES).toBe(15)
  })

  it('posts to /:id/resume and shows the result', async () => {
    setup({ detail: { rollout: rollout({ status: 'halted' }), outcomes: [outcome('ten-1', 'failed')] } })
    clientMock.post.mockResolvedValue({ rollout: rollout({ status: 'completed' }), outcomes: [outcome('ten-1', 'succeeded')] })
    renderPage('/admin/module-rollouts?rollout=r1')
    fireEvent.click(await screen.findByTestId('module-rollouts-resume'))
    await waitFor(() => expect(clientMock.post).toHaveBeenCalledWith(`${BASE}/r1/resume`, {}))
    await waitFor(() => expect(screen.queryByTestId('module-rollouts-resume')).toBeNull())
    expect(screen.getByTestId('module-rollout-status-completed')).toBeInTheDocument()
  })
  it('409 renders the superseded text', async () => {
    setup({ detail: { rollout: rollout({ status: 'halted' }), outcomes: [outcome('ten-1', 'failed')] } })
    clientMock.post.mockRejectedValue({ status: 409, message: 'x', code: 'x' })
    renderPage('/admin/module-rollouts?rollout=r1')
    fireEvent.click(await screen.findByTestId('module-rollouts-resume'))
    expect(await screen.findByTestId('module-rollouts-resume-error')).toHaveTextContent('no longer the running build')
  })
})

describe('T7 catalogs', () => {
  it('has the same id set in en, ru and kk, no empty text', () => {
    const ids = Object.keys(moduleRolloutsMessages.en).sort()
    expect(Object.keys(moduleRolloutsMessages.ru).sort()).toEqual(ids)
    expect(Object.keys(moduleRolloutsMessages.kk).sort()).toEqual(ids)
    for (const l of ['en', 'ru', 'kk'] as const) for (const id of ids) expect(moduleRolloutsMessages[l][id]).toBeTruthy()
  })
  it('keys sit under the module-rollouts root', () => {
    expect(queryKeys.moduleRollouts.status('t1', 'r1').slice(0, 3)).toEqual(['tenant', 't1', 'module-rollouts'])
  })
})
