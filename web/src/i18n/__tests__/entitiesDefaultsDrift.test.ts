/**
 * REQ-551 (GH #3180) criterion 1: the backend serves the platform default label texts from
 * priv/labels/entities_defaults.json. That file is generated from `entitiesMessages` (only the
 * "entities." ids, locales en/ru/kk); this test fails when the two differ, so an edit of either
 * runs in the frontend gate. Regenerate with `LABELS_WRITE=1 npx vitest run entitiesDefaultsDrift`.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { ENTITIES_UI_LOCALES, entitiesMessages } from '../entitiesMessages'

const FILE = path.resolve(__dirname, '../../../../priv/labels/entities_defaults.json')

function expected(): Record<string, Record<string, string>> {
  const out: Record<string, Record<string, string>> = {}
  for (const locale of ENTITIES_UI_LOCALES) {
    const sorted: Record<string, string> = {}
    for (const id of Object.keys(entitiesMessages[locale]).sort()) {
      if (id.startsWith('entities.')) sorted[id] = entitiesMessages[locale][id]
    }
    out[locale] = sorted
  }
  return out
}

if (process.env.LABELS_WRITE === '1') {
  writeFileSync(FILE, JSON.stringify(expected(), null, 2) + '\n')
}

describe('priv/labels/entities_defaults.json drift (REQ-551 D2)', () => {
  const file = JSON.parse(readFileSync(FILE, 'utf-8')) as Record<string, Record<string, string>>

  it('equals the "entities." ids and texts of entitiesMessages for en, ru and kk', () => {
    expect(file).toEqual(expected())
  })

  it('has exactly the platform locales and no "login." id', () => {
    expect(Object.keys(file).sort()).toEqual([...ENTITIES_UI_LOCALES].sort())
    for (const locale of Object.keys(file)) {
      expect(Object.keys(file[locale]).filter((id) => id.startsWith('login.'))).toEqual([])
    }
  })
})
