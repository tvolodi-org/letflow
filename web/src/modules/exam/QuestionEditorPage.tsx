/** QuestionEditorPage — GH 3423 / REQ-612
 *
 *  Create (`/admin/questions/new`) and edit (`/admin/questions/:recordId/edit`) one question with its
 *  answer options. Create posts the question, then one answer option per row, then opens the edit
 *  route of the new record. Edit loads the question and its options (soft-deleted rows excluded),
 *  and saves a whole-document PUT with the loaded values of the fields the page does not edit and
 *  `expected_last_event_global_seq`, then the option creates, updates and deletes. The page shows
 *  Save Draft only for a holder of ExamAuthoringWrite. Short text questions have no option rows
 *  (assumption A1: an examiner grades the answer, shown as a fixed notice). No AI action.
 */

import { useEffect, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { useAuth } from '@/auth/AuthContext'
import { useAccess } from '@/auth/access'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { examAuthoringApi, examQuestionApi } from './exam.api'
import { EXAM_AUTHORING_WRITE } from './bilimbagaWrites'
import { ExamIntlProvider } from './ExamIntlProvider'
import { questionQueryKeys } from './builderQueryKeys'
import type { ExamUiLocale } from './examMessages'
import {
  DIFFICULTIES,
  MAX_OPTIONS,
  MIN_OPTIONS,
  POLARITIES,
  QUESTION_TYPES,
  blankOption,
  buildOptionFields,
  buildQuestionFields,
  emptyDraft,
  localizedText,
  optionRowsForType,
  optionsFromRecords,
  planOptionWrites,
  saveErrorKind,
  validateDraft,
  type Difficulty,
  type EditorDraft,
  type OptionDraft,
  type Polarity,
  type QuestionType,
  type RefusalId,
} from './questionEditorModel'

const labelStyle = { display: 'block', fontSize: 'var(--text-sm)', color: 'var(--text-secondary)' } as const
const controlStyle = {
  display: 'block',
  padding: 'var(--space-1) var(--space-2)',
  border: '1px solid var(--border-default)',
  borderRadius: 'var(--radius-md)',
  background: 'var(--surface-card)',
  color: 'var(--text-primary)',
} as const

const BANK_PATH = '/admin/questions'

function statusOf(error: unknown): number | undefined {
  const status = (error as { status?: unknown } | null)?.status
  return typeof status === 'number' ? status : undefined
}

function QuestionEditorPageInner() {
  const intl = useIntl()
  const locale = intl.locale as ExamUiLocale
  const navigate = useNavigate()
  const { session } = useAuth()
  const tenantId = session?.tenant_id ?? ''
  const canWrite = useAccess().can(EXAM_AUTHORING_WRITE)
  const { recordId } = useParams()
  const editing = recordId !== undefined

  const [draft, setDraft] = useState<EditorDraft>(emptyDraft)
  const [refusals, setRefusals] = useState<RefusalId[]>([])
  const [errorKind, setErrorKind] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)

  const categories = useQuery({
    queryKey: questionQueryKeys.categories(tenantId),
    queryFn: () => examQuestionApi.loadCategories(),
    retry: false,
    refetchOnWindowFocus: false,
  })

  const loadQuery = useQuery({
    queryKey: questionQueryKeys.edit(tenantId, recordId ?? ''),
    queryFn: async () => {
      const questions = await examQuestionApi.loadQuestion(recordId as string)
      const question = questions[0]
      const options = question ? await examQuestionApi.loadOptions(recordId as string) : []
      return { question, options }
    },
    enabled: editing,
    retry: false,
    refetchOnWindowFocus: false,
  })

  const loadedQuestion = loadQuery.data?.question
  const loadedOptions = loadQuery.data?.options ?? []

  // A fresh load (first, or after Save) replaces the draft.
  useEffect(() => {
    const data = loadQuery.data
    if (!data?.question) return
    const fields = data.question.field_values
    const type = QUESTION_TYPES.find((t) => t === fields['type']) ?? 'single'
    const difficulty = DIFFICULTIES.find((d) => d === fields['difficulty']) ?? 'medium'
    setDraft({
      stem: localizedText(fields['stem'], locale),
      type,
      difficulty,
      categoryId: typeof fields['category_id'] === 'string' ? fields['category_id'] : '',
      options: optionsFromRecords(data.options, locale),
    })
    setRefusals([])
    setErrorKind(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loadQuery.dataUpdatedAt])

  const notFound =
    editing && (statusOf(loadQuery.error) !== undefined || (loadQuery.isSuccess && loadedQuestion === undefined))
  if (notFound) {
    return (
      <div data-testid="question-editor-not-found">
        <PageLayout title={intl.formatMessage({ id: 'exam.question.editor.titleEdit' })}>
          <p>{intl.formatMessage({ id: 'exam.question.editor.notFound' })}</p>
          <Link to={BANK_PATH}>{intl.formatMessage({ id: 'exam.question.editor.back' })}</Link>
        </PageLayout>
      </div>
    )
  }

  function update(patch: Partial<EditorDraft>) {
    setDraft((d) => ({ ...d, ...patch }))
    setSaved(false)
  }

  function changeType(type: QuestionType) {
    update({ type, options: optionRowsForType(type) })
  }

  function updateOption(key: string, patch: Partial<OptionDraft>) {
    setDraft((d) => ({ ...d, options: d.options.map((o) => (o.key === key ? { ...o, ...patch } : o)) }))
    setSaved(false)
  }

  function setCorrect(key: string, checked: boolean) {
    setDraft((d) => ({
      ...d,
      options: d.options.map((o) =>
        d.type === 'multiple' ? (o.key === key ? { ...o, isCorrect: checked } : o) : { ...o, isCorrect: o.key === key },
      ),
    }))
    setSaved(false)
  }

  const words = {
    true: intl.formatMessage({ id: 'exam.question.true' }),
    false: intl.formatMessage({ id: 'exam.question.false' }),
  }

  async function save() {
    if (saving || !canWrite) return
    const issues = validateDraft(draft)
    setRefusals(issues)
    setErrorKind(null)
    setSaved(false)
    if (issues.length > 0) return
    setSaving(true)
    try {
      if (!editing) {
        const created = await examAuthoringApi.createRecord('question', buildQuestionFields(draft, locale))
        try {
          for (const [index, option] of draft.options.entries()) {
            await examAuthoringApi.createRecord(
              'answer_option',
              buildOptionFields(option, index, created.record_id, draft.type, locale, words),
            )
          }
        } catch (error) {
          // The question exists: open it for edit so a retry does not create it twice.
          setErrorKind(saveErrorKind(error))
          navigate(`${BANK_PATH}/${encodeURIComponent(created.record_id)}/edit`)
          return
        }
        navigate(`${BANK_PATH}/${encodeURIComponent(created.record_id)}/edit`)
        return
      }
      if (!loadedQuestion) return
      const typeChanged = loadedQuestion.field_values['type'] !== draft.type
      await examAuthoringApi.updateRecord(
        'question',
        loadedQuestion.record_id,
        buildQuestionFields(draft, locale, loadedQuestion.field_values),
        undefined,
        loadedQuestion.last_event_global_seq,
      )
      const plan = planOptionWrites(loadedOptions, draft.options, typeChanged)
      for (const id of plan.deletes) await examAuthoringApi.deleteRecord('answer_option', id)
      for (const { index, option } of plan.updates) {
        await examAuthoringApi.updateRecord(
          'answer_option',
          option.recordId as string,
          buildOptionFields(option, index, loadedQuestion.record_id, draft.type, locale, words),
        )
      }
      for (const { index, option } of plan.creates) {
        await examAuthoringApi.createRecord(
          'answer_option',
          buildOptionFields(option, index, loadedQuestion.record_id, draft.type, locale, words),
        )
      }
      setSaved(true)
      await loadQuery.refetch()
    } catch (error) {
      setErrorKind(saveErrorKind(error))
    } finally {
      setSaving(false)
    }
  }

  const categoryOptions = (categories.data ?? []).map((record) => ({
    value: record.record_id,
    label: localizedText(record.field_values['name'], locale) || record.record_id,
  }))
  const showRows = draft.type !== 'shorttext'
  const canAdd = draft.type !== 'truefalse' && draft.options.length < MAX_OPTIONS
  const canRemove = draft.type !== 'truefalse' && draft.options.length > MIN_OPTIONS

  const body = (
    <div data-testid="question-editor-page">
      {!canWrite && (
        <p data-testid="question-editor-readonly">{intl.formatMessage({ id: 'exam.question.editor.readOnly' })}</p>
      )}
      <fieldset disabled={!canWrite || saving} style={{ border: 'none', padding: 0 }}>
        <div>
          <label htmlFor="question-stem" style={labelStyle}>
            {intl.formatMessage({ id: 'exam.question.field.stem' })}
          </label>
          <textarea
            id="question-stem"
            data-testid="question-stem"
            rows={4}
            value={draft.stem}
            placeholder={intl.formatMessage({ id: 'exam.question.stem.placeholder' })}
            onChange={(event) => update({ stem: event.target.value })}
            style={controlStyle}
          />
        </div>
        <div>
          <label htmlFor="question-type" style={labelStyle}>
            {intl.formatMessage({ id: 'exam.question.field.type' })}
          </label>
          <select
            id="question-type"
            data-testid="question-type"
            value={draft.type}
            onChange={(event) => changeType(event.target.value as QuestionType)}
            style={controlStyle}
          >
            {QUESTION_TYPES.map((type) => (
              <option key={type} value={type}>
                {intl.formatMessage({ id: `exam.question.type.${type}` })}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label htmlFor="question-difficulty" style={labelStyle}>
            {intl.formatMessage({ id: 'exam.question.field.difficulty' })}
          </label>
          <select
            id="question-difficulty"
            data-testid="question-difficulty"
            value={draft.difficulty}
            onChange={(event) => update({ difficulty: event.target.value as Difficulty })}
            style={controlStyle}
          >
            {DIFFICULTIES.map((difficulty) => (
              <option key={difficulty} value={difficulty}>
                {intl.formatMessage({ id: `exam.question.difficulty.${difficulty}` })}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label htmlFor="question-category" style={labelStyle}>
            {intl.formatMessage({ id: 'exam.question.field.category' })}
          </label>
          <select
            id="question-category"
            data-testid="question-category"
            value={draft.categoryId}
            onChange={(event) => update({ categoryId: event.target.value })}
            style={controlStyle}
          >
            <option value="">{intl.formatMessage({ id: 'exam.question.category.placeholder' })}</option>
            {categoryOptions.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
        </div>

        <h3>{intl.formatMessage({ id: 'exam.question.options.title' })}</h3>
        {!showRows && (
          <p data-testid="question-shorttext-notice">{intl.formatMessage({ id: 'exam.question.shortTextNotice' })}</p>
        )}
        {showRows && (
          <ol data-testid="question-options" style={{ listStyle: 'none', padding: 0 }}>
            {draft.options.map((option, index) => (
              <li key={option.key} data-testid={`question-option-${index}`} style={{ marginBottom: 'var(--space-2)' }}>
                {draft.type === 'truefalse' ? (
                  <span data-testid={`question-option-word-${index}`}>{index === 0 ? words.true : words.false}</span>
                ) : (
                  <input
                    type="text"
                    data-testid={`question-option-text-${index}`}
                    aria-label={`${intl.formatMessage({ id: 'exam.question.option.text' })} ${index + 1}`}
                    value={option.text}
                    onChange={(event) => updateOption(option.key, { text: event.target.value })}
                    style={controlStyle}
                  />
                )}
                {draft.type === 'single' || draft.type === 'truefalse' ? (
                  <label>
                    <input
                      type="radio"
                      name="question-correct"
                      data-testid={`question-option-correct-${index}`}
                      checked={option.isCorrect}
                      onChange={() => setCorrect(option.key, true)}
                    />{' '}
                    {intl.formatMessage({ id: 'exam.question.option.correct' })}
                  </label>
                ) : null}
                {draft.type === 'multiple' && (
                  <label>
                    <input
                      type="checkbox"
                      data-testid={`question-option-correct-${index}`}
                      checked={option.isCorrect}
                      onChange={(event) => setCorrect(option.key, event.target.checked)}
                    />{' '}
                    {intl.formatMessage({ id: 'exam.question.option.correct' })}
                  </label>
                )}
                {draft.type === 'likert' && (
                  <>
                    <label>
                      {intl.formatMessage({ id: 'exam.question.option.polarity' })}{' '}
                      <select
                        data-testid={`question-option-polarity-${index}`}
                        value={option.polarity}
                        onChange={(event) => updateOption(option.key, { polarity: event.target.value as Polarity })}
                      >
                        {POLARITIES.map((p) => (
                          <option key={p} value={p}>
                            {intl.formatMessage({ id: `exam.question.polarity.${p}` })}
                          </option>
                        ))}
                      </select>
                    </label>{' '}
                    <label>
                      {intl.formatMessage({ id: 'exam.question.option.weight' })}{' '}
                      <input
                        type="number"
                        step="any"
                        data-testid={`question-option-weight-${index}`}
                        value={option.weight}
                        onChange={(event) => {
                          const weight = Number(event.target.value)
                          updateOption(option.key, { weight: Number.isFinite(weight) ? weight : 0 })
                        }}
                      />
                    </label>
                  </>
                )}
                {canRemove && (
                  <Button
                    variant="ghost"
                    size="sm"
                    data-testid={`question-option-remove-${index}`}
                    onClick={() => setDraft((d) => ({ ...d, options: d.options.filter((o) => o.key !== option.key) }))}
                  >
                    {intl.formatMessage({ id: 'exam.question.option.remove' })}
                  </Button>
                )}
              </li>
            ))}
          </ol>
        )}
        {showRows && canAdd && (
          <Button
            variant="secondary"
            size="sm"
            data-testid="question-option-add"
            onClick={() => setDraft((d) => ({ ...d, options: [...d.options, blankOption()] }))}
          >
            {intl.formatMessage({ id: 'exam.question.option.add' })}
          </Button>
        )}
      </fieldset>

      {refusals.length > 0 && (
        <div role="alert" data-testid="question-refusals">
          {refusals.map((id) => (
            <p key={id} data-testid={`question-refuse-${id}`}>
              {intl.formatMessage({ id: `exam.question.refuse.${id}` })}
            </p>
          ))}
        </div>
      )}
      {errorKind && (
        <p role="alert" data-testid={`question-error-${errorKind}`}>
          {intl.formatMessage({ id: `exam.question.err.${errorKind}` })}
        </p>
      )}
      {saved && <p role="status" data-testid="question-saved">{intl.formatMessage({ id: 'exam.question.saved' })}</p>}
      {canWrite && (
        <Button variant="primary" size="md" loading={saving} disabled={saving} data-testid="question-save" onClick={() => void save()}>
          {intl.formatMessage({ id: 'exam.question.save' })}
        </Button>
      )}{' '}
      <Link to={BANK_PATH}>{intl.formatMessage({ id: 'exam.question.editor.back' })}</Link>
    </div>
  )

  return (
    <PageLayout title={intl.formatMessage({ id: editing ? 'exam.question.editor.titleEdit' : 'exam.question.editor.titleNew' })}>
      {editing ? (
        <QueryStateBoundary
          state={
            (loadQuery.isLoading ? 'loading' : loadQuery.isError ? classifyError(loadQuery.error) : 'success') as RendererState
          }
          onRetry={() => {
            void loadQuery.refetch()
          }}
        >
          {body}
        </QueryStateBoundary>
      ) : (
        body
      )}
    </PageLayout>
  )
}

export default function QuestionEditorPage() {
  return (
    <ExamIntlProvider>
      <QuestionEditorPageInner />
    </ExamIntlProvider>
  )
}
