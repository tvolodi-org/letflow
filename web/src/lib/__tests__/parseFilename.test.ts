/** W5 — T-1915: `parseFilename` moved from the stock counts model to `@/lib`; the case moved with it. */
import { describe, expect, it } from 'vitest'
import { parseFilename } from '../parseFilename'

describe('parseFilename', () => {
  it('reads filename, filename* and falls back', () => {
    expect(parseFilename('attachment; filename="a b.xlsx"', 'f.xlsx')).toBe('a b.xlsx')
    expect(parseFilename("attachment; filename*=UTF-8''%D0%B0.xlsx", 'f.xlsx')).toBe('а.xlsx')
    expect(parseFilename(null, 'f.xlsx')).toBe('f.xlsx')
    expect(parseFilename('attachment', 'f.xlsx')).toBe('f.xlsx')
  })
})
