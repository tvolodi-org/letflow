// @vitest-environment jsdom
/** T-1563 useValidateDraft: V1 debounce (one request for a burst), V2 an answer for an older draft is dropped,
 *  V3 a network failure leaves a "failed" phase (Save stays enabled in the pane). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import type { DefinitionGraph } from '@/types/api'
import { useValidateDraft } from '../useValidateDraft'

vi.mock('@/api/definitions', () => ({ definitionsApi: { validate: vi.fn() } }))
import { definitionsApi } from '@/api/definitions'

const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>
const g = (n: number): DefinitionGraph => ({ nodes: [{ id: `n${n}`, node_type: 'START', label: null, attributes: null }], edges: [] })

beforeEach(() => vi.useFakeTimers())
afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.clearAllMocks()
})

describe('useValidateDraft', () => {
  it('V1 debounces a burst of edits into one request carrying the latest graph', async () => {
    vi.mocked(definitionsApi.validate).mockResolvedValue({ status: 'valid', definition_id: 'd', findings: [] })
    const { rerender, result } = renderHook(({ graph }) => useValidateDraft('d', graph, true, 700), { wrapper, initialProps: { graph: g(1) } })
    rerender({ graph: g(2) })
    rerender({ graph: g(3) })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(699)
    })
    expect(definitionsApi.validate).not.toHaveBeenCalled()
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2)
    })
    expect(definitionsApi.validate).toHaveBeenCalledTimes(1)
    expect(vi.mocked(definitionsApi.validate).mock.calls[0]).toEqual(['d', g(3)])
    expect(result.current.check.phase).toBe('valid')
  })

  it('V2 an answer about an older graph is dropped and the newer graph is checked', async () => {
    let release: (v: unknown) => void = () => undefined
    vi.mocked(definitionsApi.validate)
      .mockImplementationOnce(() => new Promise((r) => (release = r)) as never)
      .mockResolvedValueOnce({ status: 'valid', definition_id: 'd', findings: [] })
    const { rerender, result } = renderHook(({ graph }) => useValidateDraft('d', graph, true, 100), { wrapper, initialProps: { graph: g(1) } })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(101)
    })
    expect(result.current.check.phase).toBe('checking')
    rerender({ graph: g(2) })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(101) // second request waits: one in flight
    })
    expect(definitionsApi.validate).toHaveBeenCalledTimes(1)
    await act(async () => {
      release({ status: 'invalid' })
      await vi.advanceTimersByTimeAsync(1)
    })
    expect(definitionsApi.validate).toHaveBeenCalledTimes(2)
    expect(vi.mocked(definitionsApi.validate).mock.calls[1][1]).toEqual(g(2))
    expect(result.current.check.phase).toBe('valid')
  })

  it('V3 a 422 gives the violations; a network failure gives "failed"', async () => {
    vi.mocked(definitionsApi.validate).mockRejectedValueOnce({ status: 422, details: [{ code: 'missing_role', message: 'm' }] })
    const { rerender, result } = renderHook(({ graph }) => useValidateDraft('d', graph, true, 50), { wrapper, initialProps: { graph: g(1) } })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60)
    })
    expect(result.current.check).toEqual({ phase: 'invalid', violations: [{ code: 'missing_role', message: 'm' }] })
    vi.mocked(definitionsApi.validate).mockRejectedValueOnce(new TypeError('network'))
    rerender({ graph: g(2) })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60)
    })
    expect(result.current.check.phase).toBe('failed')
  })

  it('does nothing while disabled (the Editor has unsaved changes)', async () => {
    renderHook(() => useValidateDraft('d', g(1), false, 10), { wrapper })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(100)
    })
    expect(definitionsApi.validate).not.toHaveBeenCalled()
  })
})
