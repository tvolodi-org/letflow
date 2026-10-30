/** REQ-631 part B — I1: the update-report ids exist, non-empty, in en, ru and kk. */
import { describe, expect, it } from 'vitest'
import { ENTITIES_UI_LOCALES, entitiesMessages } from '../entitiesMessages'

const REPORT_IDS = [
  ...['kept', 'override_conflict', 'orphaned', 'property_gone', 'unknown'].map((k) => `report.outcome.${k}`),
  'report.warning.override_kept_pack_changed',
  'report.nonBlocking',
  'report.heading.overrideConflicts',
  'report.overrideConflict.hint',
  ...['advanced', 'retired', 'orphaned', 'property_gone', 'left_unchanged', 'unknown'].map((k) => `report.action.${k}`),
  'report.actions.heading',
  'report.applyNeedsManage',
  ...['conflict', 'forbidden', 'override_merge_unsupported', 'generic'].map((k) => `report.error.${k}`),
].map((k) => `solutionOverrides.${k}`)

describe('REQ-631 report messages', () => {
  it('I1 every report id is non-empty in every locale', () => {
    for (const locale of ENTITIES_UI_LOCALES) {
      for (const id of REPORT_IDS) {
        expect(entitiesMessages[locale][id]?.trim(), `${locale} ${id}`).toBeTruthy()
      }
    }
  })
})
