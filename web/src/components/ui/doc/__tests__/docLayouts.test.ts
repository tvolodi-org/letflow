/** L1, L8 — the registry of document layouts. */
import { describe, expect, it } from 'vitest'
import { UI_LOCALES } from '@/i18n/uiLocaleStore'
import { mySettingsMessages } from '@/pages/me/mySettingsMessages'
import { DOC_LAYOUTS, defaultTabFor, firstProblemTab, isDocLayoutName, problemsByPane } from '../docLayouts'

describe('L1 docLayouts', () => {
  it('has row (no tabs) and tabs, each with a hook and en/ru/kk label and hint', () => {
    expect(Object.keys(DOC_LAYOUTS)).toEqual(['row', 'tabs'])
    expect(DOC_LAYOUTS.row.tabs).toBeNull()
    expect(DOC_LAYOUTS.tabs.tabs).toEqual(['header', 'lines'])
    for (const def of Object.values(DOC_LAYOUTS)) {
      expect(def.hook).toContain(`data-layout="${def.name}"`)
      for (const l of UI_LOCALES) {
        expect(def.label[l].length).toBeGreaterThan(0)
        expect(def.hint[l].length).toBeGreaterThan(0)
      }
    }
  })

  it('a new document opens on Header, an existing one on Lines; row has no tab', () => {
    expect(defaultTabFor('tabs', 'new')).toBe('header')
    expect(defaultTabFor('tabs', 'existing')).toBe('lines')
    expect(defaultTabFor('row', 'new')).toBeNull()
  })

  it('knows its names only', () => {
    expect(isDocLayoutName('tabs')).toBe(true)
    expect(isDocLayoutName('grid')).toBe(false)
    expect(isDocLayoutName('toString')).toBe(false)
    expect(isDocLayoutName(undefined)).toBe(false)
  })

  it('maps error keys to panes and picks the first pane with a problem', () => {
    const p = problemsByPane({ 'header.orgUnitId': 'x', 'side.from.orgUnitId': 'x', sides: 'x', lines: 'x', 'lines.2.itemId': 'x' })
    expect(p).toEqual({ header: 3, lines: 2 })
    expect(firstProblemTab(p)).toBe('header')
    expect(firstProblemTab({ header: 0, lines: 1 })).toBe('lines')
    expect(firstProblemTab({ header: 0, lines: 0 })).toBeNull()
  })
})

describe('L8 mySettingsMessages', () => {
  it('has the same keys in en, ru and kk, none empty', () => {
    const keys = Object.keys(mySettingsMessages.en).sort()
    for (const l of UI_LOCALES) {
      expect(Object.keys(mySettingsMessages[l]).sort()).toEqual(keys)
      for (const v of Object.values(mySettingsMessages[l])) expect(v.length).toBeGreaterThan(0)
    }
  })
})
