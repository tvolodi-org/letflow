/** HarnessPage (task S0d): /__harness/:screen?theme=&lang=&state=. Renders one registered screen with fixture
 *  data, without login or backend, for screenshots. Mounted only when import.meta.env.DEV (see router.tsx). */
import { useEffect, useLayoutEffect, useMemo, useState } from 'react'
import { Route, Routes, useParams, useSearchParams } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useUiLocaleStore } from '@/i18n/uiLocaleStore'
import { HARNESS_SCREENS } from './registry'
import { installFixtureFetch, pendingFixtureRequests } from './fixtureFetch'
import { signalWhenSettled } from './readySignal'
import {
  HARNESS_LANGS,
  HARNESS_STATES,
  HARNESS_THEMES,
  type HarnessLang,
  type HarnessState,
  type HarnessTheme,
} from './types'

/** A string that exists only in this module; the production-build test greps dist/ for it. */
export const HARNESS_ROUTE_MARKER = 'lf-screen-harness-route-marker'

function pick<T extends string>(allowed: readonly T[], value: string | null, fallback: T): T {
  return allowed.find(a => a === value) ?? fallback
}

export function HarnessPage() {
  const { screen: name = '' } = useParams<{ screen: string }>()
  const [params] = useSearchParams()
  const theme: HarnessTheme = pick(HARNESS_THEMES, params.get('theme'), 'light')
  const lang: HarnessLang = pick(HARNESS_LANGS, params.get('lang'), 'en')
  const state: HarnessState = pick(HARNESS_STATES, params.get('state'), 'default')
  const screen = HARNESS_SCREENS[name]
  const [ready, setReady] = useState(false)
  // Own query client: no retries, seeded nothing, data comes from the fixture fetch.
  const queryClient = useMemo(
    () => new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } }),
    [],
  )

  // Attribute only: the harness must not write the owner's stored theme.
  useLayoutEffect(() => {
    document.documentElement.setAttribute('data-theme', theme)
    document.documentElement.lang = lang
  }, [theme, lang])

  // Every screen reads its language from the UI-language store: give it the harness language while mounted
  // (not saved, so the owner's stored choice is untouched).
  useLayoutEffect(() => {
    useUiLocaleStore.getState().setLocaleTransient(lang)
    return () => useUiLocaleStore.getState().setLocaleTransient(null)
  }, [lang])

  useLayoutEffect(() => {
    if (!screen) return
    const restore = installFixtureFetch(screen.routes, state)
    setReady(true)
    return () => {
      setReady(false)
      restore()
    }
  }, [screen, state])

  useEffect(() => (ready ? signalWhenSettled(pendingFixtureRequests) : undefined), [ready, theme, lang, state])

  if (!screen) {
    return (
      <main data-testid="harness-unknown">
        <h1>Unknown screen</h1>
        <ul>
          {Object.keys(HARNESS_SCREENS).map(n => (
            <li key={n}>{n}</li>
          ))}
        </ul>
      </main>
    )
  }
  if (!ready) return null
  return (
    <QueryClientProvider client={queryClient}>
      <div data-harness={HARNESS_ROUTE_MARKER} hidden />
      {/* The app's router is already mounted (no second Router allowed): the screen's own location is given to
          <Routes> directly. The parent route is /__harness/:screen/*, so both are relative to that base. */}
      <Routes location={`/__harness/${screen.name}${screen.initialPath ?? '/'}`}>
        <Route path={(screen.routePattern ?? '*').replace(/^\//, '')} element={screen.render({ lang, state })} />
      </Routes>
    </QueryClientProvider>
  )
}
