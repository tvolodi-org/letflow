// @vitest-environment jsdom
/**
 * Tests for AppShell.tsx's branding integration — REQ-283 (0020 D1c, theming
 * half).
 *
 * Covers AC6 (a non-default app_name replaces the hard-coded "Letflow" text
 * node in the sidebar) and AC4/AC5's rendered-<img> assertion (a markup- or
 * javascript:-scheme logo_url renders as exactly one plain <img>, never
 * interpreted as markup, never executed).
 *
 * DIRECTIVE T-2: no msw/raw-fetch mocking — client.get is mocked directly, and
 * useAuth / useQuery are mocked the same way web/src/pages/admin/tenants/
 * __tests__/TenantsPage.test.tsx already mocks them, so this test exercises
 * AppShell's own rendering without needing a live backend, a QueryClient, or a
 * real OIDC session.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import type { UserSession } from '@/types/api'

expect.extend(jestDomMatchers)

vi.mock('@tanstack/react-query', () => ({
  useQuery: vi.fn(() => ({ data: undefined })),
}))

vi.mock('@/auth/AuthContext', () => ({
  useAuth: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  client: { get: vi.fn() },
}))

const SESSION: UserSession = {
  token: 'tok',
  display_name: 'Test User',
  loginSource: null,
  tenant_slug: 'acme',
  tenant_display_name: 'Acme Co',
  tenant_id: 'tid-acme',
  tenant_type: 'production',
  production_tenant_display_name: null,
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  document.documentElement.removeAttribute('style')
})

async function renderAppShellWithBranding(brandingConfig: unknown) {
  vi.resetModules()

  const { useAuth } = await import('@/auth/AuthContext')
  vi.mocked(useAuth).mockReturnValue({
    session: SESSION,
    isAuthenticated: true,
    isLoading: false,
    loginSource: null,
    login: vi.fn(),
    logout: vi.fn(),
    setSession: vi.fn(),
    switchTenant: vi.fn(),
    switchingToTenantSlug: null,
  })

  const clientModule = await import('@/api/client')
  vi.mocked(clientModule.client.get).mockImplementation(((url: string) => {
    if (url === '/api/tenant-config') return Promise.resolve(brandingConfig)
    // health check and dlq list (or any other endpoint AppShell's tree calls):
    // resolve harmlessly, irrelevant to this test's assertions.
    return Promise.resolve({ items: [] })
  }) as never)

  const { BrandingProvider } = await import('@/theming/BrandingProvider')
  const { AppShell } = await import('../AppShell')
  const { AccessStateProvider } = await import('@/auth/access/AccessContext')
  const { accessState } = await import('@/auth/access/fixtures')

  render(
    <MemoryRouter initialEntries={['/instances']}>
      <BrandingProvider>
        <AccessStateProvider state={accessState('platformAdmin')}>
          <AppShell />
        </AccessStateProvider>
      </BrandingProvider>
    </MemoryRouter>,
  )
}

describe('AppShell branding integration', () => {
  it('AC6: a non-default app_name replaces the hard-coded "Letflow" sidebar text', async () => {
    await renderAppShellWithBranding({
      oidc_authority: 'http://example.invalid/realm',
      client_id: 'letflow-web',
      branding: {
        app_name: 'Acme Robotics',
        logo_url: null,
        brand_colors: {},
      },
    })

    await waitFor(() => {
      expect(screen.getByText('Acme Robotics')).toBeInTheDocument()
    })
    expect(screen.queryByText('Letflow')).not.toBeInTheDocument()
  })

  it('renders the hard-coded "Letflow" default before/without tenant branding', async () => {
    await renderAppShellWithBranding({
      oidc_authority: 'http://example.invalid/realm',
      client_id: 'letflow-web',
    })

    await waitFor(() => {
      expect(screen.getByText('Letflow')).toBeInTheDocument()
    })
  })

  it('AC4/AC5: a markup-injection logo_url renders as exactly one plain <img>, never interpreted as HTML', async () => {
    const malicious = '"><img src=x onerror=window.__pwned=true>'

    await renderAppShellWithBranding({
      oidc_authority: 'http://example.invalid/realm',
      client_id: 'letflow-web',
      branding: {
        app_name: 'Acme Robotics',
        logo_url: malicious,
        brand_colors: {},
      },
    })

    await waitFor(() => {
      const imgs = document.body.querySelectorAll('img')
      expect(imgs.length).toBe(1)
    })

    const imgs = document.body.querySelectorAll('img')
    expect(imgs).toHaveLength(1)
    // Proof it was treated as an opaque URL string, never parsed as markup.
    expect(imgs[0].getAttribute('src')).toBe(malicious)
    // alt is derived only from appName, never from logo_url.
    expect(imgs[0].getAttribute('alt')).toBe('Acme Robotics')
    expect(document.body.querySelectorAll('[onerror]').length).toBe(0)
    expect((window as unknown as { __pwned?: boolean }).__pwned).toBeUndefined()
  })

  it('AC4/AC5 (javascript: scheme): a javascript: logo_url is rendered as a literal src, never executed', async () => {
    const jsScheme = 'javascript:window.__pwned3=true'

    await renderAppShellWithBranding({
      oidc_authority: 'http://example.invalid/realm',
      client_id: 'letflow-web',
      branding: {
        app_name: 'Acme Robotics',
        logo_url: jsScheme,
        brand_colors: {},
      },
    })

    await waitFor(() => {
      const imgs = document.body.querySelectorAll('img')
      expect(imgs.length).toBe(1)
    })

    expect((window as unknown as { __pwned3?: boolean }).__pwned3).toBeUndefined()
  })

  it('renders no <img> when logo_url is null (default/no-branding case)', async () => {
    await renderAppShellWithBranding({
      oidc_authority: 'http://example.invalid/realm',
      client_id: 'letflow-web',
      branding: {
        app_name: 'Acme Robotics',
        logo_url: null,
        brand_colors: {},
      },
    })

    await waitFor(() => {
      expect(screen.getByText('Acme Robotics')).toBeInTheDocument()
    })
    expect(document.body.querySelectorAll('img').length).toBe(0)
  })
})
