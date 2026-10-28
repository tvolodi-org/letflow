/** ExamBuilderPage — GH 3355 / REQ-602
 *
 *  One screen for one exam with its sections and question rules (route
 *  `/admin/bilimbaga/exam-builder/:examId`, behind ExamAuthoringWrite). Load is one query per entity
 *  type (examBuilderApi). Save runs the plan of examBuilderModel.buildSavePlan one call after the
 *  other through the exam authoring write routes: PUT exam, sections, rules, then deletes (rules
 *  first). It stops at the first rejected call and says which changes are saved and which are not;
 *  rows created before the failure carry their new record id, so a retry does not create them twice.
 *  Errors: 422 -> next to the control, 409 -> message with Reload, 403 -> message.
 */

import { useEffect, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl, type IntlShape } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { examAuthoringApi, examBuilderApi } from './exam.api'
import { EXAM_AUTHORING_WRITE } from './bilimbagaWrites'
import { ExamIntlProvider } from './ExamIntlProvider'
import { builderQueryKeys } from './builderQueryKeys'
import { CheckField, LocalizedField, Panel, SelectField, TextField } from './ExamBuilderFields'
import {
  EXAM_STATUSES,
  RULE_MODES,
  SHOW_ANSWERS,
  TAB_SWITCH,
  buildSavePlan,
  errorsFromApiError,
  examKey,
  fromLoaded,
  groupRules,
  ruleKey,
  sectionKey,
  validate,
  type BuilderState,
  type ExamForm,
  type FieldIssue,
  type LoadedRecords,
  type LocalizedInput,
  type PlanStep,
  type RuleRow,
  type SectionRow,
} from './examBuilderModel'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const LIST_PATH = '/admin/bilimbaga/exam-builder'

/** The fields that have a control, per row kind; a 422 about another field goes to the banner. */
const CONTROL_FIELDS: Record<PlanStep['rowKind'], readonly string[]> = {
  exam: [
    'title', 'description', 'status', 'time_limit_minutes', 'passing_score_pct', 'max_attempts',
    'available_from', 'available_until', 'shuffle_questions', 'shuffle_options', 'show_answers',
    'on_tab_switch', 'certificate_enabled',
  ],
  section: ['title', 'sort_order'],
  rule: ['mode', 'category_id', 'difficulty', 'count', 'sort_order'],
}

type StepStatus = 'done' | 'failed' | 'pending'
interface ResultItem {
  label: string
  status: StepStatus
}

function statusOf(error: unknown): number | undefined {
  const status = (error as { status?: unknown } | null)?.status
  return typeof status === 'number' ? status : undefined
}

function issueText(intl: IntlShape, issue: FieldIssue): string {
  return intl.formatMessage({ id: issue.id }, issue.values)
}

function nextOrder(values: string[]): string {
  const numbers = values.map(Number).filter((n) => Number.isFinite(n))
  return String(numbers.length === 0 ? 1 : Math.max(...numbers) + 1)
}

function enumOptions(intl: IntlShape, prefix: string, values: readonly string[]) {
  return values.map((value) => ({ value, label: intl.formatMessage({ id: `exam.builder.${prefix}.${value}` }) }))
}

function ExamBuilderPageInner() {
  const intl = useIntl()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const access = useAccess()
  const canWrite = access.can(EXAM_AUTHORING_WRITE)
  const { examId = '' } = useParams()
  const validId = UUID.test(examId)

  const query = useQuery({
    queryKey: builderQueryKeys.exam(tenantId, examId),
    queryFn: async (): Promise<{ exam: LoadedRecords['exam'] | undefined; sections: LoadedRecords['sections']; rules: LoadedRecords['rules'] }> => {
      const [exams, sections, rules] = await Promise.all([
        examBuilderApi.loadExam(examId),
        examBuilderApi.loadSections(examId),
        examBuilderApi.loadRules(examId),
      ])
      return { exam: exams[0], sections, rules }
    },
    enabled: validId,
    retry: false,
    refetchOnWindowFocus: false,
  })

  const [state, setState] = useState<BuilderState | null>(null)
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [banner, setBanner] = useState<{ kind: 'summary' | 'conflict' | 'forbidden' | 'generic' | 'text'; text?: string } | null>(null)
  const [result, setResult] = useState<ResultItem[] | null>(null)
  const [saved, setSaved] = useState(false)
  const [running, setRunning] = useState(false)
  const newCounter = useRef(0)
  const focusRequest = useRef(false)
  const formRef = useRef<HTMLDivElement>(null)

  // A fresh load (first, after Save, or Reload) replaces the draft.
  useEffect(() => {
    const data = query.data
    if (data?.exam) {
      setState(fromLoaded(examId, { exam: data.exam, sections: data.sections, rules: data.rules }))
      setErrors({})
      setBanner(null)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query.dataUpdatedAt])

  useEffect(() => {
    if (focusRequest.current) {
      focusRequest.current = false
      formRef.current?.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus()
    }
  }, [errors])

  const notFound =
    !validId || statusOf(query.error) === 404 || (query.isSuccess && query.data.exam === undefined)
  if (notFound) {
    return (
      <div data-testid="exam-builder-not-found">
        <PageLayout title={intl.formatMessage({ id: 'exam.builder.title' })}>
          <p>{intl.formatMessage({ id: 'exam.builder.notFound' })}</p>
          <Link to={LIST_PATH}>{intl.formatMessage({ id: 'exam.builder.back' })}</Link>
        </PageLayout>
      </div>
    )
  }

  const boundaryState = (
    query.isLoading || (query.isSuccess && state === null)
      ? 'loading'
      : query.isError
        ? classifyError(query.error)
        : 'success'
  ) as RendererState

  function update(fn: (draft: BuilderState) => BuilderState) {
    setState((current) => (current ? fn(current) : current))
    setSaved(false)
  }

  function setExamField<K extends keyof ExamForm>(field: K, value: ExamForm[K]) {
    update((s) => ({ ...s, exam: { ...s.exam, [field]: value } }))
  }

  function addSection() {
    update((s) => ({
      ...s,
      sections: [
        ...s.sections,
        {
          key: `new-s${++newCounter.current}`,
          title: { kk: '', ru: '', en: '' },
          sort_order: nextOrder(s.sections.map((x) => x.sort_order)),
          dirty: true,
        },
      ],
    }))
  }

  function patchSection(key: string, patch: Partial<SectionRow>) {
    update((s) => ({ ...s, sections: s.sections.map((x) => (x.key === key ? { ...x, ...patch, dirty: true } : x)) }))
  }

  function removeSection(key: string) {
    update((s) => {
      const section = s.sections.find((x) => x.key === key)
      const dropped = s.rules.filter((r) => r.sectionKey === key)
      return {
        ...s,
        sections: s.sections.filter((x) => x.key !== key),
        rules: s.rules.filter((r) => r.sectionKey !== key),
        deletedSections: section?.recordId ? [...s.deletedSections, section.recordId] : s.deletedSections,
        deletedRules: [...s.deletedRules, ...dropped.flatMap((r) => (r.recordId ? [r.recordId] : []))],
      }
    })
  }

  function addRule(sectionKeyOrNull: string | null) {
    update((s) => ({
      ...s,
      rules: [
        ...s.rules,
        {
          key: `new-r${++newCounter.current}`,
          sectionKey: sectionKeyOrNull,
          mode: 'random',
          category_id: '',
          difficulty: '',
          count: '1',
          sort_order: nextOrder(s.rules.map((x) => x.sort_order)),
          dirty: true,
        },
      ],
    }))
  }

  function patchRule(key: string, patch: Partial<RuleRow>) {
    update((s) => ({ ...s, rules: s.rules.map((x) => (x.key === key ? { ...x, ...patch, dirty: true } : x)) }))
  }

  function removeRule(key: string) {
    update((s) => {
      const rule = s.rules.find((x) => x.key === key)
      return {
        ...s,
        rules: s.rules.filter((x) => x.key !== key),
        deletedRules: rule?.recordId ? [...s.deletedRules, rule.recordId] : s.deletedRules,
      }
    })
  }

  function stepLabel(step: PlanStep, draft: BuilderState): string {
    if (step.rowKind === 'exam') return intl.formatMessage({ id: 'exam.builder.result.exam' })
    const id = step.rowKind === 'section' ? 'exam.builder.result.section' : 'exam.builder.result.rule'
    if (step.op === 'delete') {
      const what = intl.formatMessage({ id }, { n: step.rowKey.slice(0, 8) })
      return intl.formatMessage({ id: 'exam.builder.result.delete' }, { what })
    }
    const rows = step.rowKind === 'section' ? draft.sections : draft.rules
    return intl.formatMessage({ id }, { n: rows.findIndex((r) => r.key === step.rowKey) + 1 })
  }

  function failureBanner(step: PlanStep, error: unknown, next: Record<string, string>) {
    const mapped = errorsFromApiError(error)
    if (mapped.status === 409) return setBanner({ kind: 'conflict' })
    if (mapped.status === 403) return setBanner({ kind: 'forbidden' })
    if (mapped.status === 422 && mapped.violations.length > 0) {
      const unmatched: string[] = []
      for (const violation of mapped.violations) {
        const field = violation.field
        if (step.op !== 'delete' && field !== null && CONTROL_FIELDS[step.rowKind].includes(field)) {
          const key =
            step.rowKind === 'exam'
              ? examKey(field)
              : step.rowKind === 'section'
                ? sectionKey(step.rowKey, field)
                : ruleKey(step.rowKey, field)
          next[key] = violation.message || intl.formatMessage({ id: 'exam.builder.error.generic' })
        } else if (violation.message) {
          unmatched.push(violation.message)
        }
      }
      return unmatched.length > 0 ? setBanner({ kind: 'text', text: unmatched.join(' ') }) : setBanner(null)
    }
    return setBanner({ kind: 'generic' })
  }

  async function save() {
    if (!state || running || !canWrite) return
    setBanner(null)
    setResult(null)
    setSaved(false)
    const issues = validate(state)
    const formatted: Record<string, string> = {}
    for (const [key, issue] of Object.entries(issues)) formatted[key] = issueText(intl, issue)
    if (Object.keys(formatted).length > 0) {
      focusRequest.current = true
      setErrors(formatted)
      setBanner({ kind: 'summary' })
      return
    }
    setErrors({})
    setRunning(true)

    const draft = state
    const plan = buildSavePlan(draft)
    const ids: Record<string, string> = {}
    for (const s of draft.sections) if (s.recordId) ids[s.key] = s.recordId
    const log: ResultItem[] = plan.map((step) => ({ label: stepLabel(step, draft), status: 'pending' }))
    let failed = false

    for (let i = 0; i < plan.length; i++) {
      const step = plan[i]
      try {
        if (step.op === 'delete') {
          await examAuthoringApi.deleteRecord(step.entityType, step.recordId as string)
          setState((s) =>
            s
              ? step.rowKind === 'rule'
                ? { ...s, deletedRules: s.deletedRules.filter((id) => id !== step.recordId) }
                : { ...s, deletedSections: s.deletedSections.filter((id) => id !== step.recordId) }
              : s,
          )
        } else if (step.op === 'put') {
          await examAuthoringApi.updateRecord(step.entityType, step.recordId as string, (step.body as NonNullable<PlanStep['body']>)(ids))
          if (step.rowKind === 'section') {
            setState((s) => s && { ...s, sections: s.sections.map((x) => (x.key === step.rowKey ? { ...x, dirty: false } : x)) })
          } else if (step.rowKind === 'rule') {
            setState((s) => s && { ...s, rules: s.rules.map((x) => (x.key === step.rowKey ? { ...x, dirty: false } : x)) })
          }
        } else {
          const created = await examAuthoringApi.createRecord(step.entityType, (step.body as NonNullable<PlanStep['body']>)(ids))
          const recordId = created.record_id
          if (step.rowKind === 'section') {
            ids[step.rowKey] = recordId
            setState((s) => s && { ...s, sections: s.sections.map((x) => (x.key === step.rowKey ? { ...x, recordId, dirty: false } : x)) })
          } else {
            setState((s) => s && { ...s, rules: s.rules.map((x) => (x.key === step.rowKey ? { ...x, recordId, dirty: false } : x)) })
          }
        }
        log[i].status = 'done'
      } catch (error) {
        log[i].status = 'failed'
        const next: Record<string, string> = {}
        failureBanner(step, error, next)
        setErrors(next)
        failed = true
        break
      }
    }

    setResult([...log])
    setRunning(false)
    if (!failed) {
      setSaved(true)
      await query.refetch()
      setSaved(true)
    }
  }

  const readOnly = !canWrite
  const grouped = state ? groupRules(state) : null
  const err = (key: string) => errors[key]

  return (
    <div data-testid="exam-builder-page" ref={formRef}>
      <PageLayout title={intl.formatMessage({ id: 'exam.builder.title' })}>
        <p>
          <Link to={LIST_PATH}>{intl.formatMessage({ id: 'exam.builder.back' })}</Link>
        </p>
        <QueryStateBoundary
          state={boundaryState}
          onRetry={() => {
            void query.refetch()
          }}
        >
          {state && grouped && (
            <form
              onSubmit={(event) => {
                event.preventDefault()
                void save()
              }}
              noValidate
            >
              {readOnly && <p data-testid="exam-builder-read-only">{intl.formatMessage({ id: 'exam.builder.readOnly' })}</p>}
              <fieldset disabled={readOnly || running} style={{ border: 'none', padding: 0, margin: 0 }}>
                <Panel testId="exam-builder-exam" heading={intl.formatMessage({ id: 'exam.builder.group.exam' })}>
                  <LocalizedField
                    id="eb-exam-title"
                    testId="exam-builder-exam-title"
                    label={intl.formatMessage({ id: 'exam.builder.field.title' })}
                    value={state.exam.title}
                    error={err(examKey('title'))}
                    onChange={(locale, text) => setExamField('title', { ...state.exam.title, [locale]: text } as LocalizedInput)}
                  />
                  <LocalizedField
                    id="eb-exam-description"
                    testId="exam-builder-exam-description"
                    label={intl.formatMessage({ id: 'exam.builder.field.description' })}
                    value={state.exam.description}
                    error={err(examKey('description'))}
                    onChange={(locale, text) => setExamField('description', { ...state.exam.description, [locale]: text } as LocalizedInput)}
                  />
                  <SelectField
                    id="eb-exam-status"
                    testId="exam-builder-exam-status"
                    label={intl.formatMessage({ id: 'exam.builder.field.status' })}
                    value={state.exam.status}
                    options={enumOptions(intl, 'status', EXAM_STATUSES)}
                    placeholder={intl.formatMessage({ id: 'exam.builder.choose' })}
                    error={err(examKey('status'))}
                    onChange={(v) => setExamField('status', v)}
                  />
                  <TextField
                    id="eb-exam-time"
                    testId="exam-builder-exam-time_limit_minutes"
                    label={intl.formatMessage({ id: 'exam.builder.field.time_limit_minutes' })}
                    value={state.exam.time_limit_minutes}
                    error={err(examKey('time_limit_minutes'))}
                    onChange={(v) => setExamField('time_limit_minutes', v)}
                  />
                  <TextField
                    id="eb-exam-pass"
                    testId="exam-builder-exam-passing_score_pct"
                    label={intl.formatMessage({ id: 'exam.builder.field.passing_score_pct' })}
                    value={state.exam.passing_score_pct}
                    error={err(examKey('passing_score_pct'))}
                    onChange={(v) => setExamField('passing_score_pct', v)}
                  />
                  <TextField
                    id="eb-exam-attempts"
                    testId="exam-builder-exam-max_attempts"
                    label={intl.formatMessage({ id: 'exam.builder.field.max_attempts' })}
                    value={state.exam.max_attempts}
                    error={err(examKey('max_attempts'))}
                    onChange={(v) => setExamField('max_attempts', v)}
                  />
                  <TextField
                    id="eb-exam-from"
                    testId="exam-builder-exam-available_from"
                    type="datetime-local"
                    label={intl.formatMessage({ id: 'exam.builder.field.available_from' })}
                    value={state.exam.available_from}
                    error={err(examKey('available_from'))}
                    onChange={(v) => setExamField('available_from', v)}
                  />
                  <TextField
                    id="eb-exam-until"
                    testId="exam-builder-exam-available_until"
                    type="datetime-local"
                    label={intl.formatMessage({ id: 'exam.builder.field.available_until' })}
                    value={state.exam.available_until}
                    error={err(examKey('available_until'))}
                    onChange={(v) => setExamField('available_until', v)}
                  />
                  <SelectField
                    id="eb-exam-show"
                    testId="exam-builder-exam-show_answers"
                    label={intl.formatMessage({ id: 'exam.builder.field.show_answers' })}
                    value={state.exam.show_answers}
                    options={enumOptions(intl, 'showAnswers', SHOW_ANSWERS)}
                    placeholder={intl.formatMessage({ id: 'exam.builder.choose' })}
                    error={err(examKey('show_answers'))}
                    onChange={(v) => setExamField('show_answers', v)}
                  />
                  <SelectField
                    id="eb-exam-tab"
                    testId="exam-builder-exam-on_tab_switch"
                    label={intl.formatMessage({ id: 'exam.builder.field.on_tab_switch' })}
                    value={state.exam.on_tab_switch}
                    options={enumOptions(intl, 'tabSwitch', TAB_SWITCH)}
                    placeholder={intl.formatMessage({ id: 'exam.builder.choose' })}
                    error={err(examKey('on_tab_switch'))}
                    onChange={(v) => setExamField('on_tab_switch', v)}
                  />
                  <CheckField
                    id="eb-exam-shuffle-q"
                    testId="exam-builder-exam-shuffle_questions"
                    label={intl.formatMessage({ id: 'exam.builder.field.shuffle_questions' })}
                    checked={state.exam.shuffle_questions}
                    onChange={(v) => setExamField('shuffle_questions', v)}
                  />
                  <CheckField
                    id="eb-exam-shuffle-o"
                    testId="exam-builder-exam-shuffle_options"
                    label={intl.formatMessage({ id: 'exam.builder.field.shuffle_options' })}
                    checked={state.exam.shuffle_options}
                    onChange={(v) => setExamField('shuffle_options', v)}
                  />
                  <CheckField
                    id="eb-exam-cert"
                    testId="exam-builder-exam-certificate_enabled"
                    label={intl.formatMessage({ id: 'exam.builder.field.certificate_enabled' })}
                    checked={state.exam.certificate_enabled}
                    onChange={(v) => setExamField('certificate_enabled', v)}
                  />
                </Panel>

                <h2>{intl.formatMessage({ id: 'exam.builder.group.sections' })}</h2>
                {grouped.groups.map(({ section, rules }, index) => (
                  <Panel
                    key={section.key}
                    testId={`exam-builder-section-${section.key}`}
                    heading={intl.formatMessage({ id: 'exam.builder.section.heading' }, { n: index + 1 })}
                  >
                    <LocalizedField
                      id={`eb-s-${section.key}-title`}
                      testId={`exam-builder-section-${section.key}-title`}
                      label={intl.formatMessage({ id: 'exam.builder.field.title' })}
                      value={section.title}
                      error={err(sectionKey(section.key, 'title'))}
                      onChange={(locale, text) => patchSection(section.key, { title: { ...section.title, [locale]: text } })}
                    />
                    <TextField
                      id={`eb-s-${section.key}-sort`}
                      testId={`exam-builder-section-${section.key}-sort_order`}
                      label={intl.formatMessage({ id: 'exam.builder.field.sort_order' })}
                      value={section.sort_order}
                      error={err(sectionKey(section.key, 'sort_order'))}
                      onChange={(v) => patchSection(section.key, { sort_order: v })}
                    />
                    {rules.map((rule, ruleIndex) => (
                      <RuleEditor
                        key={rule.key}
                        rule={rule}
                        number={ruleIndex + 1}
                        errors={errors}
                        onPatch={(patch) => patchRule(rule.key, patch)}
                        onRemove={() => removeRule(rule.key)}
                      />
                    ))}
                    <div style={{ display: 'flex', gap: 'var(--space-2)', alignItems: 'center' }}>
                      <Button variant="secondary" size="sm" data-testid={`exam-builder-section-${section.key}-add-rule`} onClick={() => addRule(section.key)}>
                        {intl.formatMessage({ id: 'exam.builder.rule.add' })}
                      </Button>
                      <Button variant="danger" size="sm" data-testid={`exam-builder-section-${section.key}-remove`} onClick={() => removeSection(section.key)}>
                        {intl.formatMessage({ id: 'exam.builder.section.remove' })}
                      </Button>
                      {rules.length > 0 && (
                        <span>{intl.formatMessage({ id: 'exam.builder.section.removesRules' }, { count: rules.length })}</span>
                      )}
                    </div>
                  </Panel>
                ))}

                <Panel testId="exam-builder-group-unsectioned" heading={intl.formatMessage({ id: 'exam.builder.group.unsectioned' })}>
                  {grouped.unsectioned.map((rule, ruleIndex) => (
                    <RuleEditor
                      key={rule.key}
                      rule={rule}
                      number={ruleIndex + 1}
                      errors={errors}
                      onPatch={(patch) => patchRule(rule.key, patch)}
                      onRemove={() => removeRule(rule.key)}
                    />
                  ))}
                  <div>
                    <Button variant="secondary" size="sm" data-testid="exam-builder-add-rule-unsectioned" onClick={() => addRule(null)}>
                      {intl.formatMessage({ id: 'exam.builder.rule.add' })}
                    </Button>
                  </div>
                </Panel>

                <div>
                  <Button variant="secondary" size="md" data-testid="exam-builder-add-section" onClick={addSection}>
                    {intl.formatMessage({ id: 'exam.builder.section.add' })}
                  </Button>
                </div>
              </fieldset>

              <div style={{ marginTop: 'var(--space-4)', display: 'grid', gap: 'var(--space-2)' }}>
                {banner && (
                  <div role="alert" data-testid="exam-builder-banner" style={{ color: 'var(--interactive-danger)' }}>
                    {banner.kind === 'summary' && intl.formatMessage({ id: 'exam.builder.error.summary' })}
                    {banner.kind === 'conflict' && intl.formatMessage({ id: 'exam.builder.error.conflict' })}
                    {banner.kind === 'forbidden' && intl.formatMessage({ id: 'exam.builder.error.forbidden' })}
                    {banner.kind === 'generic' && intl.formatMessage({ id: 'exam.builder.error.generic' })}
                    {banner.kind === 'text' && banner.text}
                    {banner.kind === 'conflict' && (
                      <Button
                        variant="secondary"
                        size="sm"
                        data-testid="exam-builder-reload"
                        onClick={() => {
                          void query.refetch()
                        }}
                      >
                        {intl.formatMessage({ id: 'exam.builder.reload' })}
                      </Button>
                    )}
                  </div>
                )}
                {saved && <p role="status" data-testid="exam-builder-saved">{intl.formatMessage({ id: 'exam.builder.saved' })}</p>}
                {result && (
                  <section data-testid="exam-builder-save-result" aria-label={intl.formatMessage({ id: 'exam.builder.result.heading' })}>
                    <ul>
                      {result.map((item, index) => (
                        <li key={index} data-testid="exam-builder-save-result-item" data-status={item.status}>
                          {item.label}: {intl.formatMessage({ id: `exam.builder.result.${item.status === 'done' ? 'done' : item.status === 'failed' ? 'failed' : 'pending'}` })}
                        </li>
                      ))}
                    </ul>
                  </section>
                )}
                {!readOnly && (
                  <div>
                    <Button variant="primary" size="md" loading={running} disabled={running} data-testid="exam-builder-save" onClick={() => void save()}>
                      {intl.formatMessage({ id: running ? 'exam.builder.saving' : 'exam.builder.save' })}
                    </Button>
                  </div>
                )}
              </div>
            </form>
          )}
        </QueryStateBoundary>
      </PageLayout>
    </div>
  )
}

function RuleEditor(props: {
  rule: RuleRow
  number: number
  errors: Record<string, string>
  onPatch: (patch: Partial<RuleRow>) => void
  onRemove: () => void
}) {
  const intl = useIntl()
  const { rule, number, errors, onPatch, onRemove } = props
  const base = `exam-builder-rule-${rule.key}`
  return (
    <div
      data-testid={base}
      style={{ border: '1px dashed var(--border-default)', borderRadius: 'var(--radius-md)', padding: 'var(--space-3)', display: 'grid', gap: 'var(--space-2)' }}
    >
      <strong>{intl.formatMessage({ id: 'exam.builder.rule.heading' }, { n: number })}</strong>
      <SelectField
        id={`eb-r-${rule.key}-mode`}
        testId={`${base}-mode`}
        label={intl.formatMessage({ id: 'exam.builder.field.mode' })}
        value={rule.mode}
        options={enumOptions(intl, 'mode', RULE_MODES)}
        placeholder={intl.formatMessage({ id: 'exam.builder.choose' })}
        error={errors[ruleKey(rule.key, 'mode')]}
        onChange={(v) => onPatch({ mode: v })}
      />
      <TextField
        id={`eb-r-${rule.key}-category`}
        testId={`${base}-category_id`}
        label={intl.formatMessage({ id: 'exam.builder.field.category_id' })}
        value={rule.category_id}
        error={errors[ruleKey(rule.key, 'category_id')]}
        onChange={(v) => onPatch({ category_id: v })}
      />
      <TextField
        id={`eb-r-${rule.key}-difficulty`}
        testId={`${base}-difficulty`}
        label={intl.formatMessage({ id: 'exam.builder.field.difficulty' })}
        value={rule.difficulty}
        error={errors[ruleKey(rule.key, 'difficulty')]}
        onChange={(v) => onPatch({ difficulty: v })}
      />
      <TextField
        id={`eb-r-${rule.key}-count`}
        testId={`${base}-count`}
        label={intl.formatMessage({ id: 'exam.builder.field.count' })}
        value={rule.count}
        error={errors[ruleKey(rule.key, 'count')]}
        onChange={(v) => onPatch({ count: v })}
      />
      <TextField
        id={`eb-r-${rule.key}-sort`}
        testId={`${base}-sort_order`}
        label={intl.formatMessage({ id: 'exam.builder.field.sort_order' })}
        value={rule.sort_order}
        error={errors[ruleKey(rule.key, 'sort_order')]}
        onChange={(v) => onPatch({ sort_order: v })}
      />
      <div>
        <Button variant="danger" size="sm" data-testid={`${base}-remove`} onClick={onRemove}>
          {intl.formatMessage({ id: 'exam.builder.rule.remove' })}
        </Button>
      </div>
    </div>
  )
}

export default function ExamBuilderPage() {
  return (
    <ExamIntlProvider>
      <ExamBuilderPageInner />
    </ExamIntlProvider>
  )
}
