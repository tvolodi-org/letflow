/** E2/I1 — GH 3606 / REQ-672: the catalog has the same ids in en/ru/kk and covers every id used by the screen. */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { CODES_UI_LOCALES, codesMessages, resolveUiLocale } from '../codesMessages'
import { CODE_KINDS, CODE_REASONS, ENTRY_REASONS, STATUSES, TARGET_TYPES } from '../codesModel'

const DIR = path.resolve(__dirname, '..')

describe('E2 codesMessages', () => {
  it('has identical id sets in en, ru and kk, and ru/kk differ from en for every id', () => {
    const [first, ...rest] = CODES_UI_LOCALES.map((l) => Object.keys(codesMessages[l]).sort())
    for (const other of rest) expect(other).toEqual(first)
    // identical by nature in every language
    const same = new Set(['codes.common.dash', 'codes.kind.epc', 'codes.kind.tid'])
    for (const id of first) {
      if (same.has(id)) continue
      for (const l of ['ru', 'kk'] as const) expect(codesMessages[l][id], `${l} ${id}`).not.toBe(codesMessages.en[id])
    }
  })

  it('has a message per reason, entry reason, status, kind and target type, in every locale', () => {
    for (const locale of CODES_UI_LOCALES) {
      const m = codesMessages[locale]
      for (const r of CODE_REASONS) expect(m[`codes.error.${r}`], r).toBeTruthy()
      for (const r of ENTRY_REASONS) expect(m[`codes.entry.${r}`], r).toBeTruthy()
      for (const r of STATUSES) expect(m[`codes.status.${r}`], r).toBeTruthy()
      for (const r of CODE_KINDS) expect(m[`codes.kind.${r}`], r).toBeTruthy()
      for (const r of TARGET_TYPES) expect(m[`codes.target.${r}`], r).toBeTruthy()
      for (const id of ['forbidden', 'notFound', 'generic', 'unknown']) expect(m[`codes.error.${id}`], id).toBeTruthy()
    }
  })

  it('every literal id used in the sources exists', () => {
    const files = readdirSync(DIR).filter((f) => /\.(ts|tsx)$/.test(f) && f !== 'codesMessages.ts')
    const used = new Set<string>()
    for (const f of files) {
      for (const m of readFileSync(path.join(DIR, f), 'utf-8').matchAll(/'(codes\.[A-Za-z_]+\.[A-Za-z_]+)'/g)) used.add(m[1])
    }
    expect(used.size).toBeGreaterThan(15)
    for (const id of used) expect(codesMessages.en[id], id).toBeTruthy()
  })

  it('resolves the locale from the language list', () => {
    expect(resolveUiLocale(['ru-RU'])).toBe('ru')
    expect(resolveUiLocale(['de', 'kk'])).toBe('kk')
    expect(resolveUiLocale(['de'])).toBe('en')
  })
})
