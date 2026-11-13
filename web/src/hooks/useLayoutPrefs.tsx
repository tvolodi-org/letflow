/** T-1442 — the remembered layout (`ui.layout`) as a React context.
 *  Order of sources: the server value (through `useUiLayout`, only while authenticated) -> localStorage
 *  (`lf.prefs.ui.layout.v1.<tenant_id|anon>`) -> empty. Writes are debounced 400 ms (see `lib/layoutStore.ts`).
 *  Without a provider the hook answers a local-only store (localStorage, no network): the shell tests mock react-query
 *  with `useQuery` only, so AppShell itself must not need the provider. `AuthenticatedShellRoot` mounts it inside the
 *  per-tenant ErrorBoundary, so a tenant switch remounts it (no layout carried across tenants, INV-1). */
import { createContext, useContext, useEffect, useMemo, useRef, type ReactNode } from 'react'
import { useAuth } from '@/auth/AuthContext'
import { useUiLayout } from './useUiLayout'
import { parseLayoutJson } from '@/lib/layoutPrefs'
import { LAYOUT_STORAGE_KEY, createLayoutStore, type LayoutStore } from '@/lib/layoutStore'

const LayoutPrefsContext = createContext<LayoutStore | null>(null)

let localStore: LayoutStore | null = null
function defaultStore(): LayoutStore {
  return (localStore ??= createLayoutStore({ storageKey: `${LAYOUT_STORAGE_KEY}.anon` }))
}
/** Tests only: forget the module-level local store. */
export function resetDefaultLayoutStore(): void {
  localStore = null
}

export function LayoutPrefsProvider({ children }: { children: ReactNode }) {
  const { session } = useAuth()
  const { layout, save, reset } = useUiLayout()
  const tenantKey = session?.tenant_id ?? 'anon'
  const saveRef = useRef(save)
  const resetRef = useRef(reset)
  saveRef.current = save
  resetRef.current = reset

  const store = useMemo(
    () =>
      createLayoutStore({
        storageKey: `${LAYOUT_STORAGE_KEY}.${tenantKey}`,
        save: (json) => saveRef.current(parseLayoutJson(json)),
        reset: () => resetRef.current(),
      }),
    [tenantKey],
  )

  useEffect(() => {
    if (layout) store.adoptServer(layout)
  }, [layout, store])

  useEffect(() => {
    const onHide = () => store.flush()
    store.connect()
    window.addEventListener('pagehide', onHide)
    return () => {
      window.removeEventListener('pagehide', onHide)
      store.flush()
      store.dispose()
    }
  }, [store])

  return <LayoutPrefsContext.Provider value={store}>{children}</LayoutPrefsContext.Provider>
}

export function useLayoutPrefs(): LayoutStore {
  return useContext(LayoutPrefsContext) ?? defaultStore()
}
