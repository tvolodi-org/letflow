// @vitest-environment jsdom
/**
 * REQ-384 §7.3.2/§7.3.3 — no stale tenant-A row in the DOM at any point
 * during a switch, including mid-transition. Full TEST-DESIGNER coverage
 * comes later in the pipeline; this file proves the two structural
 * mechanisms AC3 depends on directly, with `AppShell`/`TenantSwitchTransitionScreen`
 * replaced by test doubles (DIRECTIVE T-2's "mock the layer directly beneath
 * the unit under test"):
 *
 * TC-REQ384-10: while `switchingToTenantSlug` is set, the transition
 *   placeholder renders and `AppShell` does NOT — no route to a screen that
 *   might carry stale tenant-A cache/local state mid-switch.
 * TC-REQ384-11: once settled on a NEW tenant_id, the shell subtree is fully
 *   REMOUNTED (a fresh component instance — proven via a mount counter), not
 *   merely re-rendered — the guarantee that closes the "component-local
 *   state carrying tenant-A data across the switch" gap query-cache removal
 *   alone does not cover.
 * TC-REQ384-12: for the SAME tenant_id across renders, the shell is NOT
 *   remounted (mount count stays 1) — proves the remount is keyed
 *   specifically on tenant identity, not on every render.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, cleanup, screen } from '@testing-library/react'
import * as jestDomMatchers from '@testing-library/jest-dom/matchers'
import { useEffect, useRef } from 'react'

expect.extend(jestDomMatchers)

const mockUseAuth = vi.fn()

vi.mock('@/auth/AuthContext', () => ({
  useAuth: (...args: unknown[]) => mockUseAuth(...args),
}))

// T-1442: the real provider needs react-query; it is covered by hooks/__tests__/useLayoutPrefs.test.tsx.
vi.mock('@/hooks/useLayoutPrefs', () => ({
  LayoutPrefsProvider: ({ children }: { children: unknown }) => children,
}))

let appShellMountCount = 0

vi.mock('../AppShell', () => ({
  AppShell: () => {
    const mountedRef = useRef(false)
    useEffect(() => {
      if (!mountedRef.current) {
        mountedRef.current = true
        appShellMountCount += 1
      }
    }, [])
    return <div data-testid="app-shell-double">app shell</div>
  },
}))

vi.mock('@/auth/TenantSwitchTransitionScreen', () => ({
  TenantSwitchTransitionScreen: ({ targetSlug }: { targetSlug: string }) => (
    <div data-testid="transition-screen-double">switching to {targetSlug}</div>
  ),
}))

import { AuthenticatedShellRoot } from '../AuthenticatedShellRoot'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  appShellMountCount = 0
})

describe('AuthenticatedShellRoot — REQ-384 §7.3.2/§7.3.3', () => {
  it('TC-REQ384-10: renders the transition placeholder, NOT AppShell, while a switch is in flight', () => {
    mockUseAuth.mockReturnValue({
      session: { tenant_id: 'tid-a' },
      switchingToTenantSlug: 'tenant-b',
    })

    render(<AuthenticatedShellRoot />)

    expect(screen.getByTestId('transition-screen-double')).toBeInTheDocument()
    expect(screen.queryByTestId('app-shell-double')).toBeNull()
  })

  it('TC-REQ384-11: a changed tenant_id fully remounts the shell (fresh component instance)', () => {
    mockUseAuth.mockReturnValue({ session: { tenant_id: 'tid-a' }, switchingToTenantSlug: null })
    const { rerender } = render(<AuthenticatedShellRoot />)
    expect(screen.getByTestId('app-shell-double')).toBeInTheDocument()
    expect(appShellMountCount).toBe(1)

    mockUseAuth.mockReturnValue({ session: { tenant_id: 'tid-b' }, switchingToTenantSlug: null })
    rerender(<AuthenticatedShellRoot />)

    expect(screen.getByTestId('app-shell-double')).toBeInTheDocument()
    expect(appShellMountCount).toBe(2)
  })

  it('TC-REQ384-12: the SAME tenant_id across re-renders does NOT remount the shell', () => {
    mockUseAuth.mockReturnValue({ session: { tenant_id: 'tid-a' }, switchingToTenantSlug: null })
    const { rerender } = render(<AuthenticatedShellRoot />)
    expect(appShellMountCount).toBe(1)

    mockUseAuth.mockReturnValue({ session: { tenant_id: 'tid-a' }, switchingToTenantSlug: null })
    rerender(<AuthenticatedShellRoot />)

    expect(appShellMountCount).toBe(1)
  })
})
