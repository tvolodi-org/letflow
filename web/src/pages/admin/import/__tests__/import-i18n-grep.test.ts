/**
 * I4: GH 3650 / REQ-675 criterion 7. No bare JSX text in the page files, in the style of
 * exam-i18n-grep.test.ts:  grep -nE ">[A-Za-z][A-Za-z '.-]{2,}<" <files>
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'

const SRC_ROOT = path.resolve(__dirname, '../../../..')
const FILES = ['pages/admin/import/MasterDataImportPage.tsx', 'i18n/ImportIntlProvider.tsx']
const BARE_TEXT = />[A-Za-z][A-Za-z '.-]{2,}</

describe('I4 no bare JSX text', () => {
  it.each(FILES)('%s', (file) => {
    const hits = readFileSync(path.join(SRC_ROOT, file), 'utf8')
      .split(/\r?\n/)
      .filter((line) => BARE_TEXT.test(line))
    expect(hits).toEqual([])
  })
})
