/** GH 3423 / REQ-612 — the pure logic of the question bank and editor (M1..M7). */
import { describe, expect, it } from 'vitest'
import type { EntityRecord } from '@/types/api'
import {
  DELETED_FALSE,
  blankOption,
  buildOptionFields,
  buildQuestionFields,
  emptyDraft,
  localizedText,
  optionRowsForType,
  planOptionWrites,
  reasonOf,
  saveErrorKind,
  searchFilters,
  stemColumn,
  validateDraft,
  type EditorDraft,
} from '../questionEditorModel'

function rec(id: string): EntityRecord {
  return { record_id: id, field_values: {}, deleted: false, entity_def_version: 'v', last_event_global_seq: 1 }
}

function draftOf(patch: Partial<EditorDraft>): EditorDraft {
  return { ...emptyDraft(), stem: 'Q', categoryId: 'c1', ...patch }
}

describe('M1 stemColumn', () => {
  it('maps each UI locale to its promoted stem column', () => {
    expect(stemColumn('kk')).toBe('stem_kk')
    expect(stemColumn('ru')).toBe('stem_ru')
    expect(stemColumn('en')).toBe('stem_en')
  })
})

describe('M2 searchFilters', () => {
  it('an empty or blank term gives the deleted filter only', () => {
    expect(searchFilters('', 'en')).toEqual([DELETED_FALSE])
    expect(searchFilters('   ', 'en')).toEqual([DELETED_FALSE])
  })
  it('a term gives a contains filter on the locale column with the term unmodified', () => {
    expect(searchFilters("50%_'x", 'ru')).toEqual([DELETED_FALSE, { field: 'stem_ru', op: 'contains', value: "50%_'x" }])
  })
})

describe('localizedText', () => {
  it('prefers the UI locale, then the first filled of kk, ru, en', () => {
    expect(localizedText({ en: 'E', ru: 'R' }, 'en')).toBe('E')
    expect(localizedText({ ru: 'R', en: 'E' }, 'kk')).toBe('R')
    expect(localizedText({ kk: '', en: 'E' }, 'ru')).toBe('E')
    expect(localizedText(null, 'en')).toBe('')
  })
})

describe('M3 buildQuestionFields create', () => {
  it('sets draft status, version 1, default locale and the stem under the UI locale', () => {
    expect(buildQuestionFields(draftOf({ stem: 'Hello', difficulty: 'hard', type: 'multiple' }), 'ru')).toEqual({
      category_id: 'c1',
      difficulty: 'hard',
      type: 'multiple',
      default_locale: 'ru',
      status: 'draft',
      version: 1,
      stem: { ru: 'Hello' },
    })
  })
})

describe('M4 buildQuestionFields edit', () => {
  it('keeps explanation, parent_id, version, status and the other stem locales', () => {
    const loaded = {
      category_id: 'old',
      difficulty: 'easy',
      type: 'single',
      explanation: { en: 'why' },
      parent_id: 'p1',
      version: 3,
      status: 'review',
      default_locale: 'kk',
      stem: { kk: 'K', en: 'old' },
    }
    const fields = buildQuestionFields(draftOf({ stem: 'new', difficulty: 'hard' }), 'en', loaded)
    expect(fields).toMatchObject({
      explanation: { en: 'why' },
      parent_id: 'p1',
      version: 3,
      status: 'review',
      default_locale: 'kk',
      category_id: 'c1',
      difficulty: 'hard',
      stem: { kk: 'K', en: 'new' },
    })
  })
})

describe('M5 validateDraft', () => {
  const two = (a: boolean, b: boolean) => [blankOption({ text: 'a', isCorrect: a }), blankOption({ text: 'b', isCorrect: b })]
  it('accepts a valid single question', () => {
    expect(validateDraft(draftOf({ options: two(true, false) }))).toEqual([])
  })
  it('refuses an empty stem', () => {
    expect(validateDraft(draftOf({ stem: '  ', options: two(true, false) }))).toContain('stemEmpty')
  })
  it('refuses a missing category', () => {
    expect(validateDraft(draftOf({ categoryId: '', options: two(true, false) }))).toContain('categoryMissing')
  })
  it('refuses a single question with zero or two correct options', () => {
    expect(validateDraft(draftOf({ options: two(false, false) }))).toContain('needOneCorrect')
    expect(validateDraft(draftOf({ options: two(true, true) }))).toContain('needOneCorrect')
  })
  it('refuses a truefalse question without exactly one correct option', () => {
    expect(validateDraft(draftOf({ type: 'truefalse', options: two(false, false) }))).toContain('needOneCorrect')
    expect(validateDraft(draftOf({ type: 'truefalse', options: two(true, false) }))).toEqual([])
  })
  it('refuses a multiple question with no correct option and accepts several', () => {
    expect(validateDraft(draftOf({ type: 'multiple', options: two(false, false) }))).toContain('needSomeCorrect')
    expect(validateDraft(draftOf({ type: 'multiple', options: two(true, true) }))).toEqual([])
  })
  it('accepts likert and shorttext without a correct option', () => {
    expect(validateDraft(draftOf({ type: 'likert', options: two(false, false) }))).toEqual([])
    expect(validateDraft(draftOf({ type: 'shorttext', options: [] }))).toEqual([])
  })
})

describe('optionRowsForType and buildOptionFields', () => {
  it('gives the default rows per type', () => {
    expect(optionRowsForType('single')).toHaveLength(2)
    expect(optionRowsForType('truefalse')).toHaveLength(2)
    expect(optionRowsForType('shorttext')).toEqual([])
  })
  it('likert rows carry polarity and weight and are sent with is_correct false', () => {
    const option = blankOption({ text: 'x', isCorrect: true, polarity: 'negative', weight: 2.5 })
    expect(buildOptionFields(option, 0, 'q1', 'likert', 'en', { true: 'T', false: 'F' })).toEqual({
      question_id: 'q1',
      sort_order: 1,
      text: { en: 'x' },
      is_correct: false,
      likert_polarity: 'negative',
      likert_weight: 2.5,
    })
  })
  it('truefalse rows take the localized words', () => {
    const f = buildOptionFields(blankOption(), 1, 'q1', 'truefalse', 'ru', { true: 'Верно', false: 'Неверно' })
    expect(f).toMatchObject({ sort_order: 2, text: { ru: 'Неверно' }, is_correct: false })
  })
})

describe('M6 planOptionWrites', () => {
  it('creates new rows, updates stored rows, deletes stored rows missing from the draft', () => {
    const loaded = [rec('a'), rec('b')]
    const draft = [blankOption({ recordId: 'a' }), blankOption()]
    const plan = planOptionWrites(loaded, draft)
    expect(plan.updates.map((u) => [u.index, u.option.recordId])).toEqual([[0, 'a']])
    expect(plan.creates.map((c) => c.index)).toEqual([1])
    expect(plan.deletes).toEqual(['b'])
  })
  it('a type change deletes all stored rows and creates the whole new set', () => {
    const plan = planOptionWrites([rec('a')], [blankOption({ recordId: 'a' }), blankOption()], true)
    expect(plan.deletes).toEqual(['a'])
    expect(plan.creates).toHaveLength(2)
    expect(plan.updates).toEqual([])
  })
})

describe('M7 saveErrorKind', () => {
  it('maps 409 to conflict and 403 to forbidden', () => {
    expect(saveErrorKind({ status: 409 })).toBe('conflict')
    expect(saveErrorKind({ status: 403 })).toBe('forbidden')
  })
  it('maps each known 422 reason from details.reason, and from details.extensions.reason', () => {
    for (const reason of ['parent_not_found', 'lineage_branch', 'version_not_increasing', 'lineage_active_conflict']) {
      expect(saveErrorKind({ status: 422, details: { reason } })).toBe(reason)
    }
    expect(saveErrorKind({ status: 422, details: { extensions: { reason: 'lineage_branch' } } })).toBe('lineage_branch')
  })
  it('maps an unknown 422 reason and anything else to generic', () => {
    expect(saveErrorKind({ status: 422, details: { reason: 'weird' } })).toBe('generic')
    expect(saveErrorKind({ status: 500 })).toBe('generic')
    expect(saveErrorKind(new Error('x'))).toBe('generic')
    expect(reasonOf(null)).toBeUndefined()
  })
})
