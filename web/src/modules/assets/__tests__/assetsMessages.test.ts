/** A1, A2 — T-1333 / C13: the catalog has the same ids in en/ru/kk and covers every id used by the sources. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { ASSETS_UI_LOCALES, assetsMessages, resolveUiLocale } from '../assetsMessages'
import { ASSET_KINDS, ASSET_REASONS } from '../assetsModel'

const DIR = path.resolve(__dirname, '..')

describe('A1 assetsMessages', () => {
  it('has identical id sets in en, ru and kk, and ru/kk differ from en for every id', () => {
    const [first, ...rest] = ASSETS_UI_LOCALES.map((l) => Object.keys(assetsMessages[l]).sort())
    for (const other of rest) expect(other).toEqual(first)
    const same = new Set(['assets.common.dash', 'assets.cardActions.select.blocked'])
    for (const id of first) {
      if (same.has(id)) continue
      for (const l of ['ru', 'kk'] as const) expect(assetsMessages[l][id], `${l} ${id}`).not.toBe(assetsMessages.en[id])
    }
  })

  it('has a message per kind, per reason and the generic ones, in every locale', () => {
    for (const locale of ASSETS_UI_LOCALES) {
      for (const kind of ASSET_KINDS) expect(assetsMessages[locale][`assets.kind.${kind}`], kind).toBeTruthy()
      for (const reason of ASSET_REASONS) expect(assetsMessages[locale][`assets.error.${reason}`], reason).toBeTruthy()
      for (const id of ['forbidden', 'notFound', 'generic', 'unknown', 'decimalFormat', 'decimalSize']) {
        expect(assetsMessages[locale][`assets.error.${id}`], id).toBeTruthy()
      }
    }
  })

  it('resolves the locale from the language list', () => {
    expect(resolveUiLocale(['ru-RU'])).toBe('ru')
    expect(resolveUiLocale(['de', 'kk'])).toBe('kk')
    expect(resolveUiLocale(['de'])).toBe('en')
  })
})

describe('A2 ids used in the sources', () => {
  it('every literal id exists in the catalog', () => {
    const files = readdirSync(DIR).filter((f) => /\.(ts|tsx)$/.test(f) && f !== 'assetsMessages.ts')
    const used = new Set<string>()
    for (const f of files) {
      for (const m of readFileSync(path.join(DIR, f), 'utf-8').matchAll(/'(assets\.[A-Za-z_]+\.[A-Za-z_]+)'/g)) used.add(m[1])
    }
    expect(used.size).toBeGreaterThan(30)
    for (const id of used) expect(assetsMessages.en[id], id).toBeTruthy()
  })
})
