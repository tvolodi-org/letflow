// @vitest-environment jsdom
/**
 * REQ-366 §2.2 — useHelpContent
 *
 * TC-REQ366-01: isLoading -> { status: 'loading' }
 * TC-REQ366-02: isError with ApiError.status === 404 -> { status: 'not-found' },
 *   NOT { status: 'error' } — design §2.2.1's own explicit requirement (a 404 is
 *   the common case, not an error toast).
 * TC-REQ366-03: isError with a genuine 5xx/network ApiError -> { status: 'error' }
 * TC-REQ366-04: data present -> { status: 'ready', content }
 *
 * `useQuery` itself is mocked (this codebase's own test convention — see
 * src/modules/exam/__tests__/ExamListPage.test.tsx) so this test exercises
 * useHelpContent's own branching logic in isolation, not TanStack Query's
 * internals.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'

const mockUseQuery = vi.fn()

vi.mock('@tanstack/react-query', () => ({
  useQuery: (...args: unknown[]) => mockUseQuery(...args),
}))

vi.mock('@/api/help', () => ({
  helpApi: { getResolved: vi.fn() },
}))

// REQ-384: useHelpContent now resolves a tenant-scoped query key via
// useTenantScopedQueryKeys(), which reads useAuth().session.tenant_id. This
// suite exercises only the hook's own status-branching logic (useQuery is
// mocked entirely), so a fixed authenticated session is sufficient here.
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: 'oidc',
      tenant_slug: 'fixture-tenant',
      tenant_display_name: 'Fixture Tenant',
      tenant_id: 'tid-help-content',
      tenant_type: 'test',
      production_tenant_display_name: null,
    },
    isAuthenticated: true,
  }),
}))

import { useHelpContent } from '../useHelpContent'
import type { ResolvedHelpContent } from '@/types/help'

afterEach(() => {
  vi.clearAllMocks()
})

describe('useHelpContent', () => {
  it('TC-REQ366-01: loading', () => {
    mockUseQuery.mockReturnValue({ isLoading: true, isError: false, data: undefined, error: undefined })
    const { result } = renderHook(() => useHelpContent('exam-list'))
    expect(result.current).toEqual({ status: 'loading' })
  })

  it('TC-REQ366-02: a 404 ApiError resolves to not-found, not error', () => {
    mockUseQuery.mockReturnValue({
      isLoading: false,
      isError: true,
      data: undefined,
      error: { status: 404, message: 'Not Found', code: '404' },
    })
    const { result } = renderHook(() => useHelpContent('exam-list'))
    expect(result.current).toEqual({ status: 'not-found' })
  })

  it('TC-REQ366-03: a non-404 ApiError resolves to error', () => {
    const error = { status: 500, message: 'boom', code: '500' }
    mockUseQuery.mockReturnValue({ isLoading: false, isError: true, data: undefined, error })
    const { result } = renderHook(() => useHelpContent('exam-list'))
    expect(result.current).toEqual({ status: 'error', error })
  })

  it('TC-REQ366-04: data present resolves to ready with the content', () => {
    const content: ResolvedHelpContent = {
      id: 'help-1',
      screenId: 'exam-list',
      processDefinitionId: null,
      title: 'Exam list help',
      body: 'Body text',
      status: 'live',
      confirmedAt: '2026-09-01T00:00:00Z',
      confirmedForDefinitionVersion: null,
      media: [],
      scope: 'tenant',
      stale: false,
    }
    mockUseQuery.mockReturnValue({ isLoading: false, isError: false, data: content, error: undefined })
    const { result } = renderHook(() => useHelpContent('exam-list'))
    expect(result.current).toEqual({ status: 'ready', content })
  })
})
