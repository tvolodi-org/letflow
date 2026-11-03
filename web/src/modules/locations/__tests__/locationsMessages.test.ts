/** I1 — GH 3607 / REQ-671: the catalog has the same ids in en/ru/kk and covers every id used by the screens. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { LOCATIONS_UI_LOCALES, locationsMessages, resolveUiLocale } from '../locationsMessages'
import { LOCATION_REASONS, LOCATION_TYPES } from '../locationsModel'

const DIR = path.resolve(__dirname, '..')

describe('I1 locationsMessages', () => {
  it('has identical id sets in en, ru and kk, and ru/kk differ from en for every id', () => {
    const [first, ...rest] = LOCATIONS_UI_LOCALES.map((l) => Object.keys(locationsMessages[l]).sort())
    for (const other of rest) expect(other).toEqual(first)
    // identical by nature in every language: the dash, and the loan word for quarantine
    const same = new Set(['locations.common.dash', 'locations.common.code', 'locations.type.quarantine'])
    for (const id of first) {
      if (same.has(id)) continue
      for (const l of ['ru', 'kk'] as const) {
        expect(locationsMessages[l][id], `${l} ${id}`).not.toBe(locationsMessages.en[id])
      }
    }
  })

  it('has a message per reason, per location type and the generic ones, in every locale', () => {
    for (const locale of LOCATIONS_UI_LOCALES) {
      for (const reason of LOCATION_REASONS) expect(locationsMessages[locale][`locations.error.${reason}`], reason).toBeTruthy()
      for (const type of LOCATION_TYPES) expect(locationsMessages[locale][`locations.type.${type}`], type).toBeTruthy()
      for (const id of ['forbidden', 'notFound', 'link_not_found', 'generic', 'unknown']) {
        expect(locationsMessages[locale][`locations.error.${id}`], id).toBeTruthy()
      }
    }
  })

  it('every literal id used in the sources exists', () => {
    const files = readdirSync(DIR).filter((f) => /\.(ts|tsx)$/.test(f) && f !== 'locationsMessages.ts')
    const used = new Set<string>()
    for (const f of files) {
      for (const m of readFileSync(path.join(DIR, f), 'utf-8').matchAll(/'(locations\.[A-Za-z_]+\.[A-Za-z_]+)'/g)) used.add(m[1])
    }
    expect(used.size).toBeGreaterThan(20)
    for (const id of used) expect(locationsMessages.en[id], id).toBeTruthy()
  })

  it('resolves the locale from the language list', () => {
    expect(resolveUiLocale(['ru-RU'])).toBe('ru')
    expect(resolveUiLocale(['de', 'kk'])).toBe('kk')
    expect(resolveUiLocale(['de'])).toBe('en')
  })
})
