/** I1 — GH 3609 / REQ-669: the catalog has the same ids in en/ru/kk and covers every id used by the screens. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { ORG_UI_LOCALES, orgMessages, resolveUiLocale } from '../orgMessages'
import { ORG_REASONS } from '../orgModel'

const DIR = path.resolve(__dirname, '..')

describe('I1 orgMessages', () => {
  it('has identical id sets in en, ru and kk, and ru/kk differ from en', () => {
    const [first, ...rest] = ORG_UI_LOCALES.map((l) => Object.keys(orgMessages[l]).sort())
    for (const other of rest) expect(other).toEqual(first)
    expect(orgMessages.ru['org.units.title']).not.toBe(orgMessages.en['org.units.title'])
    expect(orgMessages.kk['org.units.title']).not.toBe(orgMessages.en['org.units.title'])
    for (const id of ['org.positions.title', 'org.employees.title', 'org.employees.transfer']) {
      expect(orgMessages.ru[id], id).not.toBe(orgMessages.en[id])
      expect(orgMessages.kk[id], id).not.toBe(orgMessages.en[id])
    }
  })

  it('has a message per reason, the generic ones, in every locale', () => {
    for (const locale of ORG_UI_LOCALES) {
      for (const reason of ORG_REASONS) expect(orgMessages[locale][`org.error.${reason}`], reason).toBeTruthy()
      for (const id of ['forbidden', 'notFound', 'generic', 'unknown', 'binFormat']) {
        expect(orgMessages[locale][`org.error.${id}`], id).toBeTruthy()
      }
    }
  })

  it('every literal id used in the sources exists', () => {
    const files = readdirSync(DIR).filter((f) => /\.(ts|tsx)$/.test(f) && f !== 'orgMessages.ts')
    const used = new Set<string>()
    for (const f of files) {
      for (const m of readFileSync(path.join(DIR, f), 'utf-8').matchAll(/'(org\.[A-Za-z_]+\.[A-Za-z_]+)'/g)) used.add(m[1])
    }
    expect(used.size).toBeGreaterThan(20)
    for (const id of used) expect(orgMessages.en[id], id).toBeTruthy()
  })

  it('resolves the locale from the language list', () => {
    expect(resolveUiLocale(['ru-RU'])).toBe('ru')
    expect(resolveUiLocale(['de', 'kk'])).toBe('kk')
    expect(resolveUiLocale(['de'])).toBe('en')
  })
})
