// @vitest-environment jsdom
/**
 * GH 3423 / REQ-612 — the question editor page (E1..E21).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, useLocation, useRoutes } from 'react-router-dom'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { ACCESS_FIXTURES } from '@/auth/access/fixtures'
import type { AccessState } from '@/auth/access/types'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({ session: { token: 'tok', tenant_id: 'tid-editor' }, isAuthenticated: true }),
}))

const clientMock = vi.hoisted(() => ({ post: vi.fn(), putWithHeaders: vi.fn(), delete: vi.fn(), get: vi.fn() }))
vi.mock('@/api/client', async (importOriginal) => ({ ...(await importOriginal<object>()), client: clientMock }))

import { examRouteObjects } from '../examRoutes'

const writer: AccessState = { status: 'ready', info: ACCESS_FIXTURES.tenantAdmin }
const reader: AccessState = {
  status: 'ready',
  info: {
    ...ACCESS_FIXTURES.tenantAdmin,
    permissions: ACCESS_FIXTURES.tenantAdmin.permissions.filter((p) => p !== 'ExamAuthoringWrite'),
  },
}

const QUERY = '/api/v1/entities/query'
const AUTH = '/api/v1/modules/exam/authoring'

function Routes() {
  return useRoutes(examRouteObjects)
}
function Where() {
  return <span data-testid="where">{useLocation().pathname}</span>
}

function renderAt(path: string, access: AccessState = writer) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <AccessStateProvider state={access}>
        <MemoryRouter initialEntries={[path]}>
          <Routes />
          <Where />
        </MemoryRouter>
      </AccessStateProvider>
    </QueryClientProvider>,
  )
}

function record(id: string, fieldValues: Record<string, unknown>, seq = 1) {
  return { record_id: id, field_values: fieldValues, deleted: false, entity_def_version: 'v', last_event_global_seq: seq }
}

const CATEGORIES = [record('cat-1', { name: { en: 'Safety' } }), record('cat-2', { name: { en: 'Fire' } })]
const QUESTION = record(
  'q-1',
  {
    category_id: 'cat-2',
    difficulty: 'hard',
    type: 'single',
    status: 'review',
    version: 3,
    default_locale: 'kk',
    parent_id: 'p-0',
    explanation: { en: 'Because' },
    stem: { kk: 'Қазақша', en: 'English stem' },
  },
  42,
)
const OPTIONS = [
  record('o-2', { question_id: 'q-1', sort_order: 2, text: { en: 'Second' }, is_correct: false }),
  record('o-1', { question_id: 'q-1', sort_order: 1, text: { en: 'First' }, is_correct: true }),
]

type QueryBody = { entity_type: string; filters?: Array<{ field: string; op: string; value?: unknown }> }
let questionItems = [QUESTION]
let optionItems = OPTIONS

function setupQueries() {
  clientMock.post.mockImplementation(async (path: string, body: QueryBody & { field_values?: unknown }) => {
    if (path === QUERY) {
      if (body.entity_type === 'category') return { items: CATEGORIES, next_cursor: null }
      if (body.entity_type === 'question') return { items: questionItems, next_cursor: null }
      if (body.entity_type === 'answer_option') return { items: optionItems, next_cursor: null }
    }
    return { record_id: `new-${clientMock.post.mock.calls.length}`, field_values: {} }
  })
  clientMock.putWithHeaders.mockResolvedValue({})
  clientMock.delete.mockResolvedValue({})
}

function queryBodies(type: string): QueryBody[] {
  return clientMock.post.mock.calls.filter((c) => c[0] === QUERY && c[1].entity_type === type).map((c) => c[1])
}
function writesTo(prefix: string) {
  return clientMock.post.mock.calls.filter((c) => c[0] === `${AUTH}/${prefix}`)
}
const DELETED = { field: 'deleted', op: 'eq', value: false }

function pick(testId: string, value: string) {
  fireEvent.change(screen.getByTestId(testId), { target: { value } })
}

async function openNew(access: AccessState = writer) {
  renderAt('/admin/questions/new', access)
  await screen.findByRole('option', { name: 'Safety' })
}

function fillSingle(stem = 'What is fire?') {
  fireEvent.change(screen.getByTestId('question-stem'), { target: { value: stem } })
  pick('question-category', 'cat-1')
  fireEvent.change(screen.getByTestId('question-option-text-0'), { target: { value: 'Hot' } })
  fireEvent.change(screen.getByTestId('question-option-text-1'), { target: { value: 'Cold' } })
  fireEvent.click(screen.getByTestId('question-option-correct-0'))
}

beforeEach(() => {
  clientMock.post.mockReset()
  clientMock.putWithHeaders.mockReset()
  clientMock.delete.mockReset()
  questionItems = [QUESTION]
  optionItems = OPTIONS
  setupQueries()
})
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('create form', () => {
  it('E1 shows Save Draft, the stem with a placeholder, five types, three difficulties and the categories', async () => {
    await openNew()
    expect(screen.getByRole('button', { name: 'Save Draft' })).toBeInTheDocument()
    expect(screen.getByTestId('question-stem')).toHaveAttribute('placeholder', 'Write the question text')
    const types = Array.from(screen.getByTestId('question-type').querySelectorAll('option')).map((o) => (o as HTMLOptionElement).value)
    expect(types).toEqual(['single', 'multiple', 'truefalse', 'likert', 'shorttext'])
    const difficulties = Array.from(screen.getByTestId('question-difficulty').querySelectorAll('option')).map((o) => (o as HTMLOptionElement).value)
    expect(difficulties).toEqual(['easy', 'medium', 'hard'])
    expect(screen.getByRole('option', { name: 'Fire' })).toBeInTheDocument()
    expect(queryBodies('category')[0].filters).toEqual([DELETED])
  })

  it('E2 Save Draft posts the question, then one option per row, then opens the edit route', async () => {
    await openNew()
    fillSingle()
    fireEvent.click(screen.getByTestId('question-save'))
    await waitFor(() => expect(screen.getByTestId('where')).toHaveTextContent('/admin/questions/'))
    await waitFor(() => expect(screen.getByTestId('where')).toHaveTextContent('/edit'))
    const writes = clientMock.post.mock.calls.filter((c) => String(c[0]).startsWith(AUTH))
    expect(writes.map((c) => c[0])).toEqual([`${AUTH}/question`, `${AUTH}/answer_option`, `${AUTH}/answer_option`])
    expect(writes[0][1].field_values).toEqual({
      category_id: 'cat-1',
      difficulty: 'medium',
      type: 'single',
      default_locale: 'en',
      status: 'draft',
      version: 1,
      stem: { en: 'What is fire?' },
    })
    const newId = (await clientMock.post.mock.results[clientMock.post.mock.calls.indexOf(writes[0])].value).record_id
    expect(writes[1][1].field_values).toEqual({ question_id: newId, sort_order: 1, text: { en: 'Hot' }, is_correct: true })
    expect(writes[2][1].field_values).toEqual({ question_id: newId, sort_order: 2, text: { en: 'Cold' }, is_correct: false })
  })
})

describe('option rows by type', () => {
  it('E3 single: radio-style correct control per row, add and remove within 2..8', async () => {
    await openNew()
    expect(screen.getAllByRole('radio')).toHaveLength(2)
    expect(screen.queryByTestId('question-option-remove-0')).toBeNull()
    for (let i = 0; i < 6; i++) fireEvent.click(screen.getByTestId('question-option-add'))
    expect(screen.getAllByRole('radio')).toHaveLength(8)
    expect(screen.queryByTestId('question-option-add')).toBeNull()
    fireEvent.click(screen.getByTestId('question-option-remove-0'))
    expect(screen.getAllByRole('radio')).toHaveLength(7)
  })

  it('E4 multiple: a checkbox per row, several may be correct', async () => {
    await openNew()
    pick('question-type', 'multiple')
    const boxes = screen.getAllByRole('checkbox')
    expect(boxes).toHaveLength(2)
    fireEvent.click(boxes[0])
    fireEvent.click(boxes[1])
    expect(boxes[0]).toBeChecked()
    expect(boxes[1]).toBeChecked()
  })

  it('E5 truefalse: two fixed rows with the localized words and one correct radio', async () => {
    await openNew()
    pick('question-type', 'truefalse')
    expect(screen.getByTestId('question-option-word-0')).toHaveTextContent('True')
    expect(screen.getByTestId('question-option-word-1')).toHaveTextContent('False')
    expect(screen.getAllByRole('radio')).toHaveLength(2)
    expect(screen.queryByTestId('question-option-add')).toBeNull()
    expect(screen.queryByTestId('question-option-remove-0')).toBeNull()
  })

  it('E6 likert: polarity and weight per row and no correct control', async () => {
    await openNew()
    pick('question-type', 'likert')
    expect(screen.getByTestId('question-option-polarity-0')).toBeInTheDocument()
    expect(screen.getByTestId('question-option-weight-1')).toBeInTheDocument()
    expect(screen.queryByTestId('question-option-correct-0')).toBeNull()
  })

  it('E7 shorttext: no option rows and the examiner notice', async () => {
    await openNew()
    pick('question-type', 'shorttext')
    expect(screen.queryByTestId('question-options')).toBeNull()
    expect(screen.getByTestId('question-shorttext-notice')).toHaveTextContent(/examiner grades this answer/)
    expect(screen.queryByTestId('question-option-add')).toBeNull()
  })

  it('E8 switching types back and forth re-renders without error and keeps the stem', async () => {
    await openNew()
    fireEvent.change(screen.getByTestId('question-stem'), { target: { value: 'keep me' } })
    for (const type of ['likert', 'shorttext', 'truefalse', 'multiple', 'single']) pick('question-type', type)
    expect(screen.getByTestId('question-stem')).toHaveValue('keep me')
    expect(screen.getAllByRole('radio')).toHaveLength(2)
  })

  it('E14 likert options are sent with is_correct false, polarity and weight', async () => {
    await openNew()
    pick('question-type', 'likert')
    fireEvent.change(screen.getByTestId('question-stem'), { target: { value: 'Rate' } })
    pick('question-category', 'cat-1')
    fireEvent.change(screen.getByTestId('question-option-text-0'), { target: { value: 'Agree' } })
    fireEvent.change(screen.getByTestId('question-option-text-1'), { target: { value: 'Disagree' } })
    pick('question-option-polarity-1', 'negative')
    fireEvent.change(screen.getByTestId('question-option-weight-1'), { target: { value: '3' } })
    fireEvent.click(screen.getByTestId('question-save'))
    await waitFor(() => expect(writesTo('answer_option')).toHaveLength(2))
    expect(writesTo('answer_option')[0][1].field_values).toMatchObject({ is_correct: false, likert_polarity: 'positive', likert_weight: 1 })
    expect(writesTo('answer_option')[1][1].field_values).toMatchObject({ is_correct: false, likert_polarity: 'negative', likert_weight: 3 })
  })
})

describe('refusals send no request', () => {
  async function expectRefused(id: string) {
    fireEvent.click(screen.getByTestId('question-save'))
    expect(await screen.findByTestId(`question-refuse-${id}`)).toBeVisible()
    expect(clientMock.post.mock.calls.filter((c) => String(c[0]).startsWith(AUTH))).toEqual([])
  }

  it('E9 empty stem', async () => {
    await openNew()
    fillSingle('')
    await expectRefused('stemEmpty')
  })
  it('E10 no category', async () => {
    await openNew()
    fillSingle()
    pick('question-category', '')
    await expectRefused('categoryMissing')
  })
  it('E11 single without a correct option', async () => {
    await openNew()
    fireEvent.change(screen.getByTestId('question-stem'), { target: { value: 'Q' } })
    pick('question-category', 'cat-1')
    await expectRefused('needOneCorrect')
  })
  it('E12 truefalse is sent as the two localized words with exactly one correct', async () => {
    await openNew()
    fireEvent.change(screen.getByTestId('question-stem'), { target: { value: 'Is it?' } })
    pick('question-category', 'cat-1')
    pick('question-type', 'truefalse')
    fireEvent.click(screen.getByTestId('question-option-correct-1'))
    fireEvent.click(screen.getByTestId('question-save'))
    await waitFor(() => expect(writesTo('answer_option')).toHaveLength(2))
    expect(writesTo('answer_option').map((c) => c[1].field_values)).toMatchObject([
      { text: { en: 'True' }, is_correct: false },
      { text: { en: 'False' }, is_correct: true },
    ])
  })
  it('E13 multiple without a correct option', async () => {
    await openNew()
    fireEvent.change(screen.getByTestId('question-stem'), { target: { value: 'Which?' } })
    pick('question-category', 'cat-1')
    pick('question-type', 'multiple')
    await expectRefused('needSomeCorrect')
  })
})

describe('edit', () => {
  async function openEdit(access: AccessState = writer) {
    renderAt('/admin/questions/q-1/edit', access)
    await screen.findByDisplayValue('English stem')
  }

  it('E15 pre-populates stem, type, difficulty, category and options in sort order', async () => {
    await openEdit()
    expect(screen.getByTestId('question-type')).toHaveValue('single')
    expect(screen.getByTestId('question-difficulty')).toHaveValue('hard')
    expect(screen.getByTestId('question-category')).toHaveValue('cat-2')
    expect(screen.getByTestId('question-option-text-0')).toHaveValue('First')
    expect(screen.getByTestId('question-option-text-1')).toHaveValue('Second')
    expect(screen.getByTestId('question-option-correct-0')).toBeChecked()
  })

  it('E15b the question and option reads carry the deleted filter', async () => {
    await openEdit()
    expect(queryBodies('question')[0].filters).toEqual([{ field: 'record_id', op: 'eq', value: 'q-1' }, DELETED])
    expect(queryBodies('answer_option')[0].filters).toEqual([{ field: 'question_id', op: 'eq', value: 'q-1' }, DELETED])
  })

  it('E16 Save sends a whole-document PUT with the loaded values and the loaded sequence', async () => {
    await openEdit()
    fireEvent.change(screen.getByTestId('question-stem'), { target: { value: 'Changed' } })
    fireEvent.click(screen.getByTestId('question-save'))
    await waitFor(() => expect(clientMock.putWithHeaders).toHaveBeenCalled())
    const [path, body] = clientMock.putWithHeaders.mock.calls[0]
    expect(path).toBe(`${AUTH}/question/q-1`)
    expect(body.expected_last_event_global_seq).toBe(42)
    expect(body.field_values).toMatchObject({
      explanation: { en: 'Because' },
      parent_id: 'p-0',
      version: 3,
      status: 'review',
      default_locale: 'kk',
      stem: { kk: 'Қазақша', en: 'Changed' },
    })
  })

  it('E17 option creates, updates and deletes, and the refetch does not bring the deleted row back', async () => {
    optionItems = [...OPTIONS, record('o-3', { question_id: 'q-1', sort_order: 3, text: { en: 'Extra' }, is_correct: false })]
    await openEdit()
    await screen.findByTestId('question-option-text-2')
    fireEvent.click(screen.getByTestId('question-option-remove-1'))
    fireEvent.click(screen.getByTestId('question-option-add'))
    fireEvent.change(screen.getByTestId('question-option-text-2'), { target: { value: 'Third' } })
    fireEvent.change(screen.getByTestId('question-option-text-0'), { target: { value: 'First!' } })
    optionItems = [OPTIONS[1], optionItems[2]]
    fireEvent.click(screen.getByTestId('question-save'))
    await screen.findByTestId('question-saved')
    expect(clientMock.delete).toHaveBeenCalledWith(`${AUTH}/answer_option/o-2`)
    expect(clientMock.putWithHeaders.mock.calls.map((c) => c[0])).toEqual([
      `${AUTH}/question/q-1`,
      `${AUTH}/answer_option/o-1`,
      `${AUTH}/answer_option/o-3`,
    ])
    expect(writesTo('answer_option')).toHaveLength(1)
    expect(writesTo('answer_option')[0][1].field_values).toMatchObject({ question_id: 'q-1', sort_order: 3, text: { en: 'Third' } })
    const optionReads = queryBodies('answer_option')
    expect(optionReads.length).toBeGreaterThanOrEqual(2)
    for (const read of optionReads) expect(read.filters).toContainEqual(DELETED)
    await waitFor(() => expect(screen.getByTestId('question-option-text-0')).toHaveValue('First'))
    expect(screen.queryByTestId('question-option-text-2')).toBeNull()
  })

  it('E22 an untouched option is not written and an edited one keeps its other locales', async () => {
    optionItems = [
      record('o-1', { question_id: 'q-1', sort_order: 1, text: { kk: 'A', ru: 'Б', en: 'C' }, is_correct: true }),
      record('o-2', { question_id: 'q-1', sort_order: 2, text: { kk: 'Д', ru: 'Е', en: 'F' }, is_correct: false }),
    ]
    await openEdit()
    await screen.findByTestId('question-option-text-1')
    fireEvent.change(screen.getByTestId('question-option-text-1'), { target: { value: 'F2' } })
    fireEvent.click(screen.getByTestId('question-save'))
    await screen.findByTestId('question-saved')
    const optionPuts = clientMock.putWithHeaders.mock.calls.filter((c) => String(c[0]).includes('/answer_option/'))
    expect(optionPuts.map((c) => c[0])).toEqual([`${AUTH}/answer_option/o-2`])
    expect(optionPuts[0][1].field_values.text).toEqual({ kk: 'Д', ru: 'Е', en: 'F2' })
  })

  it('E23 a failed option write after the question PUT reloads the question and keeps the error', async () => {
    await openEdit()
    fireEvent.change(screen.getByTestId('question-option-text-0'), { target: { value: 'First!' } })
    clientMock.putWithHeaders.mockImplementation(async (path: string) => {
      if (String(path).includes('/answer_option/')) throw Object.assign(new Error('boom'), { status: 500 })
      return {}
    })
    const before = queryBodies('question').length
    fireEvent.click(screen.getByTestId('question-save'))
    await waitFor(() => expect(queryBodies('question').length).toBeGreaterThan(before))
    expect(await screen.findByTestId('question-error-generic')).toBeInTheDocument()
  })

  it('E18 a 409 shows the conflict message and keeps the form values', async () => {
    await openEdit()
    clientMock.putWithHeaders.mockRejectedValue({ status: 409, message: 'conflict' })
    fireEvent.change(screen.getByTestId('question-stem'), { target: { value: 'Mine' } })
    fireEvent.click(screen.getByTestId('question-save'))
    expect(await screen.findByTestId('question-error-conflict')).toHaveTextContent(/changed by someone else/)
    expect(screen.getByTestId('question-stem')).toHaveValue('Mine')
    expect(screen.getByTestId('where')).toHaveTextContent('/admin/questions/q-1/edit')
  })

  it.each([
    ['parent_not_found', /parent question/],
    ['lineage_branch', /branch/],
    ['version_not_increasing', /higher than the parent/],
    ['lineage_active_conflict', /already active/],
  ])('E19 a 422 with reason %s shows its message', async (reason, text) => {
    await openEdit()
    clientMock.putWithHeaders.mockRejectedValue({ status: 422, details: { reason } })
    fireEvent.click(screen.getByTestId('question-save'))
    expect(await screen.findByTestId(`question-error-${reason}`)).toHaveTextContent(text)
    expect(screen.getByTestId('question-stem')).toHaveValue('English stem')
  })

  it('E20 an empty result and a 404 show the same not-found state', async () => {
    questionItems = []
    renderAt('/admin/questions/gone/edit')
    expect(await screen.findByTestId('question-editor-not-found')).toBeInTheDocument()
    expect(queryBodies('question')[0].filters).toContainEqual(DELETED)
    cleanup()
    clientMock.post.mockImplementation(async (_path: string, body: QueryBody) => {
      if (body.entity_type === 'question') throw { status: 404, message: 'not found' }
      return { items: CATEGORIES, next_cursor: null }
    })
    renderAt('/admin/questions/other-tenant/edit')
    expect(await screen.findByTestId('question-editor-not-found')).toBeInTheDocument()
  })

  it('E21 a user without ExamAuthoringWrite sees no Save Draft on new and edit', async () => {
    await openNew(reader)
    expect(screen.queryByTestId('question-save')).toBeNull()
    expect(screen.getByTestId('question-stem')).toBeDisabled()
    cleanup()
    await openEdit(reader)
    expect(screen.queryByTestId('question-save')).toBeNull()
  })

  it('there is no AI or Import button on the editor', async () => {
    await openEdit()
    expect(screen.queryByRole('button', { name: /\bai\b|generate|import/i })).toBeNull()
  })
})
