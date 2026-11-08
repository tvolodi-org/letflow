import { describe, expect, it } from 'vitest'
import { UI_LOCALES } from '@/i18n/uiLocaleStore'
import { DEFINITION_LABELS, definitionLabel } from '../definitionLabels'
import { dashboardMessages } from '../dashboardMessages'

describe('T-1496 definition labels', () => {
  it('T1 each assets key has en/ru/kk text that differs from the key', () => {
    expect(Object.keys(DEFINITION_LABELS)).toHaveLength(5)
    for (const [key, l] of Object.entries(DEFINITION_LABELS)) {
      for (const loc of UI_LOCALES) {
        expect(l[loc].length).toBeGreaterThan(0)
        expect(l[loc]).not.toBe(key)
        expect(l[loc]).not.toMatch(/_/)
      }
    }
  })

  it('T1 unknown and prototype names come back unchanged', () => {
    expect(definitionLabel('Onboarding', 'ru')).toBe('Onboarding')
    expect(definitionLabel('constructor', 'en')).toBe('constructor')
    expect(definitionLabel('__proto__', 'kk')).toBe('__proto__')
  })

  it('T4 every dashboard message exists non-empty in all languages', () => {
    for (const loc of UI_LOCALES) {
      for (const k of Object.keys(dashboardMessages.en) as (keyof typeof dashboardMessages.en)[]) {
        expect(dashboardMessages[loc][k].length).toBeGreaterThan(0)
      }
    }
  })
})
