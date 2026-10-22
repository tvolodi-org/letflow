// @vitest-environment jsdom
/**
 * REQ-343 AC1 — one create-then-list-then-edit-then-delete test per each of
 * the ten admin-manageable BilimBaga entity types, all exercising the SAME
 * generic `EntityCrudPage` component (not ten hand-written page files) —
 * proving the "generic component, not ten hand-copied pages" reuse claim
 * actually works for every entity shape: a plain-field entity (category,
 * tag), an fk-reference + enum + localized_text entity (question), a
 * composite-unique join entity (question_tag), the is_correct
 * field-grant-aware entity (answer_option), and the remaining five exam*
 * types.
 *
 * ISS-0655: `tag` was REQ-336's original hand-built pilot
 * (`TagListPage.tsx`, since removed as superseded dead code) and was
 * dropped rather than carried across when REQ-343 generalized the other
 * nine types into this component. Its case below closes that gap and is
 * this test suite's regression coverage for it.
 *
 * Mocking pattern: useQuery/useMutation mocked directly, no msw/raw-fetch —
 * DIRECTIVE T-2.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, fireEvent, act } from '@testing-library/react'
import { renderWithAccess } from '@/auth/access/testing'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(() => ({ mutate: vi.fn(), isPending: false })),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/api/entities', () => ({
  entitiesApi: {
    getActiveDefinition: vi.fn(),
    queryRecords: vi.fn(),
    createRecord: vi.fn(),
    updateRecord: vi.fn(),
    deleteRecord: vi.fn(),
  },
}))

// REQ-384: EntityCrudPage now resolves tenant-scoped query keys via
// useTenantScopedQueryKeys(), which reads useAuth().session.tenant_id. This
// suite never exercised auth/tenant identity, so a fixed authenticated
// session is sufficient here.
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: 'oidc',
      tenant_slug: 'fixture-tenant',
      tenant_display_name: 'Fixture Tenant',
      tenant_id: 'tid-entity-crud',
      tenant_type: 'test',
    },
    isAuthenticated: true,
  }),
}))

import { useQuery, useMutation } from '@tanstack/react-query'
import { entitiesApi } from '@/api/entities'
import { EntityCrudPage } from '@/pages/entities/EntityCrudPage'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import type { EntityDefinition, EntityFieldDef, EntityRecordsPage } from '@/types/api'

const mockUseQuery = vi.mocked(useQuery)
const mockUseMutation = vi.mocked(useMutation)

interface Case {
  entityType: string
  fields: EntityFieldDef[]
  foreignKeys?: { name: string; field: string; references_entity: string }[]
  sampleFieldValues: Record<string, unknown>
  /** the field whose formatted list-cell text is asserted */
  primaryField: string
  primaryCellText: string
}

const CASES: Case[] = [
  {
    entityType: 'category',
    fields: [
      { name: 'name', type: 'localized_text', locales: ['kk', 'ru', 'en'], required: true, queried: true },
      { name: 'track', type: 'string', required: false, queried: true },
      { name: 'sort_order', type: 'integer', required: true, queried: true },
    ],
    sampleFieldValues: { name: { en: 'Security', ru: 'Безопасность', kk: 'Қауіпсіздік' }, track: 'security', sort_order: 1 },
    primaryField: 'track',
    primaryCellText: 'security',
  },
  {
    entityType: 'question',
    fields: [
      { name: 'category_id', type: 'string', required: true, queried: true },
      { name: 'difficulty', type: 'enum', enum_values: ['easy', 'medium', 'hard'], required: true, queried: true },
      { name: 'type', type: 'enum', enum_values: ['single', 'multiple'], required: true, queried: true },
      { name: 'stem', type: 'localized_text', locales: ['kk', 'ru', 'en'], required: true, queried: true },
    ],
    foreignKeys: [{ name: 'fk_question_category_id', field: 'category_id', references_entity: 'category' }],
    sampleFieldValues: { category_id: 'cat-1', difficulty: 'medium', type: 'single', stem: { en: 'What is 2+2?' } },
    primaryField: 'difficulty',
    primaryCellText: 'medium',
  },
  {
    entityType: 'answer_option',
    fields: [
      { name: 'question_id', type: 'string', required: true, queried: true },
      { name: 'sort_order', type: 'integer', required: true, queried: true },
      { name: 'is_correct', type: 'boolean', required: true, queried: true },
      { name: 'text', type: 'localized_text', locales: ['kk', 'ru', 'en'], required: true, queried: true },
    ],
    foreignKeys: [{ name: 'fk_answer_option_question_id', field: 'question_id', references_entity: 'question' }],
    sampleFieldValues: { question_id: 'q-1', sort_order: 1, is_correct: true, text: { en: 'Four' } },
    primaryField: 'is_correct',
    // Localized via entities.crud.boolean.yes -- asserted against the
    // catalog's `en` value rather than a hard-coded 'Yes' literal, so this
    // stays resilient if the English wording changes later.
    primaryCellText: entitiesMessages.en['entities.crud.boolean.yes'],
  },
  {
    entityType: 'question_tag',
    fields: [
      { name: 'question_id', type: 'string', required: true, queried: true },
      { name: 'tag_id', type: 'string', required: true, queried: true },
    ],
    foreignKeys: [
      { name: 'fk_question_tag_question_id', field: 'question_id', references_entity: 'question' },
      { name: 'fk_question_tag_tag_id', field: 'tag_id', references_entity: 'tag' },
    ],
    sampleFieldValues: { question_id: 'q-1', tag_id: 'tag-1' },
    primaryField: 'tag_id',
    primaryCellText: 'tag-1',
  },
  {
    entityType: 'exam',
    fields: [
      { name: 'title', type: 'localized_text', locales: ['kk', 'ru', 'en'], required: true, queried: true },
      { name: 'status', type: 'enum', enum_values: ['draft', 'active', 'archived'], required: true, queried: true },
    ],
    sampleFieldValues: { title: { en: 'Annual Safety Exam' }, status: 'draft' },
    primaryField: 'status',
    primaryCellText: 'draft',
  },
  {
    entityType: 'exam_section',
    fields: [
      { name: 'exam_id', type: 'string', required: true, queried: true },
      { name: 'sort_order', type: 'integer', required: true, queried: true },
    ],
    foreignKeys: [{ name: 'fk_exam_section_exam_id', field: 'exam_id', references_entity: 'exam' }],
    sampleFieldValues: { exam_id: 'exam-1', sort_order: 1 },
    primaryField: 'sort_order',
    primaryCellText: '1',
  },
  {
    entityType: 'exam_question_rule',
    fields: [
      { name: 'exam_id', type: 'string', required: true, queried: true },
      { name: 'mode', type: 'enum', enum_values: ['manual', 'random'], required: true, queried: true },
    ],
    foreignKeys: [{ name: 'fk_exam_question_rule_exam_id', field: 'exam_id', references_entity: 'exam' }],
    sampleFieldValues: { exam_id: 'exam-1', mode: 'random' },
    primaryField: 'mode',
    primaryCellText: 'random',
  },
  {
    entityType: 'exam_question_rule_tag',
    fields: [
      { name: 'rule_id', type: 'string', required: true, queried: true },
      { name: 'tag_id', type: 'string', required: true, queried: true },
    ],
    foreignKeys: [
      { name: 'fk_exam_question_rule_tag_rule_id', field: 'rule_id', references_entity: 'exam_question_rule' },
      { name: 'fk_exam_question_rule_tag_tag_id', field: 'tag_id', references_entity: 'tag' },
    ],
    sampleFieldValues: { rule_id: 'rule-1', tag_id: 'tag-1' },
    primaryField: 'rule_id',
    primaryCellText: 'rule-1',
  },
  {
    entityType: 'exam_manual_question',
    fields: [
      { name: 'rule_id', type: 'string', required: true, queried: true },
      { name: 'question_id', type: 'string', required: true, queried: true },
      { name: 'sort_order', type: 'integer', required: true, queried: true },
    ],
    foreignKeys: [
      { name: 'fk_exam_manual_question_rule_id', field: 'rule_id', references_entity: 'exam_question_rule' },
      { name: 'fk_exam_manual_question_question_id', field: 'question_id', references_entity: 'question' },
    ],
    sampleFieldValues: { rule_id: 'rule-1', question_id: 'q-1', sort_order: 2 },
    primaryField: 'sort_order',
    primaryCellText: '2',
  },
  {
    entityType: 'tag',
    fields: [{ name: 'name', type: 'string', required: true, queried: true }],
    sampleFieldValues: { name: 'security' },
    primaryField: 'name',
    primaryCellText: 'security',
  },
]

function installMocksFor(c: Case) {
  const definition: EntityDefinition = {
    id: `def-${c.entityType}`,
    name: c.entityType,
    display_name: c.entityType,
    definition: {
      name: c.entityType,
      display_name: c.entityType,
      fields: c.fields,
      foreign_keys: c.foreignKeys,
    },
    content_hash: 'x',
    logical_shape_version: 'x',
    artifact_version_id: 'x',
    status: 'active',
    inserted_at: '2026-01-01T00:00:00Z',
  }

  const page: EntityRecordsPage = {
    items: [
      {
        record_id: 'r1',
        field_values: c.sampleFieldValues,
        deleted: false,
        entity_def_version: 'v1',
        last_event_global_seq: 1,
      },
    ],
    next_cursor: null,
  }

  const deleteMutateSpy = vi.fn()

  // `entityReferenceSelectRenderer` (a fk-reference field's widget) calls
  // entitiesApi.getActiveDefinition/queryRecords directly (NOT through the
  // mocked useQuery above -- it manages its own async effect) to resolve a
  // human-readable label for the referenced entity's records. Give it a
  // harmless resolved definition/page so that effect does not throw; the
  // widget's own resolution behavior is proven by
  // EntityRecordForm.fkReference.test.tsx, not re-tested here.
  vi.mocked(entitiesApi.getActiveDefinition).mockResolvedValue(definition)
  vi.mocked(entitiesApi.queryRecords).mockResolvedValue({ items: [], next_cursor: null })

  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] }
    // REQ-384 §7.1: keys are now tenant-prefixed --
    // ['tenant', tenantId, 'entities', 'definition'|'records', ...].
    if (queryKey[3] === 'definition') {
      return { data: definition, isLoading: false, isError: false, error: null, refetch: vi.fn() } as unknown as ReturnType<typeof useQuery>
    }
    return { data: page, isLoading: false, isError: false, error: null, refetch: vi.fn() } as unknown as ReturnType<typeof useQuery>
  })

  mockUseMutation.mockImplementation((opts: unknown) => {
    const { mutationFn } = opts as { mutationFn: (v: unknown) => unknown }
    return {
      mutate: (variables: unknown) => {
        deleteMutateSpy(variables)
        void mutationFn(variables)
      },
      isPending: false,
    } as unknown as ReturnType<typeof useMutation>
  })

  return { deleteMutateSpy }
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe.each(CASES)('REQ-343 AC1 — EntityCrudPage generic CRUD for entity_type=$entityType', (c) => {
  it('lists the real record, opens create, opens edit, and requires confirmation before delete', () => {
    vi.useFakeTimers()
    try {
      const { deleteMutateSpy } = installMocksFor(c)

      renderWithAccess(<EntityCrudPage entityType={c.entityType} />)

      // LIST: the real record's formatted cell value is rendered.
      expect(screen.getByText(c.primaryCellText)).toBeInTheDocument()

      // CREATE: opens the generic form modal. ISS-0662: the click handler
      // defers its setState by one macrotask (deferClickState) to avoid a
      // real-click renderer freeze, so the modal appears asynchronously —
      // flush the deferred macrotask with fake timers rather than polling
      // on real ones.
      fireEvent.click(screen.getByTestId('entity-create-action'))
      act(() => {
        vi.runAllTimers()
      })
      expect(screen.getByTestId('entity-form-modal')).toBeInTheDocument()
      expect(screen.getByTestId('entity-record-form')).toBeInTheDocument()

      // EDIT: opens the same form modal, pre-populated (implicitly, via
      // EntityRecordForm's own initialValues prop — covered by REQ-336's
      // EntityRecordForm suite).
      fireEvent.click(screen.getByTestId(`entity-edit-${'r1'}`))
      act(() => {
        vi.runAllTimers()
      })
      expect(screen.getByTestId('entity-form-modal')).toBeInTheDocument()

      // DELETE: first click only opens ConfirmDialog -- no DELETE call yet.
      fireEvent.click(screen.getByTestId(`entity-delete-r1`))
      act(() => {
        vi.runAllTimers()
      })
      expect(deleteMutateSpy).not.toHaveBeenCalled()
      expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument()

      fireEvent.click(screen.getByTestId('confirm-dialog-confirm'))
      act(() => {
        vi.runAllTimers()
      })
      expect(deleteMutateSpy).toHaveBeenCalledWith('r1')
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('ISS-0663 — default records list excludes soft-deleted rows', () => {
  it("sends an explicit deleted:false filter on the records query's queryFn call to entitiesApi.queryRecords, and the queryKey reflects that filter", async () => {
    const tagCase = CASES.find((c) => c.entityType === 'tag')!
    installMocksFor(tagCase)

    renderWithAccess(<EntityCrudPage entityType="tag" />)

    // useQuery is mocked directly (DIRECTIVE T-2's mocking pattern for this
    // suite), so its queryFn is never invoked by the mock automatically --
    // pull out the records query's own options and call queryFn ourselves to
    // prove what request it actually issues.
    const recordsCall = mockUseQuery.mock.calls.find(([opts]) => {
      const { queryKey } = opts as { queryKey: readonly unknown[] }
      return queryKey[3] === 'records'
    })
    expect(recordsCall).toBeDefined()
    const [{ queryKey, queryFn }] = recordsCall as [{ queryKey: readonly unknown[]; queryFn: () => unknown }]

    // The queryKey (distinct from the fk-reference widget's own internal
    // queryRecords calls, which bypass useQuery entirely) must include the
    // filter too, so the cache key matches the actual request shape.
    expect(queryKey[5]).toMatchObject({
      filters: [{ field: 'deleted', op: 'eq', value: false }],
    })

    await queryFn()

    // POST /entities/query injects no implicit deleted:false default
    // (lib/letflow/entities/query/compiler.ex) -- an empty filter list would
    // return soft-deleted rows alongside live ones, so this screen must ask
    // for exclusion explicitly.
    expect(entitiesApi.queryRecords).toHaveBeenCalledWith(
      'tag',
      expect.objectContaining({
        filters: [{ field: 'deleted', op: 'eq', value: false }],
      }),
    )
  })
})

describe('REQ-343 AC2 — answer_option is_correct field-grant awareness', () => {
  it("renders answer_option's is_correct field in the admin create/edit form (this IS the authoring surface, not the candidate-facing exam UI)", () => {
    vi.useFakeTimers()
    try {
      const answerOptionCase = CASES.find((c) => c.entityType === 'answer_option')!
      installMocksFor(answerOptionCase)

      renderWithAccess(<EntityCrudPage entityType="answer_option" />)
      fireEvent.click(screen.getByTestId('entity-create-action'))
      act(() => {
        vi.runAllTimers()
      })

      const form = screen.getByTestId('entity-record-form')
      // is_correct is a :boolean field -> renders as a checkbox input somewhere
      // in the generated form; it is neither hidden nor omitted.
      const checkbox = form.querySelector('input[type="checkbox"]')
      expect(checkbox).not.toBeNull()
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('GH 2238 BUILDS 5 — EntityCrudPage write controls follow EntitiesRecordsWrite', () => {
  it('an auditor sees the records but no create, edit or delete control', () => {
    const c = CASES[0]
    installMocksFor(c)

    renderWithAccess(<EntityCrudPage entityType={c.entityType} />, 'auditor')

    expect(screen.getByText(c.primaryCellText)).toBeInTheDocument()
    expect(screen.queryByTestId('entity-create-action')).not.toBeInTheDocument()
    expect(screen.queryByTestId('entity-edit-r1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('entity-delete-r1')).not.toBeInTheDocument()
  })
})

describe('GH #2815 — restricted-field write 403 shows a friendly message', () => {
  const restrictedMessage = entitiesMessages.en['entities.crud.form.restrictedFieldError']

  function openCreateAndFail(err: unknown) {
    vi.useFakeTimers()
    try {
      installMocksFor(CASES[0])
      const onErrors: Array<(e: unknown) => void> = []
      const base = mockUseMutation.getMockImplementation()!
      mockUseMutation.mockImplementation((opts: unknown) => {
        onErrors.push((opts as { onError: (e: unknown) => void }).onError)
        return base(opts as never)
      })
      renderWithAccess(<EntityCrudPage entityType={CASES[0].entityType} />)
      fireEvent.click(screen.getByTestId('entity-create-action'))
      act(() => {
        vi.runAllTimers()
      })
      act(() => {
        onErrors[0](err)
      })
    } finally {
      vi.useRealTimers()
    }
  }

  it('maps the write 403 body to a message that names no field', () => {
    openCreateAndFail({
      status: 403,
      code: 'https://letflow/problems/forbidden',
      message: 'Forbidden',
      details: { detail: 'one or more requested fields are restricted for this caller', status: 403 },
    })
    const banner = screen.getByTestId('entity-form-error-banner')
    expect(banner).toHaveTextContent(restrictedMessage)
    expect(banner).not.toHaveTextContent('restricted for this caller')
  })

  it('maps the import per-entry field_restricted code to the same message', () => {
    openCreateAndFail({ status: 422, code: 'field_restricted', message: 'field_restricted' })
    expect(screen.getByTestId('entity-form-error-banner')).toHaveTextContent(restrictedMessage)
  })

  it('leaves an unrelated 403 untouched', () => {
    openCreateAndFail({ status: 403, code: 'x', message: 'Forbidden', details: { detail: 'other' } })
    expect(screen.getByTestId('entity-form-error-banner')).toHaveTextContent('Forbidden')
  })
})
