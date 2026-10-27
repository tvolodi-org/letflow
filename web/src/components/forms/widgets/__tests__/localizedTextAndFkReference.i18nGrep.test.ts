/**
 * REQ-342 AC — every string the localized_text and fk-reference widgets
 * render is sourced from a react-intl message catalog covering kk, ru and
 * en; a grep for a hard-coded English string literal in JSX text content
 * across the new files returns no hit outside message-catalog files.
 *
 * This is the SAME grep REQ-336's AC7 test already runs (see
 * web/src/__tests__/entities-i18n-grep.test.ts), applied to REQ-342's own
 * two new widget files instead:
 *
 *   grep -nE ">[A-Za-z][A-Za-z '.-]{2,}<" \
 *     web/src/components/forms/widgets/localizedText.tsx \
 *     web/src/components/forms/widgets/searchableSelect.tsx
 *
 * Both files render every user-visible string through
 * `intl.formatMessage({ id: ... })` (locale-tab labels, the fk-reference
 * search placeholder/loading/no-results strings) -- never a literal JSX
 * text node -- so this returns no hits.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { ENTITIES_UI_LOCALES, entitiesMessages } from '@/i18n/entitiesMessages'

const SRC_ROOT = path.resolve(__dirname, '..', '..', '..', '..')

const JSX_FILES_TO_CHECK = [
  'components/forms/widgets/localizedText.tsx',
  'components/forms/widgets/searchableSelect.tsx',
  'components/forms/widgets/categoryTreeSelect.tsx',
]

const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g

describe('REQ-342 — no hard-coded English string literal in JSX text content', () => {
  for (const relativePath of JSX_FILES_TO_CHECK) {
    it(`${relativePath} has no bare JSX text node`, () => {
      const contents = readFileSync(path.join(SRC_ROOT, relativePath), 'utf-8')
      const hits = contents.match(JSX_TEXT_NODE) ?? []
      expect(hits).toEqual([])
    })
  }

  it('every entities.widgets.* message id this requirement added is populated for kk, ru and en', () => {
    const newIds = [
      'entities.widgets.localizedText.groupLabel',
      'entities.widgets.localizedText.locale.kk',
      'entities.widgets.localizedText.locale.ru',
      'entities.widgets.localizedText.locale.en',
      'entities.widgets.localizedText.locale.other',
      'entities.widgets.fkReference.searchPlaceholder',
      'entities.widgets.fkReference.loading',
      'entities.widgets.fkReference.noResults',
    ]
    for (const locale of ENTITIES_UI_LOCALES) {
      for (const id of newIds) {
        expect(entitiesMessages[locale][id], `${locale} missing ${id}`).toBeTruthy()
      }
    }
  })
})
