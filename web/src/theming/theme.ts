/**
 * Light/dark theme choice (task S0a). The choice lives in localStorage under THEME_STORAGE_KEY and on
 * <html data-theme>. The inline script in index.html reads the same key before first paint; keep the
 * two key names in step (the theme test reads index.html to check it).
 * With no stored choice no attribute is set and tokens.css follows prefers-color-scheme.
 */
export type Theme = 'light' | 'dark'

export const THEME_STORAGE_KEY = 'lf-theme'

function isTheme(value: unknown): value is Theme {
  return value === 'light' || value === 'dark'
}

export function readStoredTheme(): Theme | null {
  try {
    const v = window.localStorage.getItem(THEME_STORAGE_KEY)
    return isTheme(v) ? v : null
  } catch {
    return null
  }
}

/** The theme in effect now: the attribute on <html>, else the system setting. */
export function currentTheme(): Theme {
  const attr = document.documentElement.getAttribute('data-theme')
  if (isTheme(attr)) return attr
  const dark =
    typeof window.matchMedia === 'function' && window.matchMedia('(prefers-color-scheme: dark)').matches
  return dark ? 'dark' : 'light'
}

/** Write data-theme on <html> and persist the choice (storage failure is ignored). */
export function setTheme(theme: Theme): void {
  document.documentElement.setAttribute('data-theme', theme)
  try {
    window.localStorage.setItem(THEME_STORAGE_KEY, theme)
  } catch {
    /* private mode or quota: the attribute still applies for this page */
  }
}
