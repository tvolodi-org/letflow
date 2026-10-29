/** questionEditorModel — GH 3423 / REQ-612
 *
 *  Pure logic of the question bank and the question editor (no React): query filters for the
 *  bank, the draft of one question with its answer options, validation, the field maps sent to
 *  the exam authoring routes, the plan of option writes on edit, and the mapping of save errors.
 *  The pages (QuestionBankPage, QuestionEditorPage) are thin on top of it.
 */

import type { EntityQueryFilterClause, EntityRecord } from '@/types/api'
import type { ExamUiLocale } from './examMessages'

export const QUESTION_TYPES = ['single', 'multiple', 'truefalse', 'likert', 'shorttext'] as const
export type QuestionType = (typeof QUESTION_TYPES)[number]

export const DIFFICULTIES = ['easy', 'medium', 'hard'] as const
export type Difficulty = (typeof DIFFICULTIES)[number]

export const POLARITIES = ['positive', 'negative'] as const
export type Polarity = (typeof POLARITIES)[number]

export const MIN_OPTIONS = 2
export const MAX_OPTIONS = 8

/** `POST /entities/query` returns soft-deleted rows unless told otherwise (the same filter value as
 *  `EXCLUDE_DELETED_FILTERS` in EntityCrudPage, which is private there). */
export const DELETED_FALSE: EntityQueryFilterClause = { field: 'deleted', op: 'eq', value: false }

export interface OptionDraft {
  /** Local key of the row (stable across renders). */
  key: string
  /** Record id of an already stored option; absent for a row not saved yet. */
  recordId?: string
  text: string
  isCorrect: boolean
  polarity: Polarity
  weight: number
}

export interface EditorDraft {
  stem: string
  type: QuestionType
  difficulty: Difficulty
  categoryId: string
  options: OptionDraft[]
}

export type StemColumn = 'stem_kk' | 'stem_ru' | 'stem_en'

export function stemColumn(locale: ExamUiLocale): StemColumn {
  return `stem_${locale}` as StemColumn
}

/** The text of a localized-text value: the UI locale, else the first filled of kk, ru, en, else ''. */
export function localizedText(value: unknown, locale: ExamUiLocale): string {
  if (!value || typeof value !== 'object') return ''
  const map = value as Record<string, unknown>
  for (const key of [locale, 'kk', 'ru', 'en']) {
    const text = map[key]
    if (typeof text === 'string' && text !== '') return text
  }
  return ''
}

/** Filters of the bank: never the deleted rows, plus a `contains` on the UI locale's stem column
 *  when the trimmed term is not empty. The term is only ever a filter value (INV-7). */
export function searchFilters(term: string, locale: ExamUiLocale): EntityQueryFilterClause[] {
  const filters: EntityQueryFilterClause[] = [DELETED_FALSE]
  if (term.trim() !== '') filters.push({ field: stemColumn(locale), op: 'contains', value: term })
  return filters
}

let counter = 0
export function newOptionKey(): string {
  counter += 1
  return `opt-${counter}`
}

export function blankOption(overrides: Partial<OptionDraft> = {}): OptionDraft {
  return { key: newOptionKey(), text: '', isCorrect: false, polarity: 'positive', weight: 1, ...overrides }
}

/** Default option rows of a type: two rows for single, multiple, likert; two fixed rows for truefalse
 *  (texts are filled at save time); none for shorttext. */
export function optionRowsForType(type: QuestionType): OptionDraft[] {
  if (type === 'shorttext') return []
  if (type === 'truefalse') return [blankOption({ isCorrect: true }), blankOption()]
  return [blankOption(), blankOption()]
}

export function emptyDraft(): EditorDraft {
  return { stem: '', type: 'single', difficulty: 'medium', categoryId: '', options: optionRowsForType('single') }
}

export type RefusalId = 'stemEmpty' | 'categoryMissing' | 'needOneCorrect' | 'needSomeCorrect' | 'optionCount'

/** Reasons a save is refused in the page (no request is sent). */
export function validateDraft(draft: EditorDraft): RefusalId[] {
  const issues: RefusalId[] = []
  if (draft.stem.trim() === '') issues.push('stemEmpty')
  if (draft.categoryId === '') issues.push('categoryMissing')
  const correct = draft.options.filter((o) => o.isCorrect).length
  if ((draft.type === 'single' || draft.type === 'truefalse') && correct !== 1) issues.push('needOneCorrect')
  if (draft.type === 'multiple' && correct < 1) issues.push('needSomeCorrect')
  if (
    (draft.type === 'single' || draft.type === 'multiple') &&
    (draft.options.length < MIN_OPTIONS || draft.options.length > MAX_OPTIONS)
  ) {
    issues.push('optionCount')
  }
  return issues
}

/** The `field_values` of the question record. On edit the loaded values of the fields the page does
 *  not edit (explanation, parent_id, version, status, default_locale, other stem locales) are kept. */
export function buildQuestionFields(
  draft: EditorDraft,
  locale: ExamUiLocale,
  loaded?: Record<string, unknown>,
): Record<string, unknown> {
  if (!loaded) {
    return {
      category_id: draft.categoryId,
      difficulty: draft.difficulty,
      type: draft.type,
      default_locale: locale,
      status: 'draft',
      version: 1,
      stem: { [locale]: draft.stem },
    }
  }
  const oldStem = loaded['stem'] && typeof loaded['stem'] === 'object' ? (loaded['stem'] as Record<string, unknown>) : {}
  return {
    ...loaded,
    category_id: draft.categoryId,
    difficulty: draft.difficulty,
    type: draft.type,
    stem: { ...oldStem, [locale]: draft.stem },
  }
}

/** The `field_values` of one answer option. `trueFalseWords` are the localized words true and false.
 *  On edit `loaded` (the stored field_values) is kept for what the page does not edit, because the
 *  authoring PUT replaces the document wholesale: the other text locales must survive. */
export function buildOptionFields(
  option: OptionDraft,
  index: number,
  questionId: string,
  type: QuestionType,
  locale: ExamUiLocale,
  trueFalseWords: { true: string; false: string },
  loaded?: Record<string, unknown>,
): Record<string, unknown> {
  const text = type === 'truefalse' ? (index === 0 ? trueFalseWords.true : trueFalseWords.false) : option.text
  const oldText = loaded?.['text'] && typeof loaded['text'] === 'object' ? (loaded['text'] as Record<string, unknown>) : {}
  const fields: Record<string, unknown> = {
    ...loaded,
    question_id: questionId,
    sort_order: index + 1,
    text: { ...oldText, [locale]: text },
    is_correct: type === 'likert' ? false : option.isCorrect,
  }
  if (type === 'likert') {
    fields['likert_polarity'] = option.polarity
    fields['likert_weight'] = option.weight
  }
  return fields
}

/** Draft rows of stored answer options, in sort_order. */
export function optionsFromRecords(records: EntityRecord[], locale: ExamUiLocale): OptionDraft[] {
  return [...records]
    .sort((a, b) => Number(a.field_values['sort_order'] ?? 0) - Number(b.field_values['sort_order'] ?? 0))
    .map((record) =>
      blankOption({
        recordId: record.record_id,
        text: localizedText(record.field_values['text'], locale),
        isCorrect: record.field_values['is_correct'] === true,
        polarity: record.field_values['likert_polarity'] === 'negative' ? 'negative' : 'positive',
        weight: typeof record.field_values['likert_weight'] === 'number' ? (record.field_values['likert_weight'] as number) : 1,
      }),
    )
}

export interface OptionWrite {
  index: number
  option: OptionDraft
}

export interface OptionPlan {
  creates: OptionWrite[]
  updates: OptionWrite[]
  deletes: string[]
}

/** Edit: rows without a record id are created, rows with one are updated, stored rows missing from the
 *  draft are deleted. Switching the type removes the stored rows and creates the new set. */
export function planOptionWrites(
  loaded: EntityRecord[],
  draftOptions: OptionDraft[],
  typeChanged = false,
): OptionPlan {
  if (typeChanged) {
    return {
      creates: draftOptions.map((option, index) => ({ index, option })),
      updates: [],
      deletes: loaded.map((r) => r.record_id),
    }
  }
  const keep = new Set(draftOptions.map((o) => o.recordId).filter((id): id is string => !!id))
  return {
    creates: draftOptions.flatMap((option, index) => (option.recordId ? [] : [{ index, option }])),
    updates: draftOptions.flatMap((option, index) => (option.recordId ? [{ index, option }] : [])),
    deletes: loaded.map((r) => r.record_id).filter((id) => !keep.has(id)),
  }
}

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  if (value && typeof value === 'object') {
    const map = value as Record<string, unknown>
    return `{${Object.keys(map)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${stable(map[k])}`)
      .join(',')}}`
  }
  return JSON.stringify(value) ?? 'undefined'
}

/** True when the field map to send differs from the stored one (key order is ignored). */
export function fieldsChanged(next: Record<string, unknown>, stored: Record<string, unknown>): boolean {
  return stable(next) !== stable(stored)
}

export type SaveErrorKind =
  | 'conflict'
  | 'parent_not_found'
  | 'lineage_branch'
  | 'version_not_increasing'
  | 'lineage_active_conflict'
  | 'forbidden'
  | 'generic'

const REASONS = ['parent_not_found', 'lineage_branch', 'version_not_increasing', 'lineage_active_conflict'] as const

function statusOf(error: unknown): number | undefined {
  const status = (error as { status?: unknown } | null)?.status
  return typeof status === 'number' ? status : undefined
}

/** The RFC 9457 `reason` of a refusal: `details.reason`, then `details.extensions.reason`. */
export function reasonOf(error: unknown): string | undefined {
  const details = (error as { details?: unknown } | null)?.details
  if (!details || typeof details !== 'object') return undefined
  const d = details as { reason?: unknown; extensions?: { reason?: unknown } | null }
  if (typeof d.reason === 'string') return d.reason
  if (d.extensions && typeof d.extensions.reason === 'string') return d.extensions.reason
  return undefined
}

export function saveErrorKind(error: unknown): SaveErrorKind {
  const status = statusOf(error)
  if (status === 409) return 'conflict'
  if (status === 403) return 'forbidden'
  if (status === 422) {
    const reason = reasonOf(error)
    const known = REASONS.find((r) => r === reason)
    if (known) return known
  }
  return 'generic'
}
