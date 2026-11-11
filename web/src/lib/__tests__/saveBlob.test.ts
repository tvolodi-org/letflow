// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { saveBlob } from '../saveBlob'

describe('saveBlob', () => {
  afterEach(() => vi.restoreAllMocks())

  it('creates the anchor, clicks it, removes it and revokes the URL', () => {
    const create = vi.fn(() => 'blob:x')
    const revoke = vi.fn()
    Object.assign(URL, { createObjectURL: create, revokeObjectURL: revoke })
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {
      expect(document.body.querySelectorAll('a').length).toBe(1)
    })
    const blob = new Blob(['a'])
    saveBlob(blob, 'f.xlsx')
    expect(create).toHaveBeenCalledWith(blob)
    expect(click).toHaveBeenCalledTimes(1)
    const a = click.mock.contexts[0] as HTMLAnchorElement
    expect(a.download).toBe('f.xlsx')
    expect(a.getAttribute('href')).toBe('blob:x')
    expect(document.body.contains(a)).toBe(false)
    expect(revoke).toHaveBeenCalledWith('blob:x')
  })
})
