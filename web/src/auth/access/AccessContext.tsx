import { createContext } from 'react'
import type { ReactNode } from 'react'
import type { AccessState } from './types'

/** Default is `loading`: a component outside a provider sees no access, never the full set. */
export const AccessContext = createContext<AccessState>({ status: 'loading' })

/** Provides a fixed state. For tests and storybook-style renders; the app uses `AccessProvider`. */
export function AccessStateProvider({ state, children }: { state: AccessState; children: ReactNode }) {
  return <AccessContext.Provider value={state}>{children}</AccessContext.Provider>
}
