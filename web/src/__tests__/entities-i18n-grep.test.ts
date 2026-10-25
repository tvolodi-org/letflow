/**
 * REQ-336 AC7 — every string rendered by a component this requirement adds
 * is sourced from a react-intl message catalog covering kk, ru and en. This
 * test IS the grep the acceptance criterion names, run programmatically (not
 * shelled out, so it runs the same way under `npm test` on any host) against
 * every non-catalog file this requirement added or touched:
 *
 *   grep -nE ">[A-Za-z][A-Za-z '.-]{2,}<" \
 *     web/src/components/entities/EntityRecordForm.tsx \
 *     web/src/i18n/EntitiesIntlProvider.tsx
 *
 * (message-catalog files -- web/src/i18n/entitiesMessages.ts -- are
 * deliberately excluded: THEY are the source of the strings, not a hit.)
 *
 * ISS-0655: REQ-336's `TagListPage.tsx` pilot was removed as superseded dead
 * code once `tag` was wired into the generic `EntityCrudPage` path (it was
 * already generalized by REQ-343 for the other nine entity types; `tag` was
 * the one dropped from that generalization). Removed from the file list
 * below along with it.
 *
 * It also asserts entitiesMessages itself carries all three locales for
 * every id, so the catalog side of the AC is checked, not only the "no
 * inline literal" side.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { ENTITIES_UI_LOCALES, entitiesMessages } from '@/i18n/entitiesMessages'

const SRC_ROOT = path.resolve(__dirname, '..')

// Files this requirement added that render JSX text content. Deliberately
// NOT web/src/i18n/entitiesMessages.ts (the catalog itself) or
// web/src/api/entities.ts / web/src/utils/entityFieldToFormField.ts /
// web/src/types/api.ts (no JSX in any of them).
const JSX_FILES_TO_CHECK = [
  'components/entities/EntityRecordForm.tsx',
  'i18n/EntitiesIntlProvider.tsx',
  // REQ-343: the generic admin-CRUD screen and the BilimBaga admin section
  // wiring it replaces nine hand-copied pages with.
  'pages/entities/EntityCrudPage.tsx',
  'components/entities/EntityViewBar.tsx',
  'modules/exam/BilimBagaAdminPage.tsx',
  'modules/exam/BilimBagaEntityRoute.tsx',
]

// Matches a JSX text node: `>` then a capitalised/alphabetic run of 3+ chars
// then `<` -- i.e. literal text sitting directly between two tags. Deliberately
// does NOT match `>{...}<` (a JS expression child), which is how every real
// string in these files is actually rendered (intl.formatMessage/props).
const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g

describe('REQ-336 AC7 — no hard-coded English string literal in JSX text content', () => {
  for (const relativePath of JSX_FILES_TO_CHECK) {
    it(`${relativePath} has no bare JSX text node`, () => {
      const contents = readFileSync(path.join(SRC_ROOT, relativePath), 'utf-8')
      const hits = contents.match(JSX_TEXT_NODE) ?? []
      expect(hits).toEqual([])
    })
  }

  it('entitiesMessages.ts covers kk, ru and en for every message id, with no id missing a locale', () => {
    const idSets = ENTITIES_UI_LOCALES.map((locale) => new Set(Object.keys(entitiesMessages[locale])))
    const [first, ...rest] = idSets
    for (const other of rest) {
      expect([...other].sort()).toEqual([...first].sort())
    }
    // Sanity: the catalog is non-empty (a vacuously-true comparison above
    // would also pass on three empty catalogs).
    expect(first.size).toBeGreaterThan(0)
  })
})
