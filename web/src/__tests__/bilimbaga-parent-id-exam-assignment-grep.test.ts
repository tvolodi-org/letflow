/**
 * REQ-343 AC3, as revised by REQ-586 part D -- "exam_assignment is never
 * rendered or mocked by any new web/ file; parent_id appears as code only for
 * the two entity types that carry it, category and question."
 *
 * This test IS that grep, run programmatically (mirroring
 * web/src/__tests__/entities-i18n-grep.test.ts's own approach to AC7) so it
 * runs the same way under `npm test` on any host. It scans the runtime
 * (non-test) files and asserts:
 *   - every line matching /exam_assignment/i is a comment line, or a quoted
 *     copy string inside the message catalog (web/src/i18n/entitiesMessages.ts)
 *     describing the gap in prose -- never rendered UI or an entity entry;
 *   - every line matching /parent_id/i is a comment line, or sits in one of
 *     the two files that implement the category tree picker
 *     (widgets/categoryTreeSelect.tsx, utils/entityFieldToFormField.ts), or is
 *     a catalog copy string. No other runtime file names parent_id as code.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'

const SRC_ROOT = path.resolve(__dirname, '..')

const EXAM_ASSIGNMENT_PATTERN = /exam_assignment/i
const PARENT_ID_PATTERN = /parent_id/i

// Runtime (non-test) files. Test files are deliberately excluded -- they are
// ALLOWED to reference these terms directly (asserting their absence).
const FILES_TO_CHECK = [
  'config/bilimbagaEntities.ts',
  'pages/entities/EntityCrudPage.tsx',
  'modules/exam/BilimBagaAdminPage.tsx',
  'modules/exam/BilimBagaEntityRoute.tsx',
  'i18n/entitiesMessages.ts',
  'router.tsx',
  'components/layout/AppShell.tsx',
  'components/entities/EntityRecordForm.tsx',
  'components/entities/entityWidgetRegistry.ts',
  'components/forms/widgets/categoryTreeSelect.tsx',
  'components/forms/widgets/searchableSelect.tsx',
  'utils/entityFieldToFormField.ts',
]

// The only runtime files that may name parent_id as code: the category tree
// picker and the bridge that routes category.parent_id to it.
const PARENT_ID_CODE_FILES = new Set([
  'components/forms/widgets/categoryTreeSelect.tsx',
  'utils/entityFieldToFormField.ts',
])

function isCommentLine(line: string): boolean {
  const trimmed = line.trim()
  return trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')
}

function isCatalogCopyLine(relativePath: string, line: string): boolean {
  // entitiesMessages.ts's hits are the exam_assignment gap note's own
  // translated copy strings (kk/ru/en) -- every such line is a quoted string.
  if (relativePath !== 'i18n/entitiesMessages.ts') return false
  return /['"`].*['"`],?\s*$/.test(line.trim())
}

function offending(relativePath: string, pattern: RegExp): string[] {
  const contents = readFileSync(path.join(SRC_ROOT, relativePath), 'utf-8')
  return contents
    .split('\n')
    .filter((line) => pattern.test(line) && !isCommentLine(line) && !isCatalogCopyLine(relativePath, line))
}

describe('REQ-343 AC3 / REQ-586 part D -- grep for exam_assignment and parent_id across the web/ runtime files', () => {
  for (const relativePath of FILES_TO_CHECK) {
    it(`${relativePath}: exam_assignment is only ever a comment or catalog copy string`, () => {
      expect(offending(relativePath, EXAM_ASSIGNMENT_PATTERN)).toEqual([])
    })

    it(`${relativePath}: parent_id as code only in the category tree picker files`, () => {
      const hits = offending(relativePath, PARENT_ID_PATTERN)
      if (PARENT_ID_CODE_FILES.has(relativePath)) {
        expect(hits.length).toBeGreaterThan(0)
      } else {
        expect(hits).toEqual([])
      }
    })
  }

  it('BILIMBAGA_ENTITY_TYPES (the nav/route source of truth) never names an exam_assignment entity', async () => {
    const { BILIMBAGA_ENTITY_TYPES } = await import('@/config/bilimbagaEntities')
    expect(BILIMBAGA_ENTITY_TYPES.map((e) => e.entityType)).not.toContain('exam_assignment')
    // ISS-0655: ten admin-manageable pack entity types, not nine -- `tag`
    // was missing and has been added back.
    expect(BILIMBAGA_ENTITY_TYPES).toHaveLength(10)
  })
})
