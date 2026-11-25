/** designerGuide.test.ts — T-2804
 *
 * docs/designer-guide.md (en), .ru.md and .kk.md must
 *  1. carry the same section anchor ids, in the same order (part 2 links to them), and
 *  2. name only screen labels that exist in the product's messages file for that language: each section lists
 *     its label keys in an HTML comment (`<!-- labels: pd.view.editor, defs.publish -->`), every key must exist
 *     in the catalogue for that language, and the section text must contain the catalogue's text.
 *  `pd.<id>` is `processDiagram.<id>` of processDiagramMessages; `defs.<id>` is definitionsMessages.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'

import { processDiagramMessages } from '@/i18n/processDiagramMessages'
import { definitionsMessages } from '@/pages/definitions/definitionsMessages'

const DOCS = path.resolve(__dirname, '../../../docs')
const FILES = { en: 'designer-guide.md', ru: 'designer-guide.ru.md', kk: 'designer-guide.kk.md' } as const
type Lang = keyof typeof FILES

const REQUIRED_IDS = [
  'sec-what-is-a-process',
  'sec-steps-and-editor',
  'sec-add-edit-step',
  'sec-function-picker',
  'sec-notification-step',
  'sec-start-and-end',
  'sec-validation-messages',
  'sec-save-version-activate',
  'sec-test-cases',
  'sec-runs-and-retry',
  'sec-platform-only',
]

interface Section {
  id: string
  text: string
  labels: string[]
}

function parse(lang: Lang): Section[] {
  const src = readFileSync(path.join(DOCS, FILES[lang]), 'utf8').replace(/\r\n/g, '\n')
  const parts = src.split(/^<a id="([a-z0-9-]+)"><\/a>$/m)
  const out: Section[] = []
  for (let i = 1; i < parts.length; i += 2) {
    const text = parts[i + 1]
    const m = /<!-- labels:([^>]*?)-->/.exec(text)
    const labels = (m?.[1] ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
    out.push({ id: parts[i], text, labels })
  }
  return out
}

function catalogueText(lang: Lang, key: string): string | undefined {
  if (key.startsWith('pd.')) return processDiagramMessages[lang][`processDiagram.${key.slice(3)}`]
  if (key.startsWith('defs.')) {
    return (definitionsMessages[lang] as unknown as Record<string, string>)[key.slice(5)]
  }
  return undefined
}

describe('designer guide (docs/designer-guide*.md)', () => {
  it('every language has all required section ids, in order, each once', () => {
    for (const lang of Object.keys(FILES) as Lang[]) {
      expect(parse(lang).map((s) => s.id), lang).toEqual(REQUIRED_IDS)
    }
  })

  it('the three files have the same section ids', () => {
    const en = parse('en').map((s) => s.id)
    expect(parse('ru').map((s) => s.id)).toEqual(en)
    expect(parse('kk').map((s) => s.id)).toEqual(en)
  })

  it('the three files list the same label keys per section', () => {
    const en = parse('en').map((s) => [s.id, s.labels])
    expect(parse('ru').map((s) => [s.id, s.labels])).toEqual(en)
    expect(parse('kk').map((s) => [s.id, s.labels])).toEqual(en)
  })

  it('the guide names real screen labels (at least one per screen section)', () => {
    const withLabels = parse('en').filter((s) => s.labels.length > 0).map((s) => s.id)
    for (const id of ['sec-steps-and-editor', 'sec-add-edit-step', 'sec-function-picker', 'sec-notification-step', 'sec-save-version-activate']) {
      expect(withLabels).toContain(id)
    }
  })

  for (const lang of Object.keys(FILES) as Lang[]) {
    it(`every label key exists in the ${lang} messages file and its text is in the section`, () => {
      for (const s of parse(lang)) {
        for (const key of s.labels) {
          const value = catalogueText(lang, key)
          expect(value, `${lang} ${s.id}: key ${key} is not in the messages file`).toBeTruthy()
          expect(s.text.includes(value as string), `${lang} ${s.id}: the text "${value}" (${key}) is not in the section`).toBe(true)
        }
      }
    })
  }
})
