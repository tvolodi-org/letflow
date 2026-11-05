/** C6-b — GH 3769 / REQ-722: no bare English text node in any .tsx under stock/documents (the REQ-338 grep). */
import { describe, expect, it } from 'vitest'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'

const DIR = path.resolve(__dirname, '..', 'documents')
const JSX_TEXT_NODE = />[A-Za-z][A-Za-z '.-]{2,}</g
const files = readdirSync(DIR).filter((f) => f.endsWith('.tsx')).map((f) => path.join(DIR, f))

describe('C6-b no hard-coded JSX text', () => {
  it('finds the document screens', () => {
    expect(files.map((f) => path.basename(f))).toEqual(
      expect.arrayContaining(['DocumentsPage.tsx', 'DocumentPage.tsx', 'DocumentNewPage.tsx', 'DocumentForm.tsx', 'LinesEditor.tsx', 'DocumentActions.tsx']),
    )
  })
  for (const f of files) {
    it(`${path.basename(f)} has no bare JSX text node`, () => {
      expect(readFileSync(f, 'utf-8').match(JSX_TEXT_NODE) ?? []).toEqual([])
    })
  }
})
