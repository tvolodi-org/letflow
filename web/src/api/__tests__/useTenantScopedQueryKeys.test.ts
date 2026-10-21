// @vitest-environment jsdom
/**
 * REQ-384 §7.1/§7.2 — tenant-keyed query-cache isolation, the core mechanism
 * this requirement adds. Full TEST-DESIGNER coverage comes later in the
 * pipeline; this file proves the load-bearing property directly: two
 * different active tenants produce two DIFFERENT, prefix-distinguishable
 * query keys for the same logical query, and a single `removeQueries` call
 * addressed at one tenant's `tenantRoot(tenantId)` prefix would remove
 * exactly one tenant's subtree — the property AuthProvider.switchTenant's
 * cache-clear step (§7.3.1) depends on.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'

const mockUseAuth = vi.fn()

vi.mock('@/auth/AuthContext', () => ({
  useAuth: (...args: unknown[]) => mockUseAuth(...args),
}))

import { useTenantScopedQueryKeys } from '../useTenantScopedQueryKeys'
import { queryKeys, tenantRoot } from '../queryKeys'

function sessionWithTenant(tenantId: string | null) {
  return {
    session: tenantId === undefined ? null : {
      token: 'tok',
      display_name: 'Test User',
      loginSource: 'oidc' as const,
      tenant_slug: 'fixture-tenant',
      tenant_display_name: 'Fixture Tenant',
      tenant_id: tenantId,
      tenant_type: 'test' as const,
      production_tenant_display_name: null,
    },
  }
}

afterEach(() => {
  vi.clearAllMocks()
})

describe('useTenantScopedQueryKeys — REQ-384 §7.2 core mechanism', () => {
  it('TC-REQ384-01: the same logical query key differs between two active tenants', () => {
    mockUseAuth.mockReturnValue(sessionWithTenant('tenant-a'))
    const { result: a } = renderHook(() => useTenantScopedQueryKeys())
    const keyA = a.current.instances.list({})

    mockUseAuth.mockReturnValue(sessionWithTenant('tenant-b'))
    const { result: b } = renderHook(() => useTenantScopedQueryKeys())
    const keyB = b.current.instances.list({})

    expect(keyA).not.toEqual(keyB)
    expect(keyA[1]).toBe('tenant-a')
    expect(keyB[1]).toBe('tenant-b')
  })

  it('TC-REQ384-02: tenant id leads the key array — required for prefix-matched removeQueries', () => {
    mockUseAuth.mockReturnValue(sessionWithTenant('tenant-a'))
    const { result } = renderHook(() => useTenantScopedQueryKeys())

    const listKey = result.current.instances.list({ status: ['ACTIVE'] })
    const detailKey = result.current.instances.detail('inst-1')
    const adminUsersKey = result.current.admin.users()

    expect(listKey.slice(0, 2)).toEqual(['tenant', 'tenant-a'])
    expect(detailKey.slice(0, 2)).toEqual(['tenant', 'tenant-a'])
    expect(adminUsersKey.slice(0, 2)).toEqual(['tenant', 'tenant-a'])
  })

  it('TC-REQ384-03: every tenant-scoped group produces a key under the tenant root, matching AuthProvider.switchTenant\'s single removeQueries prefix', () => {
    mockUseAuth.mockReturnValue(sessionWithTenant('tenant-a'))
    const { result } = renderHook(() => useTenantScopedQueryKeys())
    const root = tenantRoot('tenant-a')

    const keys = [
      result.current.instances.list({}),
      result.current.definitions.list({}),
      result.current.tasks.list({}),
      result.current.admin.audit(),
      result.current.admin.groups(),
      result.current.admin.groupMembers('g1'),
      result.current.admin.tokens(),
      result.current.admin.userDetail('u1'),
      result.current.admin.roles(),
      result.current.admin.services(),
      result.current.dlq.list(),
      result.current.webhooks.list(),
      result.current.promotions.context('r1'),
      result.current.entities.definition('tag'),
      result.current.modules.list(),
      result.current.help.resolved('screen', null),
      result.current.exam.list(),
      result.current.platformMigrations.status('roll-1'),
      result.current.solutionPackUpdate.review('pack-1', '2.0.0'),
      result.current.eventRetention.summary(),
    ]

    for (const key of keys) {
      expect(key.slice(0, 2)).toEqual(root)
    }
  })

  it('TC-REQ384-04: exempt groups (admin.tenants, admin.health, onboarding, me) are NEVER tenant-prefixed', () => {
    mockUseAuth.mockReturnValue(sessionWithTenant('tenant-a'))
    const { result } = renderHook(() => useTenantScopedQueryKeys())

    expect(result.current.admin.tenants()).toEqual(queryKeys.admin.tenants())
    expect(result.current.admin.tenantDetail('slug')).toEqual(queryKeys.admin.tenantDetail('slug'))
    expect(result.current.admin.health()).toEqual(queryKeys.admin.health())
    expect(result.current.admin.metrics()).toEqual(queryKeys.admin.metrics())
    expect(result.current.onboarding.status('id')).toEqual(queryKeys.onboarding.status('id'))
    expect(result.current.me.memberships()).toEqual(queryKeys.me.memberships())

    // None of these carry a leading 'tenant' segment.
    expect(result.current.admin.tenants()[0]).not.toBe('tenant')
    expect(result.current.me.memberships()[0]).not.toBe('tenant')
  })

  it('TC-REQ406-01: me.modules is tenant-scoped while me.memberships remains global', () => {
    mockUseAuth.mockReturnValue(sessionWithTenant('tenant-a'))
    const { result: a } = renderHook(() => useTenantScopedQueryKeys())

    mockUseAuth.mockReturnValue(sessionWithTenant('tenant-b'))
    const { result: b } = renderHook(() => useTenantScopedQueryKeys())

    expect(a.current.me.memberships()[0]).not.toBe('tenant')
    expect(a.current.me.modules().slice(0, 2)).toEqual(['tenant', 'tenant-a'])
    expect(b.current.me.modules().slice(0, 2)).toEqual(['tenant', 'tenant-b'])
    expect(a.current.me.modules()).not.toEqual(b.current.me.modules())
  })

  it('TC-REQ384-05: throws when called outside an authenticated session (no session at all)', () => {
    mockUseAuth.mockReturnValue(sessionWithTenant(undefined as unknown as string))
    const { result } = renderHook(() => {
      try {
        return { ok: true, value: useTenantScopedQueryKeys() }
      } catch (e) {
        return { ok: false, error: e }
      }
    })
    expect(result.current.ok).toBe(false)
  })

  it('TC-REQ384-06: a session with a null tenant_id (UserSession.tenant_id allows null) falls back to a stable, non-throwing key rather than crashing render', () => {
    mockUseAuth.mockReturnValue(sessionWithTenant(null))
    const { result } = renderHook(() => useTenantScopedQueryKeys())
    const key = result.current.instances.list({})
    expect(key[0]).toBe('tenant')
    expect(typeof key[1]).toBe('string')
  })
})
