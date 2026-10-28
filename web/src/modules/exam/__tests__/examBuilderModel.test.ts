/**
 * GH 3355 / REQ-602 M1 — the pure model of the exam builder: loading, validation, the save plan and
 * the mapping of API errors.
 */
import { describe, expect, it } from 'vitest'
import type { EntityRecord } from '@/types/api'
import {
  buildSavePlan,
  errorsFromApiError,
  fromLoaded,
  groupRules,
  validate,
  type BuilderState,
} from '../examBuilderModel'

const record = (record_id: string, field_values: Record<string, unknown>): EntityRecord => ({
  record_id,
  field_values,
  deleted: false,
  entity_def_version: 'v1',
  last_event_global_seq: 1,
})

const EXAM = record('exam-1', {
  title: { en: 'Safety' },
  status: 'draft',
  time_limit_minutes: 60,
  passing_score_pct: '70.00',
  max_attempts: 2,
  shuffle_questions: false,
  shuffle_options: true,
  show_answers: 'never',
  on_tab_switch: 'log',
  certificate_enabled: false,
})

function loaded(): BuilderState {
  return fromLoaded('exam-1', {
    exam: EXAM,
    sections: [record('s2', { exam_id: 'exam-1', sort_order: 2 }), record('s1', { exam_id: 'exam-1', sort_order: 1 })],
    rules: [
      record('r1', { exam_id: 'exam-1', section_id: 's1', mode: 'random', count: 3, sort_order: 1 }),
      record('r2', { exam_id: 'exam-1', section_id: 'gone', mode: 'manual', count: 1, sort_order: 2 }),
    ],
  })
}

describe('M1 fromLoaded / groupRules', () => {
  it('sorts sections by sort_order and groups rules, unknown section id as unsectioned', () => {
    const state = loaded()
    expect(state.sections.map((s) => s.key)).toEqual(['s1', 's2'])
    expect(state.exam.passing_score_pct).toBe('70.00')
    const { groups, unsectioned } = groupRules(state)
    expect(groups.map((g) => [g.section.key, g.rules.map((r) => r.key)])).toEqual([
      ['s1', ['r1']],
      ['s2', []],
    ])
    expect(unsectioned.map((r) => r.key)).toEqual(['r2'])
  })
})

describe('M1 validate', () => {
  it('accepts the loaded state', () => {
    expect(validate(loaded())).toEqual({})
  })

  it('reports required, range and minimum failures per control key', () => {
    const state = loaded()
    state.exam.title = { kk: '', ru: ' ', en: '' }
    state.exam.passing_score_pct = '101'
    state.exam.max_attempts = '0'
    state.rules[0].count = '0'
    state.rules[1].sort_order = ''
    const errors = validate(state)
    expect(Object.keys(errors).sort()).toEqual(
      ['exam.max_attempts', 'exam.passing_score_pct', 'exam.title', 'rule.r1.count', 'rule.r2.sort_order'].sort(),
    )
    expect(errors['exam.passing_score_pct'].id).toBe('exam.builder.error.range')
  })

  it('flags a duplicate sort_order among sections and among rules', () => {
    const state = loaded()
    state.sections[1].sort_order = '1'
    state.rules[1].sort_order = '1'
    const errors = validate(state)
    expect(errors['section.s2.sort_order'].id).toBe('exam.builder.error.duplicateSort')
    expect(errors['rule.r2.sort_order'].id).toBe('exam.builder.error.duplicateSort')
  })

  it('flags an availability window that ends before it starts', () => {
    const state = loaded()
    state.exam.available_from = '2026-10-02T10:00'
    state.exam.available_until = '2026-10-01T10:00'
    expect(validate(state)['exam.available_until'].id).toBe('exam.builder.error.untilBeforeFrom')
  })
})

describe('M1 buildSavePlan', () => {
  it('sends only the exam when nothing else changed', () => {
    const plan = buildSavePlan(loaded())
    expect(plan.map((s) => `${s.op} ${s.entityType}`)).toEqual(['put exam'])
    expect(plan[0].body?.({})).toMatchObject({ title: { en: 'Safety' }, passing_score_pct: 70, max_attempts: 2 })
    expect(plan[0].body?.({})).not.toHaveProperty('exam_id')
  })

  it('orders exam, sections, rules, then rule deletes before section deletes', () => {
    const state = loaded()
    state.sections.push({ key: 'new-s1', title: { kk: '', ru: '', en: 'N' }, sort_order: '3', dirty: true })
    state.rules.push({
      key: 'new-r1', sectionKey: 'new-s1', mode: 'random', category_id: ' ', difficulty: '', count: '2', sort_order: '3', dirty: true,
    })
    state.deletedRules = ['rx']
    state.deletedSections = ['sx']
    const plan = buildSavePlan(state)
    expect(plan.map((s) => `${s.op} ${s.entityType}`)).toEqual([
      'put exam',
      'post exam_section',
      'post exam_question_rule',
      'delete exam_question_rule',
      'delete exam_section',
    ])
    const ruleBody = plan[2].body?.({ 'new-s1': 'fresh-id' })
    expect(ruleBody).toEqual({ exam_id: 'exam-1', mode: 'random', count: 2, sort_order: 3, section_id: 'fresh-id' })
  })
})

describe('M1 errorsFromApiError', () => {
  it('reads details as the list itself, with a path array or a path string', () => {
    const mapped = errorsFromApiError({
      status: 422,
      message: 'bad',
      details: [
        { code: 'x', path: ['count', 0], message: 'a' },
        { code: 'y', path: 'sort_order', message: 'b' },
        { code: 'z', message: 'c' },
      ],
    })
    expect(mapped.violations).toEqual([
      { field: 'count', message: 'a' },
      { field: 'sort_order', message: 'b' },
      { field: null, message: 'c' },
    ])
  })

  it('reads details as {errors: [...]}', () => {
    const mapped = errorsFromApiError({ status: 422, details: { errors: [{ path: ['title'], message: 'm' }] } })
    expect(mapped.violations).toEqual([{ field: 'title', message: 'm' }])
  })

  it('tolerates a non-ApiError', () => {
    expect(errorsFromApiError(new Error('x')).violations).toEqual([])
    expect(errorsFromApiError(undefined).status).toBeUndefined()
  })
})
