import { beforeEach, describe, expect, it, vi } from 'vitest'
import { entitiesApi } from '@/api/entities'
import { MAX_PAGES, PAGE_SIZE, anyTruncated, fetchAllRecords } from '../entities/fetchAllRecords'

vi.mock('@/api/entities', () => ({ entitiesApi: { queryRecords: vi.fn() } }))

const query = vi.mocked(entitiesApi.queryRecords)
const row = (i: number) => ({ record_id: `r${i}` }) as never

beforeEach(() => query.mockReset())

describe('fetchAllRecords', () => {
  it('returns every row and no flag when the server runs out before the cap', async () => {
    query
      .mockResolvedValueOnce({ items: [row(1), row(2)], next_cursor: 'c1' } as never)
      .mockResolvedValueOnce({ items: [row(3)], next_cursor: null } as never)
    const rows = await fetchAllRecords('t', [])
    expect(rows).toHaveLength(3)
    expect(rows.truncated).toBeUndefined()
    expect(query).toHaveBeenCalledTimes(2)
    expect(query.mock.calls[1]?.[1]).toMatchObject({ cursor: 'c1', page_size: PAGE_SIZE })
  })

  it('stops at the page cap and marks the list truncated when the server still has more', async () => {
    let n = 0
    query.mockImplementation(async () => ({ items: [row(1)], next_cursor: `more${(n += 1)}` }) as never)
    const rows = await fetchAllRecords('t', [])
    expect(query).toHaveBeenCalledTimes(MAX_PAGES)
    expect(rows).toHaveLength(MAX_PAGES)
    expect(rows.truncated).toBe(true)
    expect(anyTruncated([{ data: rows }, { data: undefined }])).toBe(true)
  })

  it('is not truncated when the last allowed page is also the last page', async () => {
    query.mockResolvedValue({ items: [row(1)], next_cursor: null } as never)
    const rows = await fetchAllRecords('t', [], 'code', 'asc', 1)
    expect(rows.truncated).toBeUndefined()
    expect(anyTruncated([{ data: rows }])).toBe(false)
  })

  it('sends no sort when sortField is null and sorts by code by default (P5)', async () => {
    query.mockResolvedValue({ items: [row(1)], next_cursor: null } as never)
    await fetchAllRecords('t', [], null)
    expect(query.mock.calls[0]?.[1]).not.toHaveProperty('sort')
    await fetchAllRecords('t', [])
    expect(query.mock.calls[1]?.[1]).toMatchObject({ sort: [{ field: 'code', dir: 'asc' }] })
  })
})
