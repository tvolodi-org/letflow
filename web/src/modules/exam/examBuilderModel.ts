/** examBuilderModel — GH 3355 / REQ-602
 *
 *  Pure logic of the exam builder screen (no React): the editable state, loading it from the three
 *  record lists, validation before send, the ordered save plan and the mapping of API errors onto
 *  controls. The page (ExamBuilderPage.tsx) only renders this and runs the plan.
 */

import type { EntityRecord } from '@/types/api'

export const BUILDER_LOCALES = ['kk', 'ru', 'en'] as const
export type BuilderLocale = (typeof BUILDER_LOCALES)[number]
export type LocalizedInput = Record<BuilderLocale, string>

export const EXAM_STATUSES = ['draft', 'active', 'archived'] as const
export const SHOW_ANSWERS = ['never', 'after_completion', 'after_all_attempts'] as const
export const TAB_SWITCH = ['log', 'warn', 'submit'] as const
export const RULE_MODES = ['manual', 'random'] as const

export interface ExamForm {
  title: LocalizedInput
  description: LocalizedInput
  status: string
  time_limit_minutes: string
  passing_score_pct: string
  max_attempts: string
  available_from: string
  available_until: string
  shuffle_questions: boolean
  shuffle_options: boolean
  show_answers: string
  on_tab_switch: string
  certificate_enabled: boolean
}

/** `key` is the record id for a loaded row and a `new-N` token for an unsaved one; it stays stable
 *  after a first save so rules can keep naming their section. */
export interface SectionRow {
  key: string
  recordId?: string
  title: LocalizedInput
  sort_order: string
  dirty: boolean
}

export interface RuleRow {
  key: string
  recordId?: string
  /** The `key` of the section the rule sits in; null = no section. A key naming no loaded section is
   *  shown in the "unsectioned" group and sent unchanged. */
  sectionKey: string | null
  mode: string
  category_id: string
  difficulty: string
  count: string
  sort_order: string
  dirty: boolean
}

export interface BuilderState {
  examId: string
  exam: ExamForm
  sections: SectionRow[]
  rules: RuleRow[]
  deletedSections: string[]
  deletedRules: string[]
}

export interface LoadedRecords {
  exam: EntityRecord
  sections: EntityRecord[]
  rules: EntityRecord[]
}

const emptyLocalized = (): LocalizedInput => ({ kk: '', ru: '', en: '' })

function str(value: unknown): string {
  return value === null || value === undefined ? '' : String(value)
}

function localizedFrom(value: unknown): LocalizedInput {
  const out = emptyLocalized()
  if (value && typeof value === 'object') {
    for (const locale of BUILDER_LOCALES) out[locale] = str((value as Record<string, unknown>)[locale])
  }
  return out
}

/** `2026-10-01T10:00:00Z` -> `2026-10-01T10:00` (the value of a datetime-local input, read as UTC). */
function toInputDateTime(value: unknown): string {
  const text = str(value)
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(text) ? text.slice(0, 16) : ''
}

function sortOrderOf(record: EntityRecord): number {
  const n = Number(record.field_values['sort_order'])
  return Number.isFinite(n) ? n : 0
}

export function newExamDefaults(): Record<string, unknown> {
  return {
    title: { en: 'New exam' },
    status: 'draft',
    time_limit_minutes: 60,
    passing_score_pct: 50,
    max_attempts: 1,
    shuffle_questions: false,
    shuffle_options: false,
    show_answers: 'after_completion',
    on_tab_switch: 'log',
    certificate_enabled: false,
  }
}

export function fromLoaded(examId: string, loaded: LoadedRecords): BuilderState {
  const fv = loaded.exam.field_values
  const sections = [...loaded.sections]
    .sort((a, b) => sortOrderOf(a) - sortOrderOf(b))
    .map<SectionRow>((record) => ({
      key: record.record_id,
      recordId: record.record_id,
      title: localizedFrom(record.field_values['title']),
      sort_order: str(record.field_values['sort_order']),
      dirty: false,
    }))
  const rules = [...loaded.rules]
    .sort((a, b) => sortOrderOf(a) - sortOrderOf(b))
    .map<RuleRow>((record) => {
      const sectionId = record.field_values['section_id']
      return {
        key: record.record_id,
        recordId: record.record_id,
        sectionKey: sectionId ? str(sectionId) : null,
        mode: str(record.field_values['mode']),
        category_id: str(record.field_values['category_id']),
        difficulty: str(record.field_values['difficulty']),
        count: str(record.field_values['count']),
        sort_order: str(record.field_values['sort_order']),
        dirty: false,
      }
    })
  return {
    examId,
    exam: {
      title: localizedFrom(fv['title']),
      description: localizedFrom(fv['description']),
      status: str(fv['status']),
      time_limit_minutes: str(fv['time_limit_minutes']),
      passing_score_pct: str(fv['passing_score_pct']),
      max_attempts: str(fv['max_attempts']),
      available_from: toInputDateTime(fv['available_from']),
      available_until: toInputDateTime(fv['available_until']),
      shuffle_questions: fv['shuffle_questions'] === true,
      shuffle_options: fv['shuffle_options'] === true,
      show_answers: str(fv['show_answers']),
      on_tab_switch: str(fv['on_tab_switch']),
      certificate_enabled: fv['certificate_enabled'] === true,
    },
    sections,
    rules,
    deletedSections: [],
    deletedRules: [],
  }
}

/** Rules grouped by the section they sit in (in section order), plus the rules in no loaded section. */
export function groupRules(state: BuilderState): {
  groups: { section: SectionRow; rules: RuleRow[] }[]
  unsectioned: RuleRow[]
} {
  const bySort = (a: RuleRow, b: RuleRow) => (Number(a.sort_order) || 0) - (Number(b.sort_order) || 0)
  const known = new Set(state.sections.map((s) => s.key))
  const groups = [...state.sections]
    .sort((a, b) => (Number(a.sort_order) || 0) - (Number(b.sort_order) || 0))
    .map((section) => ({
      section,
      rules: state.rules.filter((r) => r.sectionKey === section.key).sort(bySort),
    }))
  const unsectioned = state.rules.filter((r) => r.sectionKey === null || !known.has(r.sectionKey)).sort(bySort)
  return { groups, unsectioned }
}

// ── validation ──────────────────────────────────────────────────────────────────────────────

export interface FieldIssue {
  /** A message id of the exam catalog. */
  id: string
  values?: Record<string, number>
}

const INTEGER = /^-?\d+$/

function checkInt(raw: string, min: number): FieldIssue | null {
  if (raw.trim() === '') return { id: 'exam.builder.error.required' }
  if (!INTEGER.test(raw.trim()) || Number(raw) < min) {
    return { id: 'exam.builder.error.integerMin', values: { min } }
  }
  return null
}

function hasText(value: LocalizedInput): boolean {
  return BUILDER_LOCALES.some((locale) => value[locale].trim() !== '')
}

export const examKey = (field: string) => `exam.${field}`
export const sectionKey = (rowKey: string, field: string) => `section.${rowKey}.${field}`
export const ruleKey = (rowKey: string, field: string) => `rule.${rowKey}.${field}`

/** Errors keyed `exam.<field>`, `section.<rowKey>.<field>`, `rule.<rowKey>.<field>`; empty = valid. */
export function validate(state: BuilderState): Record<string, FieldIssue> {
  const errors: Record<string, FieldIssue> = {}
  const e = state.exam

  if (!hasText(e.title)) errors[examKey('title')] = { id: 'exam.builder.error.required' }
  const time = checkInt(e.time_limit_minutes, 1)
  if (time) errors[examKey('time_limit_minutes')] = time
  const attempts = checkInt(e.max_attempts, 1)
  if (attempts) errors[examKey('max_attempts')] = attempts
  if (e.passing_score_pct.trim() === '') {
    errors[examKey('passing_score_pct')] = { id: 'exam.builder.error.required' }
  } else {
    const pct = Number(e.passing_score_pct)
    if (!Number.isFinite(pct) || pct < 0 || pct > 100) {
      errors[examKey('passing_score_pct')] = { id: 'exam.builder.error.range', values: { min: 0, max: 100 } }
    }
  }
  if (!(EXAM_STATUSES as readonly string[]).includes(e.status)) errors[examKey('status')] = { id: 'exam.builder.error.required' }
  if (!(SHOW_ANSWERS as readonly string[]).includes(e.show_answers)) errors[examKey('show_answers')] = { id: 'exam.builder.error.required' }
  if (!(TAB_SWITCH as readonly string[]).includes(e.on_tab_switch)) errors[examKey('on_tab_switch')] = { id: 'exam.builder.error.required' }
  for (const field of ['available_from', 'available_until'] as const) {
    if (e[field] !== '' && Number.isNaN(Date.parse(`${e[field]}:00Z`))) {
      errors[examKey(field)] = { id: 'exam.builder.error.dateInvalid' }
    }
  }
  if (
    !errors[examKey('available_from')] &&
    !errors[examKey('available_until')] &&
    e.available_from !== '' &&
    e.available_until !== '' &&
    e.available_until <= e.available_from
  ) {
    errors[examKey('available_until')] = { id: 'exam.builder.error.untilBeforeFrom' }
  }

  const seenSection = new Map<string, string>()
  for (const s of state.sections) {
    const issue = checkInt(s.sort_order, 0)
    if (issue) {
      errors[sectionKey(s.key, 'sort_order')] = issue
      continue
    }
    const n = String(Number(s.sort_order))
    if (seenSection.has(n)) {
      errors[sectionKey(s.key, 'sort_order')] = { id: 'exam.builder.error.duplicateSort' }
    } else {
      seenSection.set(n, s.key)
    }
  }

  const seenRule = new Set<string>()
  for (const r of state.rules) {
    if (!(RULE_MODES as readonly string[]).includes(r.mode)) errors[ruleKey(r.key, 'mode')] = { id: 'exam.builder.error.required' }
    const count = checkInt(r.count, 1)
    if (count) errors[ruleKey(r.key, 'count')] = count
    const sort = checkInt(r.sort_order, 0)
    if (sort) {
      errors[ruleKey(r.key, 'sort_order')] = sort
    } else {
      const n = String(Number(r.sort_order))
      if (seenRule.has(n)) errors[ruleKey(r.key, 'sort_order')] = { id: 'exam.builder.error.duplicateSort' }
      else seenRule.add(n)
    }
  }
  return errors
}

// ── save plan ───────────────────────────────────────────────────────────────────────────────

export type RowKind = 'exam' | 'section' | 'rule'

export interface PlanStep {
  op: 'put' | 'post' | 'delete'
  entityType: 'exam' | 'exam_section' | 'exam_question_rule'
  rowKind: RowKind
  /** Row key (state `key`) for exam/section/rule rows; the record id for deletes. */
  rowKey: string
  recordId?: string
  /** Request body `field_values`; given the record ids known so far (row key -> record id). */
  body?: (ids: Record<string, string>) => Record<string, unknown>
}

function localizedBody(value: LocalizedInput): Record<string, string> {
  const out: Record<string, string> = {}
  for (const locale of BUILDER_LOCALES) {
    if (value[locale].trim() !== '') out[locale] = value[locale]
  }
  return out
}

export function examBody(exam: ExamForm): Record<string, unknown> {
  const body: Record<string, unknown> = {
    title: localizedBody(exam.title),
    status: exam.status,
    time_limit_minutes: Number(exam.time_limit_minutes),
    passing_score_pct: Number(exam.passing_score_pct),
    max_attempts: Number(exam.max_attempts),
    shuffle_questions: exam.shuffle_questions,
    shuffle_options: exam.shuffle_options,
    show_answers: exam.show_answers,
    on_tab_switch: exam.on_tab_switch,
    certificate_enabled: exam.certificate_enabled,
  }
  if (hasText(exam.description)) body['description'] = localizedBody(exam.description)
  if (exam.available_from !== '') body['available_from'] = new Date(`${exam.available_from}:00Z`).toISOString()
  if (exam.available_until !== '') body['available_until'] = new Date(`${exam.available_until}:00Z`).toISOString()
  return body
}

/** The calls of a save, in order: PUT exam; sections (new POST, changed PUT); rules likewise;
 *  then DELETE rules and DELETE sections (a rule names its section, so rules go first). */
export function buildSavePlan(state: BuilderState): PlanStep[] {
  const steps: PlanStep[] = []
  steps.push({
    op: 'put',
    entityType: 'exam',
    rowKind: 'exam',
    rowKey: state.examId,
    recordId: state.examId,
    body: () => examBody(state.exam),
  })

  const bySort = <T extends { sort_order: string }>(a: T, b: T) => Number(a.sort_order) - Number(b.sort_order)
  for (const s of [...state.sections].sort(bySort)) {
    if (s.recordId && !s.dirty) continue
    steps.push({
      op: s.recordId ? 'put' : 'post',
      entityType: 'exam_section',
      rowKind: 'section',
      rowKey: s.key,
      recordId: s.recordId,
      body: () => {
        const body: Record<string, unknown> = { exam_id: state.examId, sort_order: Number(s.sort_order) }
        const title = localizedBody(s.title)
        if (Object.keys(title).length > 0) body['title'] = title
        return body
      },
    })
  }
  for (const r of [...state.rules].sort(bySort)) {
    if (r.recordId && !r.dirty) continue
    steps.push({
      op: r.recordId ? 'put' : 'post',
      entityType: 'exam_question_rule',
      rowKind: 'rule',
      rowKey: r.key,
      recordId: r.recordId,
      body: (ids) => {
        const body: Record<string, unknown> = {
          exam_id: state.examId,
          mode: r.mode,
          count: Number(r.count),
          sort_order: Number(r.sort_order),
        }
        if (r.sectionKey !== null) body['section_id'] = ids[r.sectionKey] ?? r.sectionKey
        if (r.category_id.trim() !== '') body['category_id'] = r.category_id.trim()
        if (r.difficulty.trim() !== '') body['difficulty'] = r.difficulty.trim()
        return body
      },
    })
  }
  for (const id of state.deletedRules) {
    steps.push({ op: 'delete', entityType: 'exam_question_rule', rowKind: 'rule', rowKey: id, recordId: id })
  }
  for (const id of state.deletedSections) {
    steps.push({ op: 'delete', entityType: 'exam_section', rowKind: 'section', rowKey: id, recordId: id })
  }
  return steps
}

// ── API errors ──────────────────────────────────────────────────────────────────────────────

export interface ApiViolation {
  field: string | null
  message: string
}

export interface MappedApiError {
  status: number | undefined
  violations: ApiViolation[]
  message: string
}

/** Reads an `ApiError`. `details` is the `errors` list itself (the real client) or `{errors}`; a
 *  violation's `path` is an array of segments or a single string: the first segment names the field. */
export function errorsFromApiError(error: unknown): MappedApiError {
  const err = (error ?? {}) as { status?: unknown; message?: unknown; details?: unknown }
  const details = err.details
  const list: unknown = Array.isArray(details) ? details : (details as { errors?: unknown } | undefined)?.errors
  const violations: ApiViolation[] = []
  if (Array.isArray(list)) {
    for (const item of list) {
      const v = (item ?? {}) as { path?: unknown; field_path?: unknown; field?: unknown; message?: unknown }
      const path = v.path ?? v.field_path ?? v.field
      const first = Array.isArray(path) ? path[0] : path
      violations.push({
        field: typeof first === 'string' && first !== '' ? first : null,
        message: typeof v.message === 'string' ? v.message : '',
      })
    }
  }
  return {
    status: typeof err.status === 'number' ? err.status : undefined,
    violations,
    message: typeof err.message === 'string' ? err.message : '',
  }
}
