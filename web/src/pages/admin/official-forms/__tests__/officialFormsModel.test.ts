// @vitest-environment node
/** T-1983 model tests M1-M7: registry vs priv/print_forms, per-form state, refusal codes vs the Elixir source,
 *  places, reason codes, conflict mapping, rollbackable. */
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { OfficialFormTemplateMeta } from '@/api/officialFormTemplates'
import { officialFormsMessages } from '../officialFormsMessages'
import {
  OFFICIAL_TEMPLATE_FORMS,
  REASON_CODES,
  REFUSAL_CODES,
  conflictKey,
  fileNameOf,
  formState,
  isReasonCode,
  knownReasonId,
  placeParts,
  rollbackable,
  rowsOf,
} from '../officialFormsModel'

const REPO = join(__dirname, '..', '..', '..', '..', '..', '..')

function row(over: Partial<OfficialFormTemplateMeta>): OfficialFormTemplateMeta {
  return {
    id: 'x', form: 'z1', locale: 'ru', version_no: 1, status: 'retired', byte_size: 1, sha256: '', rollback_of: null,
    created_by: null, activated_by: null, activated_at: null, retired_at: null, reason_code: null,
    inserted_at: '', updated_at: '', ...over,
  }
}

describe('M1 registry vs priv/print_forms', () => {
  it('has exactly the shipped forms, each with en/ru/kk code and name', () => {
    const shipped = readdirSync(join(REPO, 'priv', 'print_forms'))
      .filter((f) => f.endsWith('.json') && f !== 'messages.json')
      .map((f) => f.replace(/\.json$/, ''))
      .sort()
    expect(OFFICIAL_TEMPLATE_FORMS.map((f) => f.id).sort()).toEqual(shipped)
    for (const lang of ['en', 'ru', 'kk'] as const) {
      for (const f of OFFICIAL_TEMPLATE_FORMS) {
        expect(officialFormsMessages[lang][`officialForms.form.${f.id}.code`]).toBeTruthy()
        expect(officialFormsMessages[lang][`officialForms.form.${f.id}.name`]).toBeTruthy()
      }
    }
  })
})

describe('M2 formState', () => {
  it('standard, one active, two locales, draft, retired only', () => {
    expect(formState([])).toEqual({ active: [], draft: null })
    expect(formState([row({ status: 'retired' })])).toEqual({ active: [], draft: null })
    const a = row({ id: 'a', status: 'active', version_no: 3 })
    const k = row({ id: 'k', status: 'active', locale: 'kk', version_no: 2 })
    const d = row({ id: 'd', status: 'draft', version_no: 4 })
    const d2 = row({ id: 'd2', status: 'draft', version_no: 5 })
    const s = formState([a, k, d, d2])
    expect(s.active.map((r) => r.id)).toEqual(['a', 'k'])
    expect(s.draft?.id).toBe('d2')
  })
  it('rowsOf keeps one form, locale order then newest first', () => {
    const rows = [row({ id: '1', version_no: 1 }), row({ id: '2', version_no: 2, locale: 'default' }), row({ id: '3', version_no: 3 }), row({ id: '4', form: 'z2' })]
    expect(rowsOf(rows, 'z1').map((r) => r.id)).toEqual(['2', '3', '1'])
  })
})

describe('M3 refusal codes vs the Elixir source', () => {
  it('REFUSAL_CODES equals @codes of form_template.ex and every code has en/ru/kk text', () => {
    const src = readFileSync(join(REPO, 'lib', 'letflow', 'documents', 'form_template.ex'), 'utf8')
    const m = /@codes ~w\(([^)]*)\)a/.exec(src)
    expect(m).not.toBeNull()
    const elixir = m![1].trim().split(/\s+/)
    expect([...REFUSAL_CODES]).toEqual(elixir)
    for (const lang of ['en', 'ru', 'kk'] as const) {
      for (const code of elixir) expect(officialFormsMessages[lang][`officialForms.refusal.${code}`]).toBeTruthy()
    }
  })
})

describe('M4 placeParts', () => {
  it('reads the known keys in reading order and ignores the rest', () => {
    expect(placeParts({ table: 1, row: 2, cell: 5 })).toEqual([
      { key: 'table', value: '1' }, { key: 'row', value: '2' }, { key: 'cell', value: '5' },
    ])
    expect(placeParts({ paragraph: 12 })).toEqual([{ key: 'paragraph', value: '12' }])
    expect(placeParts({ part: 'word/header1.xml', company_text: 'SECRET', grid: 3 })).toEqual([{ key: 'part', value: 'word/header1.xml' }])
    expect(placeParts(null)).toEqual([])
  })
})

describe('M5 reason codes', () => {
  it('all match the server rule and have a text in every language', () => {
    for (const list of Object.values(REASON_CODES)) {
      for (const code of list) {
        expect(isReasonCode(code)).toBe(true)
        expect(knownReasonId(code)).toBe(`officialForms.reason.${code}`)
        for (const lang of ['en', 'ru', 'kk'] as const) expect(officialFormsMessages[lang][`officialForms.reason.${code}`]).toBeTruthy()
      }
    }
    expect(knownReasonId('superseded')).toBe('officialForms.reason.superseded')
    expect(knownReasonId('go_live')).toBeNull()
  })
})

describe('M6 conflictKey', () => {
  it('maps the three fixed texts, unknown 409, 403, 422', () => {
    const c = (detail: string) => conflictKey({ status: 409, details: { detail } })
    expect(c('template is not a draft')).toBe('officialForms.error.not_a_draft')
    expect(c('template is already retired')).toBe('officialForms.error.not_retirable')
    expect(c('only a retired template that was once active can be rolled back to')).toBe('officialForms.error.not_rollbackable')
    expect(c('something else')).toBe('officialForms.error.changed')
    expect(conflictKey({ status: 403 })).toBe('officialForms.error.forbidden')
    expect(conflictKey({ status: 422 })).toBe('officialForms.error.invalid')
    expect(conflictKey({ status: 500 })).toBe('officialForms.error.generic')
  })
})

describe('M7 rollbackable and file names', () => {
  it('only a retired row that was once active can be rolled back to', () => {
    expect(rollbackable({ status: 'retired', activated_at: '2026-11-01T00:00:00Z' })).toBe(true)
    expect(rollbackable({ status: 'retired', activated_at: null })).toBe(false)
    expect(rollbackable({ status: 'active', activated_at: '2026-11-01T00:00:00Z' })).toBe(false)
    expect(rollbackable({ status: 'draft', activated_at: null })).toBe(false)
  })
  it('fileNameOf reads a plain filename or falls back', () => {
    expect(fileNameOf('attachment; filename="z1-starter.docx"', 'x.docx')).toBe('z1-starter.docx')
    expect(fileNameOf(null, 'x.docx')).toBe('x.docx')
    expect(fileNameOf('attachment; filename="../evil"', 'x.docx')).toBe('x.docx')
  })
})
