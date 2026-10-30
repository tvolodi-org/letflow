/** REQ-631 part A — I1: every solutionOverrides.* id exists, non-empty, in en, ru and kk. */
import { describe, expect, it } from 'vitest'
import { entitiesMessages, ENTITIES_UI_LOCALES } from '../entitiesMessages'
import { solutionOverridesMessages } from '../solutionOverridesMessages'

describe('REQ-631 solutionOverrides messages', () => {
  const ids = Object.keys(solutionOverridesMessages.en)

  it('I1 the same non-empty ids exist in every locale and are in the entities catalog', () => {
    expect(ids.length).toBeGreaterThan(30)
    for (const locale of ENTITIES_UI_LOCALES) {
      expect(Object.keys(solutionOverridesMessages[locale]).sort()).toEqual([...ids].sort())
      for (const id of ids) {
        expect(id.startsWith('solutionOverrides.')).toBe(true)
        expect(solutionOverridesMessages[locale][id].trim()).not.toBe('')
        expect(entitiesMessages[locale][id]).toBe(solutionOverridesMessages[locale][id])
      }
    }
  })
})
