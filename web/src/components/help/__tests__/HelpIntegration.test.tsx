// @vitest-environment jsdom
/**
 * REQ-366 -- full-stack frontend integration test for the help panel.
 *
 * Every other test file under `web/src/components/help/__tests__/` and
 * `web/src/hooks/__tests__/useHelpContent.test.ts` mocks the layer directly
 * beneath the unit under test (`HelpTrigger` mocks `useHelpContent`;
 * `useHelpContent` mocks `@tanstack/react-query`'s `useQuery` itself;
 * `StalenessBadge`/`HelpPanel` are exercised only with hardcoded props). None
 * of them exercises the real chain a user actually depends on: a real
 * `useQuery` (via a real `QueryClient`), through the real `useHelpContent`
 * hook, into the real `HelpTrigger` -> `HelpPanel` -> `StalenessBadge` render
 * tree, driven by a realistic `GET /help/resolved` JSON payload. This file
 * closes that gap (TEST-DESIGNER pass, REQ-366 AC1/AC4) -- only `client.get`
 * itself is mocked, per this codebase's own DIRECTIVE T-2 unit-test exception
 * and `AppShell.branding.test.tsx`'s established "mock client.get directly,
 * use a real QueryClient" convention (no msw, no raw fetch).
 *
 * TC-REQ366-21: AC1 -- a real 200 response flows end-to-end: HelpTrigger
 *   renders once useHelpContent/useQuery resolve `ready`, and clicking it
 *   opens a HelpPanel showing the real fetched title/body -- not a
 *   hand-constructed prop.
 * TC-REQ366-22: AC1 -- a real 404 response (no help authored for this
 *   screen_id) renders nothing, end-to-end, not an error state (design
 *   §2.2.1) -- proven through the real ApiError shape client.get actually
 *   throws, not a hand-built {status:'not-found'} hook result.
 * TC-REQ366-23: AC4 -- a response with stale: true (server-computed, as
 *   `Letflow.Routers.Help.compute_stale/2` would produce after a real
 *   process-definition version bump -- see
 *   `test/letflow/routers/help_test.exs`'s own backend-side exercise of that
 *   comparison) renders the StalenessBadge's real "may be outdated" text
 *   through the full hook -> component chain, not a hardcoded
 *   `kind="stale"` prop.
 * TC-REQ366-24: AC4 -- a response with stale: false and a real confirmedAt
 *   renders "Last reviewed <date>" through the same full chain.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { HelpTrigger } from '../HelpTrigger'
import * as clientModule from '@/api/client'
import type { ResolvedHelpContentResponse } from '@/types/help'

expect.extend(jestDomMatchers)

vi.mock('@/api/client', () => ({
  client: { get: vi.fn() },
}))

// REQ-384: useHelpContent now resolves a tenant-scoped query key via
// useTenantScopedQueryKeys(), which reads useAuth().session.tenant_id. This
// integration test exercises the real useHelpContent/useQuery chain but was
// never wrapped in a real <AuthProvider> (it only mocks client.get, per this
// file's own moduledoc) -- a fixed, authenticated session mock is sufficient
// here since no test in this file asserts anything about auth/tenant
// identity itself.
vi.mock('@/auth/AuthContext', () => ({
  useAuth: () => ({
    session: {
      token: 'tok',
      display_name: 'Test User',
      loginSource: 'oidc',
      tenant_slug: 'fixture-tenant',
      tenant_display_name: 'Fixture Tenant',
      tenant_id: 'tid-help-integration',
      tenant_type: 'test',
    },
    isAuthenticated: true,
  }),
}))

afterEach(() => {
  vi.clearAllMocks()
  cleanup()
})

function renderWithClient(ui: React.ReactElement) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return render(<QueryClientProvider client={queryClient}>{ui}</QueryClientProvider>)
}

function liveResponse(
  overrides: Partial<ResolvedHelpContentResponse> = {},
): ResolvedHelpContentResponse {
  return {
    id: 'help-int-1',
    screen_id: 'exam-list',
    process_definition_id: null,
    title: 'Exam list help (from server)',
    body: 'Real fetched **markdown** body.',
    status: 'live',
    confirmed_at: '2026-09-10T00:00:00Z',
    confirmed_for_definition_version: null,
    media: [],
    scope: 'tenant',
    stale: false,
    ...overrides,
  }
}

describe('help panel -- real useQuery/useHelpContent/HelpTrigger/HelpPanel integration', () => {
  it('TC-REQ366-21: a real 200 flows end-to-end from client.get through to a rendered HelpPanel', async () => {
    vi.mocked(clientModule.client.get).mockResolvedValue(liveResponse())

    renderWithClient(<HelpTrigger screenId="exam-list" />)

    const trigger = await screen.findByTestId('help-trigger')
    fireEvent.click(trigger)

    expect(await screen.findByTestId('help-panel-title')).toHaveTextContent(
      'Exam list help (from server)',
    )
    expect(screen.getByTestId('help-panel-body')).toHaveTextContent('markdown')
    expect(clientModule.client.get).toHaveBeenCalledWith(
      '/api/v1/help/resolved',
      expect.objectContaining({ screen_id: 'exam-list' }),
    )
  })

  it('TC-REQ366-22: a real 404 ApiError renders nothing end-to-end, not an error state', async () => {
    vi.mocked(clientModule.client.get).mockRejectedValue({
      status: 404,
      message: 'Not Found',
      code: '404',
    })

    const { container } = renderWithClient(<HelpTrigger screenId="screen-with-no-help" />)

    await waitFor(() => expect(clientModule.client.get).toHaveBeenCalled())
    await waitFor(() => expect(container).toBeEmptyDOMElement())
    expect(screen.queryByTestId('help-trigger')).toBeNull()
  })

  it('TC-REQ366-23: a real stale:true payload renders the StalenessBadge "may be outdated" text end-to-end', async () => {
    vi.mocked(clientModule.client.get).mockResolvedValue(
      liveResponse({
        process_definition_id: 'def-1',
        confirmed_for_definition_version: '1.0.0',
        stale: true,
      }),
    )

    renderWithClient(
      <HelpTrigger screenId="process-screen" processDefinitionId="def-1" />,
    )

    fireEvent.click(await screen.findByTestId('help-trigger'))

    const badge = await screen.findByTestId('help-staleness-badge')
    expect(badge).toHaveAttribute('data-staleness', 'stale')
    expect(badge).toHaveTextContent(/outdated/i)
  })

  it('TC-REQ366-24: a real stale:false payload with confirmed_at renders "Last reviewed <date>" end-to-end', async () => {
    vi.mocked(clientModule.client.get).mockResolvedValue(
      liveResponse({ confirmed_at: '2026-09-10T00:00:00Z', stale: false }),
    )

    renderWithClient(<HelpTrigger screenId="exam-list" />)

    fireEvent.click(await screen.findByTestId('help-trigger'))

    const badge = await screen.findByTestId('help-staleness-badge')
    expect(badge).toHaveAttribute('data-staleness', 'reviewed')
    expect(badge).toHaveTextContent(/last reviewed/i)
  })
})
