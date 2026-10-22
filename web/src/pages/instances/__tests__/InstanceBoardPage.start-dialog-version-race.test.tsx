// @vitest-environment jsdom
/**
 * Unit tests — ISS-0911: Start Instance dialog's version field stuck empty
 * on late-resolving typeahead data.
 *
 * Root cause: `startDefinitionVersion`/`startDefinitionId` were a one-shot
 * `useState` write at keystroke time, matched only against whatever
 * `definitionTypeahead.items` held at that instant. If the `useDefinitions`
 * query was still in flight, the match failed and nothing ever re-checked
 * once the data arrived late. Fix: both are now derived (`useMemo`-backed
 * `matchedStartDefinition` plus two plain consts) so every render —
 * including the one triggered by the query finally resolving — recomputes
 * them. See lib/letflow/design/iss0911-start-instance-version-race.md and
 * docs/issues/ISS-0911.yaml.
 *
 * Mocking conventions mirror InstanceBoardPage.tenant-isolation.test.tsx:
 * `useDefinitions`/`useDefinition` are controllable `vi.fn()`s, not real
 * TanStack Query async timing, so the "late resolve" race is deterministic.
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react'
import React from 'react'
expect.extend(jestDomMatchers)

// ISS-0662: click handlers in this component defer their setState via
// deferClickState (setTimeout(fn, 0)) to avoid a real-click renderer freeze
// — flush that deferred macrotask with fake timers after every click on
// start-instance-button/submit-start-instance/etc, mirroring
// EntityCrudPage.test.tsx's established convention for the same utility.
function clickAndFlush(element: HTMLElement) {
  fireEvent.click(element)
  act(() => {
    vi.runAllTimers()
  })
}

// ── Mock dependencies before importing the component ─────────────────────────

vi.mock('@/hooks/useInstances', () => ({
  useInstances: vi.fn(() => ({
    data: { items: [], next_cursor: null },
    isLoading: false,
    error: null,
    isRefetching: false,
  })),
  useStartInstance: vi.fn(),
  instanceKeys: {
    all: ['instances'],
    list: (f: unknown) => ['instances', 'list', f],
    detail: (id: string) => ['instances', id],
    events: (id: string, f: unknown) => ['instances', id, 'events', f],
    timeline: (id: string, p: unknown) => ['instances', id, 'timeline', p],
  },
}))

vi.mock('@/hooks/useDefinitions', () => ({
  useDefinitions: vi.fn(),
  useDefinition: vi.fn(() => ({ data: undefined, isLoading: false })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/hooks/usePolling', () => ({
  usePolling: vi.fn(() => ({ lastRefreshedAt: null, refreshNow: vi.fn(), refreshCount: 0 })),
}))

vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual('@tanstack/react-query')
  return { ...(actual as object), useQueryClient: vi.fn(() => ({ invalidateQueries: vi.fn() })) }
})

const mockSetSearchParams = vi.fn()
let mockSearchParams = new URLSearchParams()

vi.mock('react-router-dom', async () => {
  const actual = await vi.importActual<typeof import('react-router-dom')>('react-router-dom')
  return {
    ...actual,
    useNavigate: vi.fn(() => vi.fn()),
    useSearchParams: vi.fn(() => [mockSearchParams, mockSetSearchParams]),
    Link: ({ children, to }: { children: React.ReactNode; to: string }) =>
      React.createElement('a', { href: String(to) }, children),
  }
})

// ── Imports after mocks ───────────────────────────────────────────────────────

import { useStartInstance } from '@/hooks/useInstances'
import { useDefinitions, useDefinition } from '@/hooks/useDefinitions'
import { useAuth } from '@/auth/AuthContext'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import { accessState } from '@/auth/access/fixtures'

const mockUseDefinitions = vi.mocked(useDefinitions)
const mockUseDefinition = vi.mocked(useDefinition)
const mockUseAuth = vi.mocked(useAuth)
const mockUseStartInstance = vi.mocked(useStartInstance)

// ── Fixtures ──────────────────────────────────────────────────────────────────

const TEST_SESSION = {
  token: 'tok',
  display_name: 'Alice',
  loginSource: null as null,
  tenant_slug: 'acme-test',
  tenant_display_name: 'Acme Test',
  tenant_id: 'tid-test-001',
  tenant_type: 'test' as const,
}

const AUTH_VALUE = {
  isAuthenticated: true,
  isLoading: false,
  loginSource: null as null,
  login: vi.fn(),
  logout: vi.fn(),
  setSession: vi.fn(),
  switchTenant: vi.fn(),
  switchingToTenantSlug: null,
  session: TEST_SESSION,
}

const SAMPLE_ITEM = { id: 'def-1', name: 'sample-process', version: '2.0.0', status: 'ACTIVE' as const }

const withAccess = (ui: React.ReactElement) => (
  <AccessStateProvider state={accessState('operator')}>{ui}</AccessStateProvider>
)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.useRealTimers()
  mockSearchParams = new URLSearchParams()
})

describe('ISS-0911 — Start Instance dialog version-race fix', () => {
  it('start-definition-version populates after late typeahead resolve (AC1/AC2/AC3)', () => {
    vi.useFakeTimers()
    mockUseAuth.mockReturnValue(AUTH_VALUE)

    // Phase 1: typeahead still loading, no data yet.
    mockUseDefinitions.mockReturnValue({ data: undefined, isLoading: true } as ReturnType<
      typeof useDefinitions
    >)
    mockUseDefinition.mockReturnValue({ data: undefined, isLoading: false } as ReturnType<
      typeof useDefinition
    >)

    const mutateAsync = vi.fn().mockResolvedValue({ instance_id: 'inst-1' })
    mockUseStartInstance.mockReturnValue({ mutateAsync, isPending: false } as unknown as ReturnType<
      typeof useStartInstance
    >)

    const { rerender } = render(withAccess(<InstanceBoardPage />))

    clickAndFlush(screen.getByTestId('start-instance-button'))

    fireEvent.change(screen.getByTestId('start-definition-name'), {
      target: { value: 'sample-process' },
    })

    // AC2: loading affordance visible, version still empty.
    const versionInput = screen.getByTestId('start-definition-version') as HTMLInputElement
    expect(versionInput.value).toBe('')
    expect(versionInput.getAttribute('placeholder')).toBe('Loading active version…')

    // AC3: submission still blocked while unresolved.
    clickAndFlush(screen.getByTestId('submit-start-instance'))
    expect(screen.getByText('Select a valid active definition name.')).toBeInTheDocument()
    expect(mutateAsync).not.toHaveBeenCalled()

    // Phase 2: the typeahead query resolves late.
    mockUseDefinitions.mockReturnValue({
      data: { items: [SAMPLE_ITEM] },
      isLoading: false,
    } as ReturnType<typeof useDefinitions>)

    rerender(withAccess(<InstanceBoardPage />))

    // AC1: field populates with no further interaction with the name input.
    const versionInputAfter = screen.getByTestId('start-definition-version') as HTMLInputElement
    expect(versionInputAfter.value).toBe('2.0.0')

    // AC3 converse: submission unblocks once the match resolves.
    clickAndFlush(screen.getByTestId('submit-start-instance'))
    expect(mutateAsync).toHaveBeenCalledWith(
      expect.objectContaining({ definition_id: 'def-1' }),
    )
  })

  it('no match found keeps version empty and validation blocked (negative control)', () => {
    vi.useFakeTimers()
    mockUseAuth.mockReturnValue(AUTH_VALUE)

    mockUseDefinitions.mockReturnValue({
      data: { items: [SAMPLE_ITEM] },
      isLoading: false,
    } as ReturnType<typeof useDefinitions>)
    mockUseDefinition.mockReturnValue({ data: undefined, isLoading: false } as ReturnType<
      typeof useDefinition
    >)
    mockUseStartInstance.mockReturnValue({
      mutateAsync: vi.fn(),
      isPending: false,
    } as unknown as ReturnType<typeof useStartInstance>)

    render(withAccess(<InstanceBoardPage />))

    clickAndFlush(screen.getByTestId('start-instance-button'))
    fireEvent.change(screen.getByTestId('start-definition-name'), {
      target: { value: 'does-not-exist' },
    })

    const versionInput = screen.getByTestId('start-definition-version') as HTMLInputElement
    expect(versionInput.value).toBe('')
    // isLoading: false means isResolvingStartDefinitionVersion must be false.
    expect(versionInput.getAttribute('placeholder')).toBe('')

    clickAndFlush(screen.getByTestId('submit-start-instance'))
    expect(screen.getByText('Select a valid active definition name.')).toBeInTheDocument()
  })

  it('page-level prefill still works when dialog opens with a known definitionId (AC4)', () => {
    vi.useFakeTimers()
    mockSearchParams = new URLSearchParams({ definitionId: 'def-1', definitionName: 'sample-process' })
    mockUseAuth.mockReturnValue(AUTH_VALUE)

    mockUseDefinitions.mockReturnValue({ data: undefined, isLoading: true } as ReturnType<
      typeof useDefinitions
    >)
    mockUseDefinition.mockReturnValue({
      data: { id: 'def-1', version: '3.1.0' },
      isLoading: false,
    } as ReturnType<typeof useDefinition>)
    mockUseStartInstance.mockReturnValue({
      mutateAsync: vi.fn(),
      isPending: false,
    } as unknown as ReturnType<typeof useStartInstance>)

    render(withAccess(<InstanceBoardPage />))

    // Open the dialog without typing anything new.
    clickAndFlush(screen.getByTestId('start-instance-button'))

    const versionInput = screen.getByTestId('start-definition-version') as HTMLInputElement
    expect(versionInput.value).toBe('3.1.0')
  })

  it('typed match does not leak stale URL definitionId into submit target (AC5, ISS-0891 guard)', () => {
    vi.useFakeTimers()
    // searchParams reports a stale definitionId that setSearchParams (a
    // no-op spy here, mirroring the tenant-isolation test's convention)
    // never actually updates within the test.
    mockSearchParams = new URLSearchParams({ definitionId: 'def-stale', definitionName: 'other-process' })
    mockUseAuth.mockReturnValue(AUTH_VALUE)

    mockUseDefinitions.mockReturnValue({
      data: { items: [SAMPLE_ITEM] },
      isLoading: false,
    } as ReturnType<typeof useDefinitions>)
    mockUseDefinition.mockReturnValue({
      data: { id: 'def-stale', version: '1.0.0' },
      isLoading: false,
    } as ReturnType<typeof useDefinition>)

    const mutateAsync = vi.fn().mockResolvedValue({ instance_id: 'inst-2' })
    mockUseStartInstance.mockReturnValue({ mutateAsync, isPending: false } as unknown as ReturnType<
      typeof useStartInstance
    >)

    render(withAccess(<InstanceBoardPage />))

    clickAndFlush(screen.getByTestId('start-instance-button'))
    // Type a name that matches a DIFFERENT id than the stale searchParams one.
    fireEvent.change(screen.getByTestId('start-definition-name'), {
      target: { value: 'sample-process' },
    })

    const versionInput = screen.getByTestId('start-definition-version') as HTMLInputElement
    expect(versionInput.value).toBe('2.0.0')

    clickAndFlush(screen.getByTestId('submit-start-instance'))
    expect(mutateAsync).toHaveBeenCalledWith(
      expect.objectContaining({ definition_id: 'def-1' }),
    )
    expect(mutateAsync).not.toHaveBeenCalledWith(
      expect.objectContaining({ definition_id: 'def-stale' }),
    )
  })
})
