// @vitest-environment jsdom
/**
 * GH 2680 / REQ-510 slice 2 — which routes the generic EntityCrudPage's writes reach, and which
 * controls the caller sees.
 *
 * Unlike EntityCrudPage.test.tsx, the entities API is NOT mocked here: the real client runs
 * against a window.fetch spy, so each assertion is on the request the page actually sends (path,
 * method, If-Match header, body). Only React Query (reads and mutation lifecycle) and the auth
 * context are mocked.
 *
 *  - no `writes` prop (the default, every non-BilimBaga type): /api/v1/entities/records, gated
 *    by EntitiesRecordsWrite;
 *  - `writes={BILIMBAGA_WRITES}` (the ten BilimBaga types): /api/v1/modules/exam/authoring,
 *    gated by ExamAuthoringWrite.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup, fireEvent, act } from '@testing-library/react'
import { renderWithAccess } from '@/auth/access/testing'
import { setToken, clearToken } from '@/api/client'
expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(),
  useMutation: vi.fn(),
  useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: 'oidc',
      tenant_slug: 'fixture-tenant',
      tenant_display_name: 'Fixture Tenant',
      tenant_id: 'tid-writes',
      tenant_type: 'test',
    },
    isAuthenticated: true,
  }),
}))

import { useQuery, useMutation } from '@tanstack/react-query'
import { EntityCrudPage } from '@/pages/entities/EntityCrudPage'
import { BILIMBAGA_WRITES } from '../bilimbagaWrites'
import { BILIMBAGA_ENTITY_TYPES } from '@/config/bilimbagaEntities'
import { entitiesMessages } from '@/i18n/entitiesMessages'
import type { EntityDefinition, EntityFieldDef, EntityRecordsPage } from '@/types/api'

const mockUseQuery = vi.mocked(useQuery)
const mockUseMutation = vi.mocked(useMutation)

const RECORDS = '/api/v1/entities/records'
const AUTHORING = '/api/v1/modules/exam/authoring'
const RESTRICTED_DETAIL = 'one or more requested fields are restricted for this caller'

const TAG_FIELDS: EntityFieldDef[] = [{ name: 'name', type: 'string', required: true, queried: true }]

const originalFetch = window.fetch
let fetchSpy: ReturnType<typeof vi.fn>

/** A response the client reads through json()/text() without a body stream: a stream would not settle under fake timers. */
function jsonResponse(body: unknown, status = 200): Promise<Response> {
  const response = {
    ok: status < 400,
    status,
    headers: new Headers({ 'Content-Type': 'application/json' }),
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
  }
  return Promise.resolve(response as unknown as Response)
}

/** One record `r1` (version `v1`) and its active definition. A type with no fields gets an empty
 *  form, so create and update submit `{ field_values: {} }` and the write goes through as-is. */
function installMocks(entityType: string, fields: EntityFieldDef[]) {
  const definition: EntityDefinition = {
    id: `def-${entityType}`,
    name: entityType,
    display_name: entityType,
    definition: { name: entityType, display_name: entityType, fields },
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
        field_values: fields.length > 0 ? { name: 'security' } : {},
        deleted: false,
        entity_def_version: 'v1',
        last_event_global_seq: 1,
      },
    ],
    next_cursor: null,
  }

  mockUseQuery.mockImplementation((opts: unknown) => {
    const { queryKey } = opts as { queryKey: readonly unknown[] }
    // REQ-384: keys are tenant-prefixed, ['tenant', tenantId, 'entities', 'definition'|'records', ...].
    const data = queryKey[3] === 'definition' ? definition : page
    return { data, isLoading: false, isError: false, error: null, refetch: vi.fn() } as unknown as ReturnType<typeof useQuery>
  })

  // Runs the mutation the way React Query does: mutationFn, then onSuccess or onError, asynchronously.
  mockUseMutation.mockImplementation((opts: unknown) => {
    const o = opts as {
      mutationFn: (v: unknown) => Promise<unknown>
      onSuccess?: (d: unknown, v: unknown) => void
      onError?: (e: unknown, v: unknown) => void
    }
    return {
      mutate: (variables: unknown) => {
        void Promise.resolve()
          .then(() => o.mutationFn(variables))
          .then(
            (data) => o.onSuccess?.(data, variables),
            (err) => o.onError?.(err, variables),
          )
      },
      isPending: false,
    } as unknown as ReturnType<typeof useMutation>
  })
}

/** Runs the one-macrotask deferral of the page's click handlers (deferClickState) under fake timers. */
function flushDeferred(): void {
  act(() => {
    vi.runAllTimers()
  })
}

/** The element with that test id, after the deferred click state has been applied. */
function byTestId(id: string): HTMLElement {
  flushDeferred()
  return screen.getByTestId(id)
}

function byText(text: string): HTMLElement {
  flushDeferred()
  return screen.getByText(text)
}

/** Lets the mutation promise chain (mutationFn, then onSuccess or onError) run to the end. */
async function settle(): Promise<void> {
  flushDeferred()
  for (let i = 0; i < 50; i++) await Promise.resolve()
  flushDeferred()
}

/** The URL and init of the last request the page sent. */
function lastRequest(): { url: string; init: RequestInit } {
  const [url, init] = fetchSpy.mock.calls.at(-1) as [string, RequestInit]
  return { url, init }
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  setToken('test-token')
  fetchSpy = vi.fn().mockImplementation(() => jsonResponse({ record_id: 'r1' }))
  window.fetch = fetchSpy as unknown as typeof window.fetch
})

afterEach(() => {
  vi.useRealTimers()
  cleanup()
  window.fetch = originalFetch
  clearToken()
  vi.clearAllMocks()
})

describe('GH 2680 — the default path (no writes prop) still writes through /entities/records', () => {
  it('delete goes to DELETE /entities/records/:type/:id and to no exam route', async () => {
    installMocks('tag', TAG_FIELDS)
    renderWithAccess(<EntityCrudPage entityType="tag" />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-delete-r1'))
    fireEvent.click(byTestId('confirm-dialog-confirm'))
    await settle()
    const { url, init } = lastRequest()
    expect(url).toBe(`${RECORDS}/tag/r1`)
    expect(init.method).toBe('DELETE')
    expect(fetchSpy.mock.calls.map(([u]) => String(u)).some((u) => u.includes('/modules/exam/'))).toBe(false)
  })

  it('update goes to PUT /entities/records/:type/:id with the record version sent as If-Match', async () => {
    installMocks('tag', TAG_FIELDS)
    renderWithAccess(<EntityCrudPage entityType="tag" />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-edit-r1'))
    fireEvent.click(byTestId('entity-form-submit'))
    await settle()
    const { url, init } = lastRequest()
    expect(url).toBe(`${RECORDS}/tag/r1`)
    expect(init.method).toBe('PUT')
    expect(new Headers(init.headers).get('If-Match')).toBe('v1')
    expect(JSON.parse(init.body as string)).toEqual({ field_values: { name: 'security' } })
  })
})

describe.each(BILIMBAGA_ENTITY_TYPES)('GH 2680 — BilimBaga type $entityType writes go to /modules/exam/authoring', ({ entityType }) => {
  it('create goes to POST /modules/exam/authoring/:type', async () => {
    installMocks(entityType, [])
    renderWithAccess(<EntityCrudPage entityType={entityType} writes={BILIMBAGA_WRITES} />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-create-action'))
    expect(byTestId('entity-form-modal')).toBeInTheDocument()
    fireEvent.click(byTestId('entity-form-submit'))
    await settle()
    const { url, init } = lastRequest()
    expect(url).toBe(`${AUTHORING}/${entityType}`)
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ field_values: {} })
  })

  it('update goes to PUT /modules/exam/authoring/:type/:id with If-Match', async () => {
    installMocks(entityType, [])
    renderWithAccess(<EntityCrudPage entityType={entityType} writes={BILIMBAGA_WRITES} />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-edit-r1'))
    fireEvent.click(byTestId('entity-form-submit'))
    await settle()
    const { url, init } = lastRequest()
    expect(url).toBe(`${AUTHORING}/${entityType}/r1`)
    expect(init.method).toBe('PUT')
    expect(new Headers(init.headers).get('If-Match')).toBe('v1')
    expect(JSON.parse(init.body as string)).toEqual({ field_values: {} })
  })

  it('delete goes to DELETE /modules/exam/authoring/:type/:id', async () => {
    installMocks(entityType, [])
    renderWithAccess(<EntityCrudPage entityType={entityType} writes={BILIMBAGA_WRITES} />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-delete-r1'))
    fireEvent.click(byTestId('confirm-dialog-confirm'))
    await settle()
    const { url, init } = lastRequest()
    expect(url).toBe(`${AUTHORING}/${entityType}/r1`)
    expect(init.method).toBe('DELETE')
    expect(fetchSpy.mock.calls.map(([u]) => String(u)).some((u) => u.includes('/entities/records'))).toBe(false)
  })
})

describe('GH 2680 — the authoring routes’ errors are surfaced as the generic routes’ are', () => {
  it('a stale If-Match (409) on update shows the conflict banner', async () => {
    installMocks('tag', TAG_FIELDS)
    fetchSpy.mockImplementation(() => jsonResponse({ title: 'Conflict', type: 'stale_version' }, 409))
    renderWithAccess(<EntityCrudPage entityType="tag" writes={BILIMBAGA_WRITES} />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-edit-r1'))
    fireEvent.click(byTestId('entity-form-submit'))
    await settle()

    expect(byTestId('entity-form-conflict-banner')).toBeInTheDocument()
    expect(lastRequest().url).toBe(`${AUTHORING}/tag/r1`)
  })

  it('a restricted-field 403 on update shows the restricted-field message, naming no field', async () => {
    installMocks('tag', TAG_FIELDS)
    fetchSpy.mockImplementation(() => jsonResponse({ detail: RESTRICTED_DETAIL, status: 403 }, 403))
    renderWithAccess(<EntityCrudPage entityType="tag" writes={BILIMBAGA_WRITES} />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-edit-r1'))
    fireEvent.click(byTestId('entity-form-submit'))
    await settle()

    const banner = byTestId('entity-form-error-banner')
    expect(banner).toHaveTextContent(entitiesMessages.en['entities.crud.form.restrictedFieldError'])
    expect(banner).not.toHaveTextContent(RESTRICTED_DETAIL)
  })

  it('a 404 on update shows the error banner with the route’s message', async () => {
    installMocks('tag', TAG_FIELDS)
    fetchSpy.mockImplementation(() => jsonResponse({ title: 'Not Found', status: 404 }, 404))
    renderWithAccess(<EntityCrudPage entityType="tag" writes={BILIMBAGA_WRITES} />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-edit-r1'))
    fireEvent.click(byTestId('entity-form-submit'))
    await settle()

    expect(byTestId('entity-form-error-banner')).toHaveTextContent('Not Found')
  })

  it('a failed delete (409) shows the delete error message', async () => {
    installMocks('tag', TAG_FIELDS)
    fetchSpy.mockImplementation(() => jsonResponse({ title: 'Conflict', type: 'stale_version' }, 409))
    renderWithAccess(<EntityCrudPage entityType="tag" writes={BILIMBAGA_WRITES} />, 'platformAdmin')

    fireEvent.click(screen.getByTestId('entity-delete-r1'))
    fireEvent.click(byTestId('confirm-dialog-confirm'))
    await settle()

    expect(byText(entitiesMessages.en['entities.crud.delete.error'])).toBeInTheDocument()
  })
})

describe('GH 2680 — write controls follow the screen’s permission', () => {
  it('a user with EntitiesRecordsWrite but not ExamAuthoringWrite sees no write controls on a BilimBaga type', () => {
    installMocks('tag', TAG_FIELDS)
    renderWithAccess(<EntityCrudPage entityType="tag" writes={BILIMBAGA_WRITES} />, 'operator')

    expect(screen.getByText('security')).toBeInTheDocument()
    expect(screen.queryByTestId('entity-create-action')).not.toBeInTheDocument()
    expect(screen.queryByTestId('entity-edit-r1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('entity-delete-r1')).not.toBeInTheDocument()
  })

  it('the same user keeps the write controls on the default path (EntitiesRecordsWrite)', () => {
    installMocks('tag', TAG_FIELDS)
    renderWithAccess(<EntityCrudPage entityType="tag" />, 'operator')

    expect(screen.getByTestId('entity-create-action')).toBeInTheDocument()
    expect(screen.getByTestId('entity-edit-r1')).toBeInTheDocument()
    expect(screen.getByTestId('entity-delete-r1')).toBeInTheDocument()
  })

  it('a tenant admin (ExamAuthoringWrite) sees the write controls on a BilimBaga type', () => {
    installMocks('tag', TAG_FIELDS)
    renderWithAccess(<EntityCrudPage entityType="tag" writes={BILIMBAGA_WRITES} />, 'tenantAdmin')

    expect(screen.getByTestId('entity-create-action')).toBeInTheDocument()
    expect(screen.getByTestId('entity-edit-r1')).toBeInTheDocument()
    expect(screen.getByTestId('entity-delete-r1')).toBeInTheDocument()
  })
})
