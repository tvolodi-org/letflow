/** I2 (AC5) — GH 3605 / REQ-673: no bare English text node in any .tsx of the catalog_items module. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'

const DIR = path.resolve(__dirname, '..')
const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g

describe('I2 no hard-coded JSX text', () => {
  const files = readdirSync(DIR).filter((f) => f.endsWith('.tsx'))
  it('finds the screen', () => {
    expect(files).toEqual(expect.arrayContaining(['LotsPage.tsx']))
  })
  for (const f of files) {
    it(`${f} has no bare JSX text node`, () => {
      expect(readFileSync(path.join(DIR, f), 'utf-8').match(JSX_TEXT_NODE) ?? []).toEqual([])
    })
  }
})
