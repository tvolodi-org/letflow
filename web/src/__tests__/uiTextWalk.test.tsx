// @vitest-environment jsdom
/**
 * T-1553 W1-W3, P1: the text walk. For each walked core screen (Users, Instances, Definitions) and each UI language,
 * render the empty list, the failed load, the permission refusal and the refused save, and read the text of the
 * STATE ELEMENT only (a testid), never the page: those screens stay English around the state text, so a page-wide
 * check would pass or fail on page chrome. For ru/kk the text must equal the catalogue value and differ from en.
 * A refused save carries a server body with a snake_case code and a status number; neither may reach the element.
 * The asset, stock, Home and My Tasks screens have their own catalogue tests (registerErrors, countsErrors,
 * taskErrors, catalog-completeness); the table in docs/uat/ui-text-walk.md names them.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import React from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderWithAccess } from '@/auth/access/testing'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'
import { UI_LOCALES, useUiLocaleStore, type UiLocale } from '@/i18n/uiLocaleStore'
import { feedbackMessages, fillFeedback } from '@/components/ui/feedbackMessages'
import { uiMessages } from '@/components/ui/uiMessages'
import { usersMessages } from '@/pages/admin/usersMessages'
import { instancesMessages } from '@/pages/instances/instancesMessages'
import { definitionsMessages } from '@/pages/definitions/definitionsMessages'
expect.extend(jestDomMatchers)

// Shared mutable state of the mocks.
const ctl = {
  users: { items: [] as unknown[], isError: false, error: null as unknown },
  defs: { items: [] as unknown[], isError: false, error: null as unknown },
  createDefError: null as unknown,
  insts: { items: [] as unknown[], isError: false, error: null as unknown },
  startError: null as unknown,
}
const SERVER_BODY = { status: 422, message: 'insufficient_stock 409', code: 'insufficient_stock' }

vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    isAuthenticated: true,
    session: { token: 'tok', tenant_id: 'tid-1', tenant_slug: 't', tenant_display_name: 'T', tenant_type: 'production' },
  }),
}))
vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useNavigate: () => vi.fn(),
    useSearchParams: () => [new URLSearchParams(), vi.fn()],
    Link: ({ children, to }: { children: React.ReactNode; to: string }) =>
      React.createElement('a', { href: String(to) }, children),
  }
})
vi.mock('@tanstack/react-query', () => ({
  useQuery: () => ({
    data: { items: ctl.users.items },
    isLoading: false,
    isError: ctl.users.isError,
    error: ctl.users.error,
    refetch: vi.fn(),
  }),
  useMutation: (opts: { onError?: (e: unknown) => void }) => ({
    mutate: () => opts.onError?.(SERVER_BODY),
    isPending: false,
  }),
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))
vi.mock('@/api/useTenantScopedQueryKeys', () => ({
  useTenantScopedQueryKeys: () => ({
    admin: { users: () => ['users'], roles: () => ['roles'] },
    instances: { all: () => ['instances'] },
  }),
}))
vi.mock('@/hooks/useDefinitions', () => ({
  useDefinitions: () => ({
    data: { items: ctl.defs.items },
    isLoading: false,
    isError: ctl.defs.isError,
    error: ctl.defs.error,
    refetch: vi.fn(),
  }),
  useDefinition: () => ({ data: undefined, isLoading: false }),
  useDefinitionsByIds: () => ({ definitions: new Map(), pending: new Set() }),
  useDefinitionVersions: () => ({ data: undefined, isLoading: false }),
  useActivateDefinition: () => ({ mutate: vi.fn(), isPending: false }),
  useArchiveDefinition: () => ({ mutate: vi.fn(), isPending: false }),
  useCreateDefinition: () => ({
    mutateAsync: () => Promise.reject(ctl.createDefError),
    isPending: false,
  }),
  useDefinitionSearch: () => ({ data: undefined, isLoading: false, isFetching: false }),
  definitionKeys: { all: ['definitions'], list: () => ['definitions', 'list'] },
}))
vi.mock('@/hooks/useInstances', () => ({
  useInstances: () => ({
    data: { items: ctl.insts.items, next_cursor: null },
    isLoading: false,
    isError: ctl.insts.isError,
    error: ctl.insts.error,
    isRefetching: false,
  }),
  useStartInstance: () => ({
    mutateAsync: () => Promise.reject(ctl.startError),
    isPending: false,
  }),
  instanceKeys: { all: ['instances'], list: (f: unknown) => ['instances', 'list', f] },
}))
vi.mock('@/hooks/usePolling', () => ({
  usePolling: () => ({ lastRefreshedAt: null, refreshNow: vi.fn(), refreshCount: 0 }),
}))
vi.mock('@/api/definitions', () => ({ definitionsApi: { importJson: vi.fn() } }))

import UsersPage from '@/pages/admin/UsersPage'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'
import { PermissionDenied } from '@/components/ui/PermissionDenied'
import { RateLimitBackpressure } from '@/components/ui/RateLimitBackpressure'

const FAILED_LOAD = { status: 500, message: 'internal_error 500', code: 'internal_error' }
const FORBIDDEN = { status: 403, message: 'forbidden', code: 'forbidden' }

/** Error and refusal elements only: no technical code, status number next to an HTTP/status token, or JS residue. */
function expectNoTechnicalCode(text: string): void {
  expect(text).not.toMatch(/\b[a-z]+(_[a-z0-9]+)+\b/)
  expect(text).not.toMatch(/\b(HTTP|status)\s*[1-5]\d\d\b/i)
  expect(text).not.toMatch(/\[object|undefined|null|Exception|Error:/)
}

/** The text of the state element equals `expected` for the locale and, in ru/kk, differs from the en text. */
function expectLocaleText(actual: string, expected: string, en: string, locale: UiLocale, key: string): void {
  expect(actual.trim()).not.toBe('')
  expect(actual).toBe(expected)
  if (locale !== 'en') expect(actual, `${key}: ${locale} text is the English one`).not.toBe(en)
}

function reset(): void {
  ctl.users = { items: [], isError: false, error: null }
  ctl.defs = { items: [], isError: false, error: null }
  ctl.insts = { items: [], isError: false, error: null }
  ctl.createDefError = SERVER_BODY
  ctl.startError = SERVER_BODY
}

beforeEach(reset)
afterEach(() => {
  cleanup()
  useUiLocaleStore.getState().setLocaleTransient('en')
})

describe.each(UI_LOCALES)('T-1553 text walk, locale %s', (locale) => {
  const fb = feedbackMessages[locale]
  beforeEach(() => {
    useUiLocaleStore.getState().setLocaleTransient(locale)
  })

  describe('W1 empty lists', () => {
    it('Users: empty text and next step', () => {
      renderWithAccess(<UsersPage />, 'tenantAdmin')
      const el = within(screen.getByTestId('admin-users-table')).getByTestId('datatable-empty-state')
      const m = usersMessages[locale]
      expect(el.textContent).toContain(m.empty)
      expect(el.textContent).toContain(m.emptyHint)
      expectLocaleText(m.empty, m.empty, usersMessages.en.empty, locale, 'users.empty')
      if (locale !== 'en') expect(el.textContent).not.toContain(usersMessages.en.empty)
    })

    it('Instances: empty text and next step', () => {
      render(
        <AccessStateProvider state={accessState('operator')}>
          <InstanceBoardPage />
        </AccessStateProvider>,
      )
      const el = within(screen.getByTestId('instance-board-table')).getByTestId('datatable-empty-state')
      const m = instancesMessages[locale]
      expect(el.textContent).toContain(m.empty)
      expect(el.textContent).toContain(m.emptyHint)
      if (locale !== 'en') expect(el.textContent).not.toContain(instancesMessages.en.empty)
    })

    it('Definitions: empty text and next step', () => {
      renderWithAccess(<DefinitionListPage />, 'platformAdmin')
      const el = screen.getByTestId('empty-state')
      const m = definitionsMessages[locale]
      expect(el.textContent).toContain(m.empty)
      expect(el.textContent).toContain(m.emptyHint)
      if (locale !== 'en') expect(el.textContent).not.toContain(definitionsMessages.en.empty)
    })

    it('Definitions: empty search text interpolates the term as text', () => {
      const m = definitionsMessages[locale]
      expect(fillFeedback(m.emptySearch, { term: '<b>x</b>' })).toContain('<b>x</b>')
    })
  })

  describe('W2 failed load and refusal', () => {
    it.each([
      ['Users', () => (ctl.users = { items: [], isError: true, error: FAILED_LOAD }), () => renderWithAccess(<UsersPage />, 'tenantAdmin')],
      ['Definitions', () => (ctl.defs = { items: [], isError: true, error: FAILED_LOAD }), () => renderWithAccess(<DefinitionListPage />, 'platformAdmin')],
      [
        'Instances',
        () => (ctl.insts = { items: [], isError: true, error: FAILED_LOAD }),
        () =>
          render(
            <AccessStateProvider state={accessState('operator')}>
              <InstanceBoardPage />
            </AccessStateProvider>,
          ),
      ],
    ])('%s: failed load shows the catalogue text, no code', (_name, arrange, view) => {
      arrange()
      view()
      const alert = screen.getByRole('alert')
      expectLocaleText(alert.textContent ?? '', `${uiMessages[locale].loadError}${uiMessages[locale].retry}`, `${uiMessages.en.loadError}${uiMessages.en.retry}`, locale, 'ui.loadError')
      expectNoTechnicalCode(alert.textContent ?? '')
    })

    it('Users: a 403 shows the translated permission text', () => {
      ctl.users = { items: [], isError: true, error: FORBIDDEN }
      renderWithAccess(<UsersPage />, 'tenantAdmin')
      const el = screen.getByTestId('permission-denied')
      expect(el.textContent).toContain(fb.permissionDenied)
      if (locale !== 'en') expect(el.textContent).not.toContain(feedbackMessages.en.permissionDenied)
      expectNoTechnicalCode(el.textContent ?? '')
    })
  })

  describe('W3 refused save', () => {
    it('Definitions create: 422 with a code body shows the status-class text only', async () => {
      renderWithAccess(<DefinitionListPage />, 'platformAdmin')
      fireEvent.click(screen.getByTestId('btn-new-definition'))
      fireEvent.change(screen.getByTestId('create-name-input'), { target: { value: 'p' } })
      fireEvent.change(screen.getByTestId('create-version-input'), { target: { value: '1.0.0' } })
      fireEvent.click(screen.getByTestId('create-submit'))
      const el = await screen.findByTestId('def-create-error')
      expectLocaleText(el.textContent ?? '', fb.saveInvalid, feedbackMessages.en.saveInvalid, locale, 'save.invalid')
      expectNoTechnicalCode(el.textContent ?? '')
      expect(el.textContent).not.toContain('insufficient_stock')
    })

    it('Instances start: 422 with a code body shows the status-class text only', async () => {
      ctl.defs = { items: [{ id: 'def-1', name: 'sample-process', version: '2.0.0', status: 'ACTIVE' }], isError: false, error: null }
      render(
        <AccessStateProvider state={accessState('operator')}>
          <InstanceBoardPage />
        </AccessStateProvider>,
      )
      fireEvent.click(screen.getByTestId('start-instance-button'))
      fireEvent.change(await screen.findByTestId('start-definition-name'), { target: { value: 'sample-process' } })
      fireEvent.click(screen.getByTestId('submit-start-instance'))
      const el = await screen.findByTestId('start-instance-error')
      expectLocaleText(el.textContent ?? '', fb.saveInvalid, feedbackMessages.en.saveInvalid, locale, 'save.invalid')
      expectNoTechnicalCode(el.textContent ?? '')
    })

    it('Users create: a refused create shows the status-class text only', async () => {
      renderWithAccess(<UsersPage />, 'tenantAdmin')
      fireEvent.click(screen.getByText(usersMessages[locale].newUser))
      fireEvent.click(screen.getAllByText(usersMessages[locale].createUser)[1])
      const el = await screen.findByTestId('admin-users-save-error')
      expectLocaleText(el.textContent ?? '', fb.saveInvalid, feedbackMessages.en.saveInvalid, locale, 'save.invalid')
      expectNoTechnicalCode(el.textContent ?? '')
    })
  })

  describe('T-1716 whole pages', () => {
    /** Every catalogue value is used by the page text and, in ru/kk, none is the English string. */
    function expectCatalogue<T extends object>(table: Record<UiLocale, T>, keys: (keyof T)[]): void {
      for (const k of keys) {
        const v = String(table[locale][k])
        expect(v.trim(), String(k)).not.toBe('')
        if (locale !== 'en') expect(v, `${String(k)} is English in ${locale}`).not.toBe(String(table.en[k]))
      }
    }

    it('catalogues are complete and translated', () => {
      for (const table of [usersMessages, instancesMessages, definitionsMessages] as unknown as Record<UiLocale, Record<string, string>>[]) {
        expect(Object.keys(table[locale]).sort()).toEqual(Object.keys(table.en).sort())
      }
      expectCatalogue(usersMessages, ['title', 'newUser', 'apply', 'createUser', 'cancel', 'username', 'roles', 'saved', 'deactivated'])
      expectCatalogue(instancesMessages, ['title', 'startInstance', 'refresh', 'colInstanceId', 'cancel', 'start'])
      expectCatalogue(definitionsMessages, ['title', 'importButton', 'newDefinition', 'colName', 'create', 'cancel'])
    })

    it('Users: heading, buttons and column headers follow the language', () => {
      renderWithAccess(<UsersPage />, 'tenantAdmin')
      const m = usersMessages[locale]
      expect(screen.getByRole('heading', { level: 2 }).textContent).toBe(m.title)
      expect(screen.getByText(m.newUser)).toBeTruthy()
      expect(screen.getByText(m.apply)).toBeTruthy()
      expect(screen.getByPlaceholderText(m.searchPlaceholder)).toBeTruthy()
      fireEvent.click(screen.getByText(m.newUser))
      expect(screen.getByLabelText(m.displayName)).toBeTruthy()
      expect(screen.getByLabelText(m.password)).toBeTruthy()
    })

    it('Definitions: title and actions follow the language', () => {
      renderWithAccess(<DefinitionListPage />, 'platformAdmin')
      const m = definitionsMessages[locale]
      expect(screen.getByText(m.title)).toBeTruthy()
      expect(screen.getByTestId('btn-import-definition').textContent).toBe(m.importButton)
      expect(screen.getByTestId('btn-new-definition').textContent).toBe(m.newDefinition)
      expect(screen.getByTestId('definition-search').getAttribute('placeholder')).toBe(m.searchPlaceholder)
      fireEvent.click(screen.getByTestId('btn-new-definition'))
      fireEvent.click(screen.getByTestId('create-submit'))
      expect(screen.getByText(m.nameRequired)).toBeTruthy()
    })

    it('Instances: title, start dialog and refresh follow the language', async () => {
      render(
        <AccessStateProvider state={accessState('operator')}>
          <InstanceBoardPage />
        </AccessStateProvider>,
      )
      const m = instancesMessages[locale]
      expect(screen.getByRole('heading', { level: 2 }).textContent).toBe(m.title)
      expect(screen.getByTestId('start-instance-button').textContent).toBe(m.startInstance)
      expect(screen.getByText(m.refresh)).toBeTruthy()
      fireEvent.click(screen.getByTestId('start-instance-button'))
      expect(await screen.findByLabelText(m.definitionName)).toBeTruthy()
      expect(screen.getByLabelText(m.initialVariables)).toBeTruthy()
      expect(screen.getByTestId('submit-start-instance').textContent).toBe(m.start)
    })
  })

  describe('P1 shared surfaces', () => {
    it('PermissionDenied', () => {
      renderWithAccess(<PermissionDenied />, 'tenantAdmin')
      expect(screen.getByTestId('permission-denied').textContent).toContain(fb.permissionDenied)
    })

    it('RateLimitBackpressure with and without a surface label', () => {
      render(<RateLimitBackpressure retryAfter={7} onRetry={() => undefined} surfaceLabel="X" />)
      expect(screen.getByTestId('rate-limit-backpressure').textContent).toContain(
        fillFeedback(fb.rateLimitSurface, { surface: 'X' }),
      )
      expect(screen.getByTestId('retry-countdown').textContent).toBe(fillFeedback(fb.retryIn, { n: 7 }))
      expect(screen.getByTestId('rate-limit-retry-now').textContent).toBe(fb.retryNow)
    })
  })
})
