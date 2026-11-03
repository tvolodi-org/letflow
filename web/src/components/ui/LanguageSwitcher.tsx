/** LanguageSwitcher — globe + current code; menu of locales with a check on the current one.
 *  The choice is persisted per user (localStorage key per `userKey`) by `saveLocale`;
 *  `loadLocale` reads it back (null when nothing valid is stored). Escape closes the menu
 *  and returns focus to the trigger; Arrow keys move between items. */
import { useEffect, useRef, useState } from 'react'
import { Check, ChevronDown, Globe } from 'lucide-react'
import { useUiMessages } from './uiMessages'

export interface LocaleOption {
  /** BCP-47 base tag, e.g. "ru". */
  code: string
  /** Name in its own language, e.g. "Русский". */
  label: string
}

export interface LanguageSwitcherProps {
  locales: LocaleOption[]
  current: string
  onChange: (code: string) => void
  /** Stable id of the signed-in user; the choice is stored under it. Omit to skip persistence. */
  userKey?: string
}

const STORAGE_PREFIX = 'letflow.locale.'

export function loadLocale(userKey: string, allowed: readonly string[]): string | null {
  try {
    const v = window.localStorage.getItem(STORAGE_PREFIX + userKey)
    return v != null && allowed.includes(v) ? v : null
  } catch {
    return null
  }
}

export function saveLocale(userKey: string, code: string): void {
  try {
    window.localStorage.setItem(STORAGE_PREFIX + userKey, code)
  } catch {
    // storage unavailable (private mode): the choice lasts for this session only
  }
}

export function LanguageSwitcher({ locales, current, onChange, userKey }: LanguageSwitcherProps) {
  const t = useUiMessages()
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement | null>(null)
  const trigger = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    if (!open) return
    const away = (e: MouseEvent) => {
      if (root.current != null && !root.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', away)
    return () => document.removeEventListener('mousedown', away)
  }, [open])

  const select = (code: string) => {
    if (userKey != null) saveLocale(userKey, code)
    onChange(code)
    setOpen(false)
    trigger.current?.focus()
  }

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape' && open) {
      e.stopPropagation()
      setOpen(false)
      trigger.current?.focus()
      return
    }
    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && root.current != null) {
      e.preventDefault()
      if (!open) {
        setOpen(true)
        return
      }
      const items = Array.from(root.current.querySelectorAll<HTMLElement>('[role="menuitemradio"]'))
      if (items.length === 0) return
      const i = items.indexOf(document.activeElement as HTMLElement)
      const next = e.key === 'ArrowDown' ? (i + 1) % items.length : (i <= 0 ? items.length - 1 : i - 1)
      items[next].focus()
    }
  }

  const currentCode = current.toUpperCase()
  return (
    <div className="lf-lang" ref={root} onKeyDown={onKeyDown} data-testid="language-switcher">
      <button
        ref={trigger}
        type="button"
        className="lf-lang__trigger lf-btn lf-btn--ghost lf-btn--s"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={`${t.language}: ${currentCode}`}
        data-testid="language-switcher-trigger"
        onClick={() => setOpen((o) => !o)}
      >
        <Globe className="lf-icon" aria-hidden="true" />
        {currentCode}
        <ChevronDown className="lf-icon" aria-hidden="true" />
      </button>
      {open && (
        <div className="lf-lang__menu" role="menu" aria-label={t.language}>
          {locales.map((l) => {
            const isCurrent = l.code === current
            return (
              <a
                key={l.code}
                href="#"
                role="menuitemradio"
                aria-checked={isCurrent}
                aria-current={isCurrent ? 'true' : undefined}
                className="lf-lang__item"
                data-testid={`language-option-${l.code}`}
                onClick={(e) => {
                  e.preventDefault()
                  select(l.code)
                }}
                onKeyDown={(e) => {
                  if (e.key === ' ') {
                    e.preventDefault()
                    select(l.code)
                  }
                }}
              >
                <span>{l.label}</span>
                <span className="lf-lang__code">{l.code.toUpperCase()}</span>
                {isCurrent ? <Check className="lf-icon" aria-hidden="true" /> : <span />}
              </a>
            )
          })}
        </div>
      )}
    </div>
  )
}
