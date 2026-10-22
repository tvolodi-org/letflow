// @vitest-environment jsdom
/**
 * Unit tests — ENV-04: TestEnvironmentBanner component
 *
 * TC-ENV04-01: renders the TEST ENVIRONMENT banner (and no pairing text) when tenant_type is test
 * TC-ENV04-02: does NOT render banner when tenant_type is production
 * TC-ENV04-03: does NOT render banner when tenant_type is null (REQ-470)
 */

import { describe, it, expect, vi, afterEach } from 'vitest'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, screen, cleanup } from '@testing-library/react'
expect.extend(jestDomMatchers)

vi.mock('@/auth/useTenantContext')

import { TestEnvironmentBanner } from '../TestEnvironmentBanner'
import { useTenantContext } from '@/auth/useTenantContext'

const mockUseTenantContext = vi.mocked(useTenantContext)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const ctx = (tenantType: 'test' | 'production' | null) => ({
  tenantType,
  tenantSlug: 'acme',
  tenantId: 'tid-001',
  tenantDisplayName: 'Acme',
  isUnknown: false,
})

describe('ENV-04 — TestEnvironmentBanner', () => {
  it('TC-ENV04-01: renders TEST ENVIRONMENT banner without pairing text when tenantType is test', () => {
    mockUseTenantContext.mockReturnValue(ctx('test'))

    render(<TestEnvironmentBanner />)

    expect(screen.getByTestId('test-environment-banner')).toBeInTheDocument()
    expect(screen.getByText('TEST ENVIRONMENT')).toBeVisible()
    expect(screen.queryByText(/Paired with/)).not.toBeInTheDocument()
  })

  it('TC-ENV04-02: does NOT render banner when tenantType is production', () => {
    mockUseTenantContext.mockReturnValue(ctx('production'))

    const { container } = render(<TestEnvironmentBanner />)

    expect(container).toBeEmptyDOMElement()
    expect(screen.queryByTestId('test-environment-banner')).not.toBeInTheDocument()
  })

  it('TC-ENV04-03: does NOT render banner when tenantType is null', () => {
    mockUseTenantContext.mockReturnValue(ctx(null))

    const { container } = render(<TestEnvironmentBanner />)

    expect(container).toBeEmptyDOMElement()
  })
})
