/** uiLocaleStore — GH language switch (D-083). The one store of the UI language (en, ru, kk).
 *
 *  Priority: `?lang=xx` address parameter > saved choice (localStorage `lf-locale`) > browser language
 *  (`navigator.languages`, read live) > en. An unsupported value is ignored at each step. The tenant
 *  `default_locale` tier stays unused, as in the session-locale store (REQ-285), which this does not replace:
 *  that one is for date and number formats.
 *
 *  `choice` is the explicit choice (address parameter, saved or made in the switcher) or null. With null the
 *  language is the browser's, read at the time of the call, so a change of `navigator.languages` is seen too.
 *  `?lang` is not saved: it holds for that page load only. */
import { create } from 'zustand'

export const UI_LOCALES = ['en', 'ru', 'kk'] as const
export type UiLocale = (typeof UI_LOCALES)[number]
export const UI_LOCALE_STORAGE_KEY = 'lf-locale'
export const UI_LOCALE_PARAM = 'lang'
export const UI_LOCALE_LABELS: Record<UiLocale, string> = { en: 'English', ru: 'Русский', kk: 'Қазақша' }

/** Base language tag of a BCP-47 string when it is a supported UI language, else null. */
export function toUiLocale(raw: string | null | undefined): UiLocale | null {
  if (raw == null) return null
  const base = raw.split('-')[0].toLowerCase()
  return (UI_LOCALES as readonly string[]).includes(base) ? (base as UiLocale) : null
}

/** First supported language among the browser's, else en. Safe without `navigator`. */
export function browserUiLocale(): UiLocale {
  if (typeof navigator === 'undefined') return 'en'
  const sources =
    navigator.languages && navigator.languages.length > 0 ? navigator.languages : navigator.language ? [navigator.language] : []
  for (const raw of sources) {
    const l = toUiLocale(raw)
    if (l) return l
  }
  return 'en'
}

function readSaved(): UiLocale | null {
  try {
    return toUiLocale(window.localStorage.getItem(UI_LOCALE_STORAGE_KEY))
  } catch {
    return null
  }
}

function readParam(): UiLocale | null {
  if (typeof window === 'undefined') return null
  try {
    return toUiLocale(new URLSearchParams(window.location.search).get(UI_LOCALE_PARAM))
  } catch {
    return null
  }
}

/** The explicit choice from the environment: `?lang` first, then the saved one; null when neither is valid. */
export function readInitialChoice(): UiLocale | null {
  return readParam() ?? readSaved()
}

interface UiLocaleStore {
  choice: UiLocale | null
  /** The user's choice: applied at once and saved. */
  setLocale: (locale: UiLocale) => void
  /** Applied at once, not saved (the screen harness). Pass null to go back to the saved or browser language. */
  setLocaleTransient: (locale: UiLocale | null) => void
  /** Re-reads `?lang` and the saved choice (tests). */
  reloadFromEnvironment: () => void
}

export const useUiLocaleStore = create<UiLocaleStore>((set) => ({
  choice: readInitialChoice(),
  setLocale: (locale) => {
    try {
      window.localStorage.setItem(UI_LOCALE_STORAGE_KEY, locale)
    } catch {
      // storage unavailable (private mode): the choice lasts for this page load only
    }
    set({ choice: locale })
  },
  setLocaleTransient: (locale) => set({ choice: locale ?? readSaved() }),
  reloadFromEnvironment: () => set({ choice: readInitialChoice() }),
}))

/** Non-hook accessor for plain functions (the per-module `resolveUiLocale`). */
export function getUiLocale(): UiLocale {
  return useUiLocaleStore.getState().choice ?? browserUiLocale()
}

/** Hook: the current UI language; the component re-renders when the choice changes. */
export function useUiLocale(): UiLocale {
  const choice = useUiLocaleStore((s) => s.choice)
  return choice ?? browserUiLocale()
}
