// @vitest-environment jsdom
/**
 * GH #2238 (REQ-450, slice 2b): Reject / Approve / Apply on a promotion review
 * are write controls. The server gates approve|reject|apply with
 * PromotionsManage (lib/letflow/api/authorization.ex); a viewer who only holds
 * PromotionsRead (the auditor) sees the review state but no action buttons.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { screen, cleanup } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router-dom'

expect.extend(jestDomMatchers)

vi.mock('@/auth/AuthContext', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/auth/AuthContext')>()
  return {
    ...actual,
    useAuth: () => ({
      session: {
        token: 'header.' + btoa(JSON.stringify({ sub: 'reviewer-id' })) + '.sig',
        display_name: 'Reviewer',
        loginSource: 'oidc' as const,
        tenant_slug: null,
        tenant_display_name: null,
        tenant_id: 'tenant-1',
        tenant_type: null,
      },
      isAuthenticated: true,
      isLoading: false,
      loginSource: 'oidc' as const,
      login: vi.fn(),
      logout: vi.fn(),
      setSession: vi.fn(),
    }),
  }
})

const CONTEXT = {
  review: {
    id: 'review-1',
    tenant_id: 'tenant-1',
    plan_digest: 'abc123',
    def_type: 'process',
    def_id: 'def-1',
    serialised_plan: '{}',
    status: 'pending_review',
    requested_by: 'someone-else',
    approved_by: null,
    approved_at: null,
    superseded_by: null,
    row_version: 1,
    created_at: '2026-10-22T00:00:00Z',
    updated_at: '2026-10-22T00:00:00Z',
  },
  plan: { entries: [] },
  digest_verified: true,
  assertions: [],
}

vi.mock('@/hooks/usePromotions', () => {
  const mutation = () => ({ mutateAsync: vi.fn().mockResolvedValue(undefined), isPending: false })
  return {
    usePromotionContext: () => ({
      data: CONTEXT,
      isLoading: false,
      isError: false,
      error: null,
      refetch: vi.fn(),
    }),
    useApprovePromotion: mutation,
    useRejectPromotion: mutation,
    useApplyPromotion: mutation,
  }
})

import PromotionReviewPage from '@/pages/definitions/PromotionReviewPage'
import { renderWithAccess } from '@/auth/access/testing'
import type { AccessFixtureName } from '@/auth/access/fixtures'

afterEach(cleanup)

function renderPage(fixture: AccessFixtureName) {
  return renderWithAccess(
    <MemoryRouter initialEntries={['/definitions/def-1/promotions/review-1']}>
      <Routes>
        <Route path="/definitions/:id/promotions/:reviewId" element={<PromotionReviewPage />} />
      </Routes>
    </MemoryRouter>,
    fixture,
  )
}

describe('PromotionReviewPage action controls by permission', () => {
  it('an auditor sees the review but no Reject, Approve or Apply button', () => {
    renderPage('auditor')
    expect(screen.getByTestId('non-skippable-approval-gate')).toBeInTheDocument()
    expect(screen.queryByTestId('reject-btn')).not.toBeInTheDocument()
    expect(screen.queryByTestId('approve-btn')).not.toBeInTheDocument()
    expect(screen.queryByTestId('apply-btn')).not.toBeInTheDocument()
  })

  it.each(['platformAdmin', 'tenantAdmin'] as AccessFixtureName[])(
    'a %s (PromotionsManage) sees Reject, Approve and Apply',
    (fixture) => {
      renderPage(fixture)
      expect(screen.getByTestId('reject-btn')).toBeInTheDocument()
      expect(screen.getByTestId('approve-btn')).toBeInTheDocument()
      expect(screen.getByTestId('apply-btn')).toBeInTheDocument()
    },
  )
})
