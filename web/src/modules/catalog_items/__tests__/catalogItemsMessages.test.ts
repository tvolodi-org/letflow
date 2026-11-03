/** I1 (AC5) — GH 3605 / REQ-673: the catalog has the same ids in en/ru/kk. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { CATALOG_ITEMS_UI_LOCALES, catalogItemsMessages, resolveUiLocale } from '../catalogItemsMessages'
import { LOT_REASONS } from '../catalogItemsModel'

const DIR = path.resolve(__dirname, '..')

describe('I1 catalogItemsMessages', () => {
  it('has identical id sets in en, ru and kk, and ru/kk differ from en for every id', () => {
    const [first, ...rest] = CATALOG_ITEMS_UI_LOCALES.map((l) => Object.keys(catalogItemsMessages[l]).sort())
    for (const other of rest) expect(other).toEqual(first)
    const same = new Set(['catalog_items.common.dash'])
    for (const id of first) {
      if (same.has(id)) continue
      for (const l of ['ru', 'kk'] as const) expect(catalogItemsMessages[l][id], `${l} ${id}`).not.toBe(catalogItemsMessages.en[id])
    }
  })

  it('has a message per reason and for every error key in every locale', () => {
    for (const locale of CATALOG_ITEMS_UI_LOCALES) {
      const m = catalogItemsMessages[locale]
      for (const r of LOT_REASONS) expect(m[`catalog_items.error.${r}`], r).toBeTruthy()
      for (const id of ['forbidden', 'notFound', 'generic', 'unknown', 'expiryInvalid', 'lotCodeTaken']) {
        expect(m[`catalog_items.error.${id}`], id).toBeTruthy()
      }
    }
  })

  it('every literal id used in the sources exists', () => {
    const files = readdirSync(DIR).filter((f) => /\.(ts|tsx)$/.test(f) && f !== 'catalogItemsMessages.ts')
    const used = new Set<string>()
    for (const f of files) {
      for (const m of readFileSync(path.join(DIR, f), 'utf-8').matchAll(/'(catalog_items\.[A-Za-z_]+\.[A-Za-z_]+)'/g)) used.add(m[1])
    }
    expect(used.size).toBeGreaterThan(10)
    for (const id of used) expect(catalogItemsMessages.en[id], id).toBeTruthy()
  })

  it('resolves the locale from the language list', () => {
    expect(resolveUiLocale(['ru-RU'])).toBe('ru')
    expect(resolveUiLocale(['de', 'kk'])).toBe('kk')
    expect(resolveUiLocale(['de'])).toBe('en')
  })
})
