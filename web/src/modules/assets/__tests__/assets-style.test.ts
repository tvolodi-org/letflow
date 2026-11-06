/** A3 — T-1333 / C13: design-system grep over the module sources: no inline colour or spacing, no hex colour, no plain
 *  date input, no fixed pixel width. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'

const DIR = path.resolve(__dirname, '..')
const files = readdirSync(DIR).filter((f) => /\.(ts|tsx)$/.test(f))

describe('A3 tokens only', () => {
  it('finds the sources', () => {
    expect(files).toEqual(expect.arrayContaining(['AssetCardsPage.tsx', 'AssetCardForm.tsx', 'AssetCardFacts.tsx']))
  })
  for (const f of files) {
    it(`${f} has no inline style, hex colour, plain date input or px width`, () => {
      const src = readFileSync(path.join(DIR, f), 'utf-8')
      expect(src).not.toMatch(/style=\{/)
      expect(src).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
      expect(src).not.toMatch(/type=["']date["']/)
      expect(src).not.toMatch(/\bwidth:\s*\d+px/)
    })
  }
})
