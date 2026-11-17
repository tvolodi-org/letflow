// @vitest-environment jsdom
/** P3-O1 — T-2042: the object URL is made for a blob, revoked when the blob changes and on unmount. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useObjectUrl } from './useObjectUrl'

afterEach(() => vi.restoreAllMocks())

describe('P3-O1 useObjectUrl', () => {
  it('creates, revokes on replacement and on unmount, and is null without a blob', () => {
    let n = 0
    const create = vi.fn(() => `blob:${++n}`)
    const revoke = vi.fn()
    vi.stubGlobal('URL', Object.assign(URL, { createObjectURL: create, revokeObjectURL: revoke }))
    const a = new Blob(['a'])
    const b = new Blob(['b'])
    const { result, rerender, unmount } = renderHook(({ blob }) => useObjectUrl(blob), { initialProps: { blob: undefined as Blob | undefined } })
    expect(result.current).toBeNull()
    rerender({ blob: a })
    expect(result.current).toBe('blob:1')
    rerender({ blob: b })
    expect(revoke).toHaveBeenCalledWith('blob:1')
    expect(result.current).toBe('blob:2')
    unmount()
    expect(revoke).toHaveBeenCalledWith('blob:2')
  })
})
