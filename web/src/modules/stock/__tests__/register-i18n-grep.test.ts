/** I2 — GH 3767 / REQ-724: no bare English text node in any .tsx of the stock module (the REQ-338 grep). */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(__dirname, '..')
const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g

const files = [ROOT, path.join(ROOT, 'register')].flatMap((dir) =>
  readdirSync(dir)
    .filter((f) => f.endsWith('.tsx'))
    .map((f) => path.join(dir, f)),
)

describe('I2 no hard-coded JSX text', () => {
  it('finds the screens', () => {
    expect(files.map((f) => path.basename(f))).toEqual(expect.arrayContaining(['BalancesPage.tsx', 'MovementsPage.tsx']))
  })
  for (const f of files) {
    it(`${path.relative(ROOT, f)} has no bare JSX text node`, () => {
      expect(readFileSync(f, 'utf-8').match(JSX_TEXT_NODE) ?? []).toEqual([])
    })
  }
})
