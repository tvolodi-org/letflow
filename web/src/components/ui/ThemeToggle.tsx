/** ThemeToggle — design-system component (NOTES.md section 2): writes data-theme and storage;
 *  the head script in index.html reads the stored choice before first paint.
 *  A switch button: aria-pressed is true while the dark theme is on. Labels come from the
 *  en/ru/kk catalog below (the resolved UI locale, as the other catalogs do).
 */
import { useState } from 'react'
import { Moon, Sun } from 'lucide-react'
import type { EntitiesUiLocale } from '@/i18n/entitiesMessages'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { currentTheme, setTheme, type Theme } from '@/theming/theme'

export const themeToggleMessages: Record<EntitiesUiLocale, Record<Theme | 'label', string>> = {
  en: { label: 'Dark theme', light: 'Switch to dark theme', dark: 'Switch to light theme' },
  ru: { label: 'Тёмная тема', light: 'Включить тёмную тему', dark: 'Включить светлую тему' },
  kk: { label: 'Қараңғы тақырып', light: 'Қараңғы тақырыпты қосу', dark: 'Жарық тақырыпты қосу' },
}

export function ThemeToggle({ locale }: { locale?: EntitiesUiLocale }) {
  const [theme, setLocal] = useState<Theme>(() => currentTheme())
  const current = useUiLocale()
  const messages = themeToggleMessages[locale ?? current]
  const isDark = theme === 'dark'
  const toggle = () => {
    const next: Theme = isDark ? 'light' : 'dark'
    setTheme(next)
    setLocal(next)
  }
  return (
    <button
      type="button"
      className="lf-btn lf-btn--secondary lf-btn--s lf-btn--icon"
      data-testid="theme-toggle"
      aria-pressed={isDark}
      aria-label={messages.label}
      title={isDark ? messages.dark : messages.light}
      onClick={toggle}
    >
      {isDark ? <Sun className="lf-icon" aria-hidden="true" /> : <Moon className="lf-icon" aria-hidden="true" />}
    </button>
  )
}
