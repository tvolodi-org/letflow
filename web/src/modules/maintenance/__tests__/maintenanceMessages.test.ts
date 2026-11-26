/** GH 4802 / REQ-898: the catalog of the maintenance screens has the same ids in en/ru/kk and covers every id the
 *  screens use (AC5: every new label exists in the en, ru and kk catalogs). */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { MAINTENANCE_UI_LOCALES, maintenanceMessages, resolveUiLocale } from '../maintenanceMessages'
import { PHOTO_REASONS, REASONS } from '../maintenanceModel'
import { REQUEST_STATUSES, URGENCIES } from '../maintenance.api'

const DIR = path.resolve(__dirname, '..')

describe('maintenanceMessages', () => {
  it('has identical id sets in en, ru and kk, and ru/kk differ from en for every id', () => {
    const [first, ...rest] = MAINTENANCE_UI_LOCALES.map((l) => Object.keys(maintenanceMessages[l]).sort())
    for (const other of rest) expect(other).toEqual(first)
    for (const id of first) {
      for (const l of ['ru', 'kk'] as const) {
        expect(maintenanceMessages[l][id], `${l} ${id}`).not.toBe(maintenanceMessages.en[id])
      }
    }
  })

  it('has a message per reason, photo reason, status and urgency, in every locale', () => {
    for (const locale of MAINTENANCE_UI_LOCALES) {
      const m = maintenanceMessages[locale]
      for (const r of REASONS) expect(m[`maintenance.error.${r}`], r).toBeTruthy()
      for (const r of PHOTO_REASONS) expect(m[`maintenance.photos.error.${r}`], r).toBeTruthy()
      for (const s of REQUEST_STATUSES) expect(m[`maintenance.status.${s}`], s).toBeTruthy()
      for (const u of URGENCIES) expect(m[`maintenance.urgency.${u}`], u).toBeTruthy()
      for (const id of ['notFound', 'forbidden', 'unknown', 'generic']) expect(m[`maintenance.error.${id}`], id).toBeTruthy()
      for (const id of ['notFound', 'forbidden', 'unknown', 'generic']) expect(m[`maintenance.photos.error.${id}`], id).toBeTruthy()
    }
  })

  it('every literal id used in the sources exists', () => {
    const files = readdirSync(DIR).filter((f) => /\.(ts|tsx)$/.test(f) && f !== 'maintenanceMessages.ts')
    const used = new Set<string>()
    for (const f of files) {
      for (const m of readFileSync(path.join(DIR, f), 'utf-8').matchAll(/'(maintenance\.[A-Za-z_]+\.[A-Za-z_]+)'/g)) used.add(m[1])
    }
    expect(used.size).toBeGreaterThan(15)
    for (const id of used) expect(maintenanceMessages.en[id], id).toBeTruthy()
  })

  it('resolves the locale from the language list', () => {
    expect(resolveUiLocale(['ru-RU'])).toBe('ru')
    expect(resolveUiLocale(['de', 'kk'])).toBe('kk')
    expect(resolveUiLocale(['de'])).toBe('en')
  })
})
