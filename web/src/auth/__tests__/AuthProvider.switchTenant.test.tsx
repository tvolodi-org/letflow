// @vitest-environment jsdom
/**
 * REQ-384 §5.3/§7.3.1 — AuthProvider.switchTenant's cache-clear mechanism,
 * the core property AC3 depends on: on a successful silent switch, the
 * OUTGOING tenant's whole query-cache subtree is REMOVED (not merely
 * invalidated) BEFORE the new session is set. Full TEST-DESIGNER coverage
 * comes later in the pipeline; this file proves the load-bearing mechanism
 * directly against a real QueryClient (only the OIDC/token/tenant-lookup
 * boundary is mocked), per this codebase's own DIRECTIVE T-2 "mock the layer
 * directly beneath the unit under test" convention.
 *
 * TC-REQ384-07: a tenant-A-keyed cache entry populated before the switch is
 *   GONE (getQueryData returns undefined, not stale data) after a successful
 *   switch — proving removeQueries, not invalidateQueries, ran.
 * TC-REQ384-08: the session's tenant_id actually changes to the target
 *   tenant after a successful switch.
 * TC-REQ384-09: on 'interaction_required', the outgoing tenant's cache is
 *   left completely untouched — switchTenant's cache-clear step must only
 *   run after a CONFIRMED successful silent switch (design §6.1's own
 *   "a failed switch must not leave the user logged into neither tenant"
 *   guarantee, checked here at the cache layer).
 * TC-REQ384-22 (TEST-DESIGNER audit addition): the cache-isolation race
 *   SECURITY-REVIEWER analyzed — a straggler tenant-A fetch that was already
 *   in flight when the switch started, and whose queryFn ignores the abort
 *   signal and resolves LATE (after AuthProvider's own
 *   `cancelQueries`+`removeQueries` pair has already run) — must not
 *   repopulate the tenant-A-keyed cache entry. `cancelQueries` marks the
 *   in-flight fetch cancelled; TanStack Query discards a cancelled fetch's
 *   eventual resolution rather than writing it to the cache. Neither
 *   ELIXIR-DEV nor FRONTEND-DEV's inline coverage included a test that
 *   actually has an in-flight fetch racing the switch (TC-REQ384-07 only
 *   covers a fetch that already SETTLED before the switch, via
 *   `setQueryData`) — this closes that gap.
 */
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { render, cleanup, act } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
expect.extend(jestDomMatchers)

const { mockSetToken, mockAttemptSilentSwitch, mockGetBySlug } = vi.hoisted(() => ({
  mockSetToken: vi.fn(),
  mockAttemptSilentSwitch: vi.fn(),
  mockGetBySlug: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  clearToken: vi.fn(),
  setToken: mockSetToken,
  tryRestoreE2eSession: vi.fn(() => ({
    token: 'tok-a',
    display_name: 'Alice',
    tenant_slug: 'tenant-a',
    tenant_display_name: 'Tenant A',
    tenant_id: 'tid-a',
    tenant_type: 'production',
    production_tenant_display_name: null,
  })),
}))

vi.mock('../OidcManager', () => ({
  getOidcManager: vi.fn(async () => ({
    signoutRedirect: vi.fn(),
    signinRedirect: vi.fn(),
    events: { addAccessTokenExpiring: vi.fn(), removeAccessTokenExpiring: vi.fn() },
    startSilentRenew: vi.fn(),
  })),
}))

vi.mock('../tenantOidcRegistry', () => ({
  attemptSilentSwitch: mockAttemptSilentSwitch,
}))

// /me/access decides platform authority (the token's role claims are never read).
vi.mock('@/api/me', () => ({
  meApi: {
    getAccessWithToken: vi.fn(async () => ({
      roles: [],
      permissions: ['TenantsManage'],
      platform_tenant: true,
    })),
  },
}))

vi.mock('@/api/tenants', () => ({
  tenantsApi: {
    getBySlug: mockGetBySlug,
  },
}))

// A minimal, real-shaped (base64url header.payload.signature) JWT so
// decodeTokenPayload (the real, unmocked implementation) parses it. Payload:
// { roles: ["claimed"], tenant_id: "tenant-b", sub: "u1" }
const TENANT_B_TOKEN =
  'eyJhbGciOiJub25lIn0.' +
  'eyJyb2xlcyI6WyJQTEFURk9STV9BRE1JTiJdLCJ0ZW5hbnRfaWQiOiJ0ZW5hbnQtYiIsInN1YiI6InUxIn0.' +
  'sig'

import { AuthProvider } from '../AuthProvider'
import { AuthContext } from '../AuthContext'
import { tenantRoot } from '@/api/queryKeys'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function renderAuthProvider(queryClient: QueryClient) {
  let captured: import('../AuthContext').AuthContextValue | null = null

  function Capture() {
    return (
      <AuthContext.Consumer>
        {(value) => {
          captured = value ?? null
          return null
        }}
      </AuthContext.Consumer>
    )
  }

  render(
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Capture />
      </AuthProvider>
    </QueryClientProvider>,
  )

  return () => captured
}

describe('AuthProvider.switchTenant — REQ-384 §5.3/§7.3.1 cache-clear mechanism', () => {
  it('TC-REQ384-07/08: a successful switch REMOVES the outgoing tenant\'s cache subtree and updates session.tenant_id', async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    // Seed a tenant-A-keyed cache entry, mirroring what a real screen would
    // have populated via useInstances() before the switch.
    const tenantAKey = ['tenant', 'tid-a', 'instances', 'list', {}] as const
    queryClient.setQueryData(tenantAKey, { items: [{ instance_id: 'tenant-a-only' }], next_cursor: null })
    expect(queryClient.getQueryData(tenantAKey)).toBeDefined()

    mockAttemptSilentSwitch.mockResolvedValue({
      outcome: 'silent_ok',
      user: { access_token: TENANT_B_TOKEN },
    })
    mockGetBySlug.mockResolvedValue({
      slug: 'tenant-b',
      tenant_id: 'tid-b',
      display_name: 'Tenant B',
      tenant_type: 'production',
      production_tenant_display_name: null,
    })

    const getCaptured = renderAuthProvider(queryClient)

    let outcome: string | undefined
    await act(async () => {
      outcome = await getCaptured()!.switchTenant('tenant-b')
    })

    expect(outcome).toBe('ok')

    // The load-bearing assertion: removeQueries ran (data is GONE), not
    // invalidateQueries (which would leave getQueryData still returning the
    // stale tenant-A rows synchronously while a background refetch runs —
    // exactly the "stale row in a placeholder frame" AC3 forbids).
    expect(queryClient.getQueryData(tenantAKey)).toBeUndefined()

    // Session now reflects tenant B.
    expect(getCaptured()!.session?.tenant_id).toBe('tid-b')
    expect(mockSetToken).toHaveBeenCalledWith(TENANT_B_TOKEN)
  })

  it('TC-REQ384-09: interaction_required leaves the outgoing tenant\'s cache and session completely untouched', async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const tenantAKey = ['tenant', 'tid-a', 'instances', 'list', {}] as const
    queryClient.setQueryData(tenantAKey, { items: [{ instance_id: 'tenant-a-only' }], next_cursor: null })

    mockAttemptSilentSwitch.mockResolvedValue({ outcome: 'interaction_required' })

    const getCaptured = renderAuthProvider(queryClient)

    let outcome: string | undefined
    await act(async () => {
      outcome = await getCaptured()!.switchTenant('tenant-b')
    })

    expect(outcome).toBe('interaction_required')
    // Cache-clear must not have run: a failed/incomplete switch must not
    // leave the user logged into neither tenant.
    expect(queryClient.getQueryData(tenantAKey)).toBeDefined()
    expect(getCaptured()!.session?.tenant_id).toBe('tid-a')
    expect(mockSetToken).not.toHaveBeenCalled()
  })

  it('TC-REQ384-22: switchTenant actually cancels the outgoing tenant\'s in-flight queries, in order, BEFORE removing them (the straggler-fetch race SECURITY-REVIEWER analyzed)', async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const tenantAKey = ['tenant', 'tid-a', 'instances', 'list', {}] as const

    // Verified by direct experiment (this test file, temporarily dropping
    // AuthProvider.tsx's own `cancelQueries` call): TanStack Query's
    // `removeQueries` alone already deletes the Query instance from the
    // client's internal map, so a plain `getQueryData` check after a late
    // resolution passes regardless of whether `cancelQueries` ran --
    // asserting only on `getQueryData` would NOT catch a regression that
    // drops the `cancelQueries` call design §7.3.1 requires (wasted
    // in-flight network requests, and any observer still subscribed to the
    // stale query object during the removeQueries-to-late-resolution window
    // would still see the straggler's data via onSuccess/state updates that
    // don't route through getQueryData). The load-bearing, regression-
    // sensitive assertion is therefore that `cancelQueries` is actually
    // invoked, scoped to the outgoing tenant's own prefix, and strictly
    // BEFORE `removeQueries` -- exactly what §7.3.1 specifies as mechanism
    // (1) of the three-part AC3 guarantee.
    const cancelSpy = vi.spyOn(queryClient, 'cancelQueries')
    const removeSpy = vi.spyOn(queryClient, 'removeQueries')

    // A queryFn that deliberately ignores its AbortSignal (the realistic
    // worst case -- many fetchers do not wire the signal through) and
    // resolves only when the test tells it to, simulating a slow network
    // response landing AFTER the switch's own cancelQueries/removeQueries
    // pair has already run.
    let resolveStraggler!: (value: { items: { instance_id: string }[]; next_cursor: null }) => void
    const stragglerPromise = new Promise<{ items: { instance_id: string }[]; next_cursor: null }>((resolve) => {
      resolveStraggler = resolve
    })

    // Kick off the in-flight fetch (mirrors a real screen's useInstances()
    // call that was mid-request when the user clicked the switcher) without
    // awaiting it -- it is still pending when switchTenant runs below.
    const inFlightFetch = queryClient.fetchQuery({
      queryKey: tenantAKey,
      queryFn: () => stragglerPromise,
    })
    // Swallow the eventual cancellation rejection so it doesn't surface as
    // an unhandled rejection in this test.
    inFlightFetch.catch(() => {})

    mockAttemptSilentSwitch.mockResolvedValue({
      outcome: 'silent_ok',
      user: { access_token: TENANT_B_TOKEN },
    })
    mockGetBySlug.mockResolvedValue({
      slug: 'tenant-b',
      tenant_id: 'tid-b',
      display_name: 'Tenant B',
      tenant_type: 'production',
      production_tenant_display_name: null,
    })

    const getCaptured = renderAuthProvider(queryClient)

    let outcome: string | undefined
    await act(async () => {
      outcome = await getCaptured()!.switchTenant('tenant-b')
    })

    expect(outcome).toBe('ok')

    // cancelQueries ran, scoped to the OUTGOING tenant's prefix.
    expect(cancelSpy).toHaveBeenCalledWith({ queryKey: tenantRoot('tid-a') })
    // removeQueries ran against the same prefix.
    expect(removeSpy).toHaveBeenCalledWith({ queryKey: tenantRoot('tid-a') })
    // Ordering: cancel strictly before remove -- cancelling AFTER removal
    // would leave the window open for the straggler's late resolution to
    // recreate the query entry the way `fetchQuery`/observers do.
    expect(cancelSpy.mock.invocationCallOrder[0]).toBeLessThan(removeSpy.mock.invocationCallOrder[0])

    // Behavioral corroboration: the entry is gone immediately after the switch.
    expect(queryClient.getQueryData(tenantAKey)).toBeUndefined()

    // The straggler's response finally lands, well after the switch.
    await act(async () => {
      resolveStraggler({ items: [{ instance_id: 'late-tenant-a-row' }], next_cursor: null })
      await stragglerPromise
      await Promise.resolve()
    })

    // Still gone -- the cancelled fetch's late resolution was discarded, not
    // written back into the cache under the switched-away-from tenant's key.
    expect(queryClient.getQueryData(tenantAKey)).toBeUndefined()
    expect(getCaptured()!.session?.tenant_id).toBe('tid-b')
  })
})

/**
 * REQ-384 fix regression coverage (REVIEWER gap, WF02-REQ384-20260922) --
 * `switchingToTenantSlug` drives AuthenticatedShellRoot's unmount/remount of
 * AppShell (and therefore TenantSwitcher). AuthProvider.tsx's own comment
 * above `switchTenant` explains the bug this guards against: the code used
 * to set `switchingToTenantSlug` for the WHOLE attempt (covering the
 * `attemptSilentSwitch` call itself), which unmounted `TenantSwitcher` the
 * instant the user clicked an option -- so on `interaction_required`/`error`
 * the calling `TenantSwitcher` instance's own `onSelect` was setting local
 * state on an already-unmounted component, a silent no-op that meant neither
 * affordance ever rendered even though `switchTenant` itself resolved
 * correctly. The fix moves `setSwitchingToTenantSlug` to run only AFTER
 * `attemptSilentSwitch` confirms `'silent_ok'`, in a `try/finally` that
 * resets it to `null` once the switch (successful or not) completes.
 *
 * These tests use a deferred (controllable), never an immediately-resolved,
 * mock for `attemptSilentSwitch`/`tenantsApi.getBySlug` specifically so the
 * assertions can observe `switchingToTenantSlug`'s value WHILE the call is
 * still in flight -- an immediately-resolved mock collapses the pending
 * window to nothing and could not distinguish "never set" from "set and
 * unset before we could observe it."
 *
 * TC-REQ384-25: while `attemptSilentSwitch` is pending and after it resolves
 *   `'interaction_required'`, `switchingToTenantSlug` stays `null` throughout.
 * TC-REQ384-26: same, for an `'error'` outcome.
 * TC-REQ384-27: on a confirmed `'silent_ok'`, `switchingToTenantSlug` is
 *   still `null` while `attemptSilentSwitch` itself is pending, becomes the
 *   target slug only once `'silent_ok'` is confirmed (observed here while a
 *   deferred `tenantsApi.getBySlug` call inside `buildSessionFromToken` is
 *   still in flight), and returns to `null` once the switch completes.
 */
describe('AuthProvider.switchTenant — switchingToTenantSlug lifecycle (REVIEWER gap)', () => {
  function deferred<T>() {
    let resolve!: (value: T) => void
    const promise = new Promise<T>((res) => {
      resolve = res
    })
    return { promise, resolve }
  }

  it("TC-REQ384-25: switchingToTenantSlug stays null through a pending-then-'interaction_required' outcome", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const attempt = deferred<{ outcome: string }>()
    mockAttemptSilentSwitch.mockReturnValue(attempt.promise)

    const getCaptured = renderAuthProvider(queryClient)

    let switchPromise!: Promise<string>
    await act(async () => {
      switchPromise = getCaptured()!.switchTenant('tenant-b')
      // Flush a microtask so switchTenant has actually started (called
      // attemptSilentSwitch and is now awaiting the still-pending deferred
      // promise) without resolving it yet.
      await Promise.resolve()
    })

    // Still pending: switchingToTenantSlug must not have been set merely
    // because an attempt STARTED.
    expect(getCaptured()!.switchingToTenantSlug).toBeNull()

    let outcome: string | undefined
    await act(async () => {
      attempt.resolve({ outcome: 'interaction_required' })
      outcome = await switchPromise
    })

    expect(outcome).toBe('interaction_required')
    expect(getCaptured()!.switchingToTenantSlug).toBeNull()
    expect(mockSetToken).not.toHaveBeenCalled()
  })

  it("TC-REQ384-26: switchingToTenantSlug stays null through a pending-then-'error' outcome", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const attempt = deferred<{ outcome: string }>()
    mockAttemptSilentSwitch.mockReturnValue(attempt.promise)

    const getCaptured = renderAuthProvider(queryClient)

    let switchPromise!: Promise<string>
    await act(async () => {
      switchPromise = getCaptured()!.switchTenant('tenant-b')
      await Promise.resolve()
    })

    expect(getCaptured()!.switchingToTenantSlug).toBeNull()

    let outcome: string | undefined
    await act(async () => {
      attempt.resolve({ outcome: 'error' })
      outcome = await switchPromise
    })

    expect(outcome).toBe('error')
    expect(getCaptured()!.switchingToTenantSlug).toBeNull()
    expect(mockSetToken).not.toHaveBeenCalled()
  })

  it("TC-REQ384-27: switchingToTenantSlug is set to the target slug only once 'silent_ok' is confirmed, and clears once the switch completes", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const attempt = deferred<{ outcome: string; user: { access_token: string } }>()
    const getBySlug = deferred<{
      slug: string
      tenant_id: string
      display_name: string
      tenant_type: string
      production_tenant_display_name: string | null
    }>()
    mockAttemptSilentSwitch.mockReturnValue(attempt.promise)
    mockGetBySlug.mockReturnValue(getBySlug.promise)

    const getCaptured = renderAuthProvider(queryClient)

    let switchPromise!: Promise<string>
    await act(async () => {
      switchPromise = getCaptured()!.switchTenant('tenant-b')
      await Promise.resolve()
    })

    // attemptSilentSwitch itself is still pending -- must not be set yet.
    expect(getCaptured()!.switchingToTenantSlug).toBeNull()

    await act(async () => {
      // Confirms 'silent_ok'. switchTenant now proceeds synchronously into
      // setSwitchingToTenantSlug(targetSlug) and then calls
      // buildSessionFromToken, which awaits the still-pending
      // tenantsApi.getBySlug deferred -- so switchTenant is paused there,
      // giving us a real in-flight window to observe.
      attempt.resolve({ outcome: 'silent_ok', user: { access_token: TENANT_B_TOKEN } })
      await Promise.resolve()
      await Promise.resolve()
    })

    // Set ONLY after silent_ok was confirmed -- this is the load-bearing
    // assertion this test exists for.
    expect(getCaptured()!.switchingToTenantSlug).toBe('tenant-b')
    // Still mid-flight: the switch hasn't landed yet.
    expect(getCaptured()!.session?.tenant_id).toBe('tid-a')

    let outcome: string | undefined
    await act(async () => {
      getBySlug.resolve({
        slug: 'tenant-b',
        tenant_id: 'tid-b',
        display_name: 'Tenant B',
        tenant_type: 'production',
        production_tenant_display_name: null,
      })
      outcome = await switchPromise
    })

    expect(outcome).toBe('ok')
    // Cleared once the switch (successful) completes.
    expect(getCaptured()!.switchingToTenantSlug).toBeNull()
    expect(getCaptured()!.session?.tenant_id).toBe('tid-b')
  })
})
