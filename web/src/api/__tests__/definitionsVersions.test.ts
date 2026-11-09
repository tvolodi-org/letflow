// @vitest-environment jsdom
/** T-1588: A1 getVersions keeps exact name matches only and follows the cursor (the server filter is a substring
 *  match); A2 it stops after MAX_VERSION_PAGES and reports the cursor that is left. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { client } from '../client'
import { definitionsApi, MAX_VERSION_PAGES } from '../definitions'

const row = (id: string, name: string) => ({ id, name, version: '1' })

afterEach(() => vi.restoreAllMocks())

describe('definitionsApi.getVersions', () => {
  it('A1 returns only exact name matches across two pages', async () => {
    const get = vi
      .spyOn(client, 'get')
      .mockResolvedValueOnce({ items: [row('1', 'purchase-approval'), row('2', 'approval')], next_cursor: 'c1' })
      .mockResolvedValueOnce({ items: [row('3', 'approval_2'), row('4', 'approval')], next_cursor: null })
    const res = await definitionsApi.getVersions('approval')
    expect(res.items.map((d) => d.id)).toEqual(['2', '4'])
    expect(res.next_cursor).toBeNull()
    expect(get).toHaveBeenCalledTimes(2)
    expect(get.mock.calls[0][1]).toMatchObject({ name: 'approval', page_size: 200 })
    expect(get.mock.calls[1][1]).toMatchObject({ cursor: 'c1' })
  })

  it('A2 stops at the page cap and returns the cursor left over', async () => {
    const get = vi.spyOn(client, 'get').mockResolvedValue({ items: [row('x', 'approval')], next_cursor: 'more' })
    const res = await definitionsApi.getVersions('approval')
    expect(get).toHaveBeenCalledTimes(MAX_VERSION_PAGES)
    expect(res.items).toHaveLength(MAX_VERSION_PAGES)
    expect(res.next_cursor).toBe('more')
  })
})
