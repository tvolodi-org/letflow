// @vitest-environment jsdom
/** K1 (AC3) — GH 3605 / REQ-673: idempotency key reuse on retry, new key for an edited body. */
import { describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'
import { act, renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useCatalogItemsWrite } from '../useCatalogItemsWrite'

vi.mock('@/auth/AuthContext', () => ({ useAuth: () => ({ session: { token: 't', tenant_id: 'tid' } }) }))

function setup(call: (b: { n: string }, key: string) => Promise<unknown>) {
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>
  )
  return renderHook(() => useCatalogItemsWrite(call), { wrapper })
}

describe('K1 useCatalogItemsWrite', () => {
  it('reuses the key for the same body after a failure, changes it for an edited body and after success', async () => {
    const keys: string[] = []
    const call = vi.fn(async (_b: { n: string }, key: string) => {
      keys.push(key)
      if (keys.length === 1) throw { status: 500 }
      return {}
    })
    const { result } = setup(call)
    await act(async () => void (await result.current.submit({ n: 'a' })))
    expect(result.current.error).toEqual({ status: 500 })
    await act(async () => void (await result.current.submit({ n: 'a' })))
    expect(keys[1]).toBe(keys[0])
    expect(result.current.error).toBeNull()
    await act(async () => void (await result.current.submit({ n: 'a' })))
    expect(keys[2]).not.toBe(keys[0])

    const failing = vi.fn(async (_b: { n: string }, key: string) => {
      keys.push(key)
      throw { status: 422, details: { reason: 'record_payload_invalid' } }
    })
    const second = setup(failing)
    await act(async () => void (await second.result.current.submit({ n: 'x' })))
    await act(async () => void (await second.result.current.submit({ n: 'y' })))
    expect(keys.at(-1)).not.toBe(keys.at(-2))
  })
})
