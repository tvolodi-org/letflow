// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { registerRenewer, renewSession } from '../sessionRenewal'

let off: (() => void) | null = null
afterEach(() => {
  off?.()
  off = null
})

describe('sessionRenewal', () => {
  it('SR-01: concurrent renewSession() calls run the renewer once', async () => {
    let resolve!: (v: { kind: 'ok'; token: string }) => void
    const renewer = vi.fn(() => new Promise<{ kind: 'ok'; token: string }>(r => (resolve = r)))
    off = registerRenewer(renewer)
    const a = renewSession()
    const b = renewSession()
    resolve({ kind: 'ok', token: 't' })
    expect(await a).toEqual({ kind: 'ok', token: 't' })
    expect(await b).toEqual({ kind: 'ok', token: 't' })
    expect(renewer).toHaveBeenCalledTimes(1)
    // the flight is over: the next call starts a new one
    const c = renewSession()
    resolve({ kind: 'ok', token: 'u' })
    await c
    expect(renewer).toHaveBeenCalledTimes(2)
  })

  it('SR-01b: no renewer, or a renewer that throws, is terminal', async () => {
    expect(await renewSession()).toEqual({ kind: 'terminal' })
    off = registerRenewer(async () => {
      throw new Error('x')
    })
    expect(await renewSession()).toEqual({ kind: 'terminal' })
  })
})
