/** Screen harness types (task S0d). Dev only: nothing under src/dev/ may be imported by production code
 *  except through the `import.meta.env.DEV` branch in router.tsx. */
import type { ReactElement } from 'react'

export const HARNESS_LANGS = ['en', 'ru', 'kk'] as const
export type HarnessLang = (typeof HARNESS_LANGS)[number]
export const HARNESS_THEMES = ['light', 'dark'] as const
export type HarnessTheme = (typeof HARNESS_THEMES)[number]
export const HARNESS_STATES = ['default', 'empty', 'loading', 'error'] as const
export type HarnessState = (typeof HARNESS_STATES)[number]

/** What a fixture answers for one request. */
export interface FixtureReply {
  status: number
  body: unknown
}

/** One fake API endpoint. `match` gets the pathname (no query string) and the method. */
export interface FixtureRoute {
  match: (path: string, method: string) => boolean
  /** The reply per state. `loading` never answers; `error` defaults to a 500 problem body. */
  reply: (state: Exclude<HarnessState, 'loading'>, path: string, body?: unknown) => FixtureReply
}

export interface HarnessScreen {
  /** URL segment: /__harness/<name>. Also the file-name prefix of its screenshots. */
  name: string
  /** Router location the screen expects (screens that read route params), default `/`. */
  initialPath?: string
  /** Route pattern the screen is rendered under, default `*`. */
  routePattern?: string
  routes: FixtureRoute[]
  render: (ctx: { lang: HarnessLang; state: HarnessState }) => ReactElement
}
