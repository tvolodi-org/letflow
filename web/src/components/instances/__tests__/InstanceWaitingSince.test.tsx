// @vitest-environment jsdom
/** T-1705 (REQ-812) the "Waiting since" block (C-W1, C-W4, C-W5, C-W6 states, C-W8, C-W9). The data hook is mocked with
 *  its real shape, so no polling exists and the block's own timer is tested alone; the real hook (paging, requests, retry)
 *  is covered by InstanceWaitingSince.hook.test.tsx. Times are pinned to UTC. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import type { NodeEnteredItem } from '@/types/api'
expect.extend(jestDomMatchers)

const hook = vi.hoisted(() => ({ fn: vi.fn() }))
vi.mock('@/hooks/useInstances', () => ({ useInstanceNodeEntries: (...a: unknown[]) => hook.fn(...a) }))

import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { processDiagramMessages } from '@/i18n/processDiagramMessages'
import { InstanceWaitingSince } from '../InstanceWaitingSince'

const node = (id: string, node_type: string, label: string | null = null) => ({ id, node_type, label, attributes: null })
const GRAPH = {
  nodes: [node('start', 'START'), node('split', 'PARALLEL_GATEWAY'), node('x', 'HUMAN_TASK', 'Check stock'), node('y', 'HUMAN_TASK', 'Approve budget'), node('end', 'END')],
  edges: [
    { id: 'e1', source: 'start', target: 'split' },
    { id: 'e2', source: 'split', target: 'x' },
    { id: 'e3', source: 'split', target: 'y' },
  ],
}
const entry = (seq: number, node_id: string, node_type: string, via: string | null, at: string): NodeEnteredItem => ({
  event_id: `ev-${seq}`,
  sequence_number: seq,
  created_at: at,
  payload: { node_id, node_type, via_edge_id: via },
})
const FULL = [
  entry(1, 'start', 'START', null, '2026-11-09T10:00:00Z'),
  entry(2, 'split', 'PARALLEL_GATEWAY', 'e1', '2026-11-09T10:00:00Z'),
  entry(3, 'x', 'HUMAN_TASK', 'e2', '2026-11-09T10:00:00Z'),
  entry(4, 'y', 'HUMAN_TASK', 'e3', '2026-11-09T10:30:00Z'),
]
const NOW = '2026-11-09T12:05:30Z'

function data(over: Record<string, unknown> = {}) {
  return { entries: FULL, complete: true, truncated: false, isLoading: false, isError: false, retry: vi.fn(), ...over }
}
function show(status = 'ACTIVE') {
  return render(<InstanceWaitingSince instanceId="i1" status={status} graph={GRAPH as never} timeZone="UTC" />)
}

beforeEach(() => {
  act(() => useUiLocaleStore.getState().setLocale('en'))
  hook.fn.mockReturnValue(data())
  vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval', 'Date'] })
  vi.setSystemTime(new Date(NOW))
})
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.clearAllMocks()
})

describe('T-1705 InstanceWaitingSince', () => {
  it.each(['COMPLETED', 'CANCELLED', 'ERROR'])('C-W1-%s no block and the data hook is not even called', (status) => {
    show(status)
    expect(screen.queryByTestId('waiting-since')).toBeNull()
    expect(hook.fn).not.toHaveBeenCalled()
  })

  it('C-W1-ACTIVE the block is shown', () => {
    show('ACTIVE')
    expect(screen.getByTestId('waiting-since')).toBeInTheDocument()
    expect(hook.fn).toHaveBeenCalledWith('i1', { status: 'ACTIVE' })
  })

  it('C-W4-row name, since time and elapsed; oldest first', () => {
    show()
    const items = within(screen.getByRole('list')).getAllByRole('listitem')
    expect(items).toHaveLength(2)
    expect(items[0]).toHaveTextContent('Check stock')
    expect(items[0]).toHaveTextContent('Since 11/9/2026, 10:00:00 AM')
    expect(items[0]).toHaveTextContent('waiting 2 h 5 min')
    expect(items[1]).toHaveTextContent('Approve budget')
    expect(items[1]).toHaveTextContent('waiting 1 h 35 min')
  })

  it('C-W4-row a node without a label shows its type name; a node not in the graph says so with its id', () => {
    hook.fn.mockReturnValue(
      data({ entries: [entry(1, 'start', 'START', null, '2026-11-09T12:05:00Z'), entry(2, 'gone', 'HUMAN_TASK', null, '2026-11-09T12:05:10Z')] }),
    )
    show()
    const items = screen.getAllByRole('listitem')
    expect(items[1]).toHaveTextContent('gone (not in this definition)')
    expect(items[1]).toHaveTextContent('waiting under 1 min')
  })

  it('C-W5-tick elapsed text moves by a minute on the 60 s timer; the data hook only re-renders', () => {
    show()
    const first = screen.getByTestId('waiting-row-x')
    expect(first).toHaveTextContent('waiting 2 h 5 min')
    act(() => {
      vi.advanceTimersByTime(60_000)
    })
    expect(screen.getByTestId('waiting-row-x')).toHaveTextContent('waiting 2 h 6 min')
    expect(screen.getByTestId('waiting-row-x')).toHaveTextContent('Since 11/9/2026, 10:00:00 AM')
  })

  it('C-W6-loading skeleton while the first page is loading; no rows', () => {
    hook.fn.mockReturnValue(data({ entries: [], complete: false, isLoading: true }))
    show()
    expect(screen.getByTestId('waiting-since').querySelector('[aria-busy="true"]')).not.toBeNull()
    expect(screen.queryByRole('list')).toBeNull()
  })

  it('C-W6-loading-paging pages still missing (isLoading false, complete false): skeleton, no rows, no since', () => {
    hook.fn.mockReturnValue(data({ complete: false, isLoading: false }))
    show()
    expect(screen.getByTestId('waiting-since').querySelector('[aria-busy="true"]')).not.toBeNull()
    expect(screen.queryByRole('list')).toBeNull()
    expect(screen.queryByText(/Since/)).toBeNull()
  })

  it('C-W6-error banner and Retry calls the hook retry; rows hidden even if some entries loaded', () => {
    const retry = vi.fn()
    hook.fn.mockReturnValue(data({ isError: true, complete: false, retry }))
    show()
    expect(screen.getByText(/could not be loaded/)).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }))
    expect(retry).toHaveBeenCalledTimes(1)
  })

  it('C-W6-truncated text and no rows', () => {
    hook.fn.mockReturnValue(data({ truncated: true, complete: false }))
    show()
    expect(screen.getByText(/too many recorded steps/)).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
  })

  it('C-W6-none nothing recorded: text, no rows', () => {
    hook.fn.mockReturnValue(data({ entries: [] }))
    show()
    expect(screen.getByText(/No steps were recorded/)).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
  })

  it('C-W6-partial rows and the not-recorded-before note with the first recorded time', () => {
    hook.fn.mockReturnValue(data({ entries: FULL.slice(2) }))
    show()
    expect(screen.getByText(/Steps before 11\/9\/2026, 10:00:00 AM were not recorded/)).toBeInTheDocument()
    expect(screen.getAllByRole('listitem')).toHaveLength(2)
  })

  it('C-W6-empty recorded but nothing waits', () => {
    hook.fn.mockReturnValue(
      data({ entries: [entry(1, 'start', 'START', null, '2026-11-09T10:00:00Z'), entry(2, 'end', 'END', 'e1', '2026-11-09T10:00:01Z')] }),
    )
    show()
    expect(screen.getByText('No recorded step is waiting.')).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
  })

  it.each(['ru', 'kk'] as const)('C-W8-%s the block speaks the language; every waiting.* id exists in en, ru and kk', (lang) => {
    act(() => useUiLocaleStore.getState().setLocale(lang))
    show()
    const msg = processDiagramMessages[lang]
    expect(screen.getByRole('heading', { level: 4 })).toHaveTextContent(msg['processDiagram.waiting.title']!)
    expect(screen.getByTestId('waiting-row-x')).not.toHaveTextContent(/Since|waiting/)
    const ids = (l: 'en' | 'ru' | 'kk') => Object.keys(processDiagramMessages[l]).filter((k) => k.startsWith('processDiagram.waiting.')).sort()
    expect(ids('ru')).toEqual(ids('en'))
    expect(ids('kk')).toEqual(ids('en'))
    expect(ids('en')).toHaveLength(11)
  })

  it('C-W9-a11y a labelled region with a heading and a list; time[datetime] in ISO; elapsed is not hidden nor live', () => {
    show()
    const region = screen.getByRole('region', { name: 'Waiting since' })
    expect(within(region).getByRole('heading', { level: 4 })).toBeInTheDocument()
    expect(within(region).getByRole('list')).toBeInTheDocument()
    const t = region.querySelector('time')!
    expect(t.getAttribute('datetime')).toBe('2026-11-09T10:00:00.000Z')
    const elapsed = region.querySelector('.lf-waiting__elapsed')!
    expect(elapsed.closest('[aria-hidden="true"]')).toBeNull()
    expect(elapsed.closest('[aria-live]')).toBeNull()
  })
})
