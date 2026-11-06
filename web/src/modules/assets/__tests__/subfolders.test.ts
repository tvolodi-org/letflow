/** G1 — T-1334 / C14: the scans of the module read only the top level of `assets/`; these read the new folders
 *  `documents/` and `register/` too (bare JSX text, tokens only, every literal message id exists). */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { assetsMessages } from '../assetsMessages'

const ROOT = path.resolve(__dirname, '..')
const FOLDERS = ['documents', 'register']
const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g
const files = FOLDERS.flatMap((d) => readdirSync(path.join(ROOT, d)).filter((f) => /\.(ts|tsx)$/.test(f)).map((f) => path.join(d, f)))
const read = (f: string) => readFileSync(path.join(ROOT, f), 'utf-8')

describe('G1 sources of documents/ and register/', () => {
  it('finds the screens of both folders', () => {
    expect(files).toEqual(expect.arrayContaining([
      path.join('documents', 'DocumentView.tsx'), path.join('documents', 'DocumentActions.tsx'), path.join('documents', 'DocumentList.tsx'),
      path.join('register', 'BalancesPage.tsx'), path.join('register', 'MovementsPage.tsx'), path.join('register', 'BalanceHistoryPanel.tsx'),
    ]))
  })
  for (const f of files) {
    it(`${f}: no bare JSX text, no inline style, hex colour, plain date input or px width`, () => {
      const src = read(f)
      if (f.endsWith('.tsx')) expect(src.match(JSX_TEXT_NODE) ?? []).toEqual([])
      expect(src).not.toMatch(/style=\{/)
      expect(src).not.toMatch(/#[0-9a-fA-F]{3,8}\b/)
      expect(src).not.toMatch(/type=["']date["']/)
      expect(src).not.toMatch(/\bwidth:\s*\d+px/)
    })
  }
  it('every literal message id used by these sources exists in the catalog', () => {
    const used = new Set<string>()
    for (const f of files.filter((x) => !/Messages\.ts$/.test(x))) {
      for (const m of read(f).matchAll(/'(assets\.[A-Za-z]+\.[A-Za-z_.]+)'/g)) used.add(m[1])
    }
    expect(used.size).toBeGreaterThan(100)
    // a prefix such as 'assets.doc.state' (the word is built as `${prefix}.${value}`) is not an id itself
    const isPrefix = (id: string) => Object.keys(assetsMessages.en).some((k) => k.startsWith(`${id}.`))
    for (const id of used) if (!isPrefix(id)) expect(assetsMessages.en[id], id).toBeTruthy()
  })
  it('no request sends a tenant identifier: the word tenant appears only in cache keys', () => {
    for (const f of files.filter((x) => /\.api\.ts$/.test(x))) expect(read(f).replace(/\/\*\*[\s\S]*?\*\//g, '')).not.toMatch(/tenant/i)
  })
})
