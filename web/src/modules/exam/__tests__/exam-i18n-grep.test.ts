/**
 * REQ-338 AC10 — every string rendered by a component this requirement adds
 * is sourced from a react-intl message catalog covering kk, ru and en. This
 * test IS the grep the acceptance criterion names, run programmatically:
 *
 *   grep -nE ">[A-Za-z][A-Za-z '.-]{2,}<" \
 *     web/src/modules/exam/ExamListPage.tsx \
 *     web/src/modules/exam/ExamSessionPage.tsx \
 *     web/src/modules/exam/ExamIntlProvider.tsx
 *
 * (web/src/modules/exam/examMessages.ts is deliberately excluded -- it IS the source
 * of the strings, not a hit.)
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { EXAM_UI_LOCALES, examMessages } from '../examMessages'

// This test file is at web/src/modules/exam/__tests__/, so three levels up
// reaches web/src/
const SRC_ROOT = path.resolve(__dirname, '../../..')

const JSX_FILES_TO_CHECK = [
  'modules/exam/ExamListPage.tsx',
  'modules/exam/ExamSessionPage.tsx',
  'modules/exam/ExamIntlProvider.tsx',
  // GH 3355 / REQ-602: the exam builder screens.
  'modules/exam/ExamBuilderPage.tsx',
  'modules/exam/ExamBuilderListPage.tsx',
  'modules/exam/ExamBuilderFields.tsx',
  'modules/exam/ExamBuilderLink.tsx',
]

const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g

describe('REQ-338 AC10 — no hard-coded English string literal in JSX text content', () => {
  for (const relativePath of JSX_FILES_TO_CHECK) {
    it(`${relativePath} has no bare JSX text node`, () => {
      const contents = readFileSync(path.join(SRC_ROOT, relativePath), 'utf-8')
      const hits = contents.match(JSX_TEXT_NODE) ?? []
      expect(hits).toEqual([])
    })
  }

  it('examMessages.ts covers kk, ru and en for every message id, with no id missing a locale', () => {
    const idSets = EXAM_UI_LOCALES.map((locale) => new Set(Object.keys(examMessages[locale])))
    const [first, ...rest] = idSets
    for (const other of rest) {
      expect([...other].sort()).toEqual([...first].sort())
    }
    expect(first.size).toBeGreaterThan(0)
  })
})
