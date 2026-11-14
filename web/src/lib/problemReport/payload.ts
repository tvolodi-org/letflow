/** The body of a problem report (T-1950): exactly what `Capture.parse/1` of the server accepts. The dialog shows
 *  this object as JSON before sending and posts the same object (one snapshot, one builder). */
import type { ActionEntry, RequestEntry } from './capture'
import { maskText, normalizePath, oneLine } from './redact'

export type ReportContext = {
  route: string
  ui_language: 'en' | 'ru' | 'kk'
  browser: { user_agent: string; viewport: string; language?: string }
  actions: ActionEntry[]
  requests: RequestEntry[]
  crash?: { name: string; message: string }
}
export type ReportBody = { text: string; consent: true; context: ReportContext }

export function buildReportBody(
  text: string,
  snap: { actions: ActionEntry[]; requests: RequestEntry[] },
  opts: { uiLanguage: 'en' | 'ru' | 'kk'; crash?: Error | null },
): ReportBody {
  const language = typeof navigator.language === 'string' && /^[A-Za-z-]{2,16}$/.test(navigator.language) ? navigator.language : undefined
  const context: ReportContext = {
    route: maskText(normalizePath(window.location.pathname)),
    ui_language: opts.uiLanguage,
    browser: {
      user_agent: oneLine(navigator.userAgent).slice(0, 300),
      viewport: `${window.innerWidth}x${window.innerHeight}`,
      ...(language ? { language } : {}),
    },
    actions: snap.actions,
    requests: snap.requests,
  }
  if (opts.crash) {
    context.crash = {
      name: maskText(oneLine(opts.crash.name)).slice(0, 80),
      message: maskText(oneLine(opts.crash.message)).slice(0, 300),
    }
  }
  return { text: maskText(text.trim()), consent: true, context }
}
