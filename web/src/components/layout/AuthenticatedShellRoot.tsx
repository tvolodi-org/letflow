/** REQ-384 §7.3.2/§7.3.3 — wraps the authenticated shell so a tenant switch
 *  gets a structural remount, not a re-render.
 *
 *  Two mechanisms, both required by design §7.3:
 *
 *  1. While `switchingToTenantSlug` is set (`AuthProvider.switchTenant`'s
 *     in-flight promise), render `TenantSwitchTransitionScreen` instead of
 *     `AppShell` — a dedicated placeholder, not a route change to some
 *     default screen that might itself carry stale cache.
 *  2. Once settled, `<ErrorBoundary key={session?.tenant_id}>` — React's own
 *     semantics for a changed `key` are a full unmount-then-remount of that
 *     subtree, which is what guarantees no component can carry
 *     tenant-A-derived local state (a `useState` seeded from tenant-A props,
 *     a derived `useMemo`, an uncontrolled form) across the switch: the
 *     component instance itself does not survive it. This is a structural
 *     guarantee that complements — not replaces — §7.1/§7.3.1's query-cache
 *     `removeQueries` call, which covers the *query cache* but not
 *     component-local state a screen might have derived from an earlier
 *     tenant-A response.
 *
 *  T-1950: a crash shows the localised `ShellCrashPanel` (with "Report this problem"), passed as the boundary's `fallback`.
 */
import { useAuth } from '@/auth/AuthContext'
import { TenantSwitchTransitionScreen } from '@/auth/TenantSwitchTransitionScreen'
import { AppShell } from './AppShell'
import { ErrorBoundary } from './ErrorBoundary'
import { ShellCrashPanel } from './ShellCrashPanel'
import { LayoutPrefsProvider } from '@/hooks/useLayoutPrefs'

export function AuthenticatedShellRoot(): JSX.Element {
  const { session, switchingToTenantSlug } = useAuth()

  if (switchingToTenantSlug) {
    return <TenantSwitchTransitionScreen targetSlug={switchingToTenantSlug} />
  }

  return (
    <ErrorBoundary key={session?.tenant_id ?? 'anonymous'} fallback={(error, reset) => <ShellCrashPanel error={error} reset={reset} />}>
      <LayoutPrefsProvider>
        <AppShell />
      </LayoutPrefsProvider>
    </ErrorBoundary>
  )
}
