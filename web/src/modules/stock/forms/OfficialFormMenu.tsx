/** OfficialFormMenu — T-1434 (E5e). One "Official form" disclosure menu: per form a .docx and a PDF item, and a line
 *  naming the language that will be printed. Built like LanguageSwitcher (aria-haspopup, role=menu, Escape closes and
 *  returns focus, outside mousedown closes, arrows move). The download itself belongs to the caller (`onPick`). */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { ChevronDown, FileText } from 'lucide-react'
import { getUiLocale } from '@/i18n/uiLocaleStore'
import { OFFICIAL_FORMATS, OFFICIAL_FORMS, officialFormLang, type OfficialFormFormat, type OfficialFormId, type OfficialFormLang } from './officialForms'

export interface OfficialFormMenuProps {
  forms: OfficialFormId[]
  /** Key of the running download (`form-<id>-<format>`); the trigger shows it as busy. */
  busyKey: string | null
  onPick: (form: OfficialFormId, format: OfficialFormFormat, lang: OfficialFormLang) => void
  /** Suffix of the trigger test id, for a screen that shows more than one menu. */
  testIdSuffix?: string
  /** Opens at once (harness screenshots). */
  initialOpen?: boolean
}

export function OfficialFormMenu({ forms, busyKey, onPick, testIdSuffix, initialOpen = false }: OfficialFormMenuProps) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [open, setOpen] = useState(initialOpen)
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

  if (forms.length === 0) return null
  const busy = busyKey !== null && busyKey.startsWith('form-') && forms.some((f) => busyKey.startsWith(`form-${f}-`))
  const lang = officialFormLang(getUiLocale())

  const pick = (form: OfficialFormId, format: OfficialFormFormat) => {
    setOpen(false)
    trigger.current?.focus()
    onPick(form, format, officialFormLang(getUiLocale()))
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
      const items = Array.from(root.current.querySelectorAll<HTMLElement>('[role="menuitem"]'))
      if (items.length === 0) return
      const i = items.indexOf(document.activeElement as HTMLElement)
      items[e.key === 'ArrowDown' ? (i + 1) % items.length : i <= 0 ? items.length - 1 : i - 1].focus()
    }
  }

  return (
    <div className="lf-lang lf-formmenu" ref={root} onKeyDown={onKeyDown}>
      <button
        ref={trigger}
        type="button"
        className={`lf-btn lf-btn--secondary lf-btn--s${busy ? ' is-loading' : ''}`}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-busy={busy || undefined}
        disabled={busy}
        data-testid={`official-form-menu${testIdSuffix ? `-${testIdSuffix}` : ''}`}
        onClick={() => setOpen((o) => !o)}
      >
        <FileText className="lf-icon" aria-hidden="true" />
        {t('stock.form.menu')}
        <ChevronDown className="lf-icon" aria-hidden="true" />
      </button>
      {open && (
        <div className="lf-lang__menu" role="menu" aria-label={t('stock.form.menu')}>
          {forms.map((form) =>
            OFFICIAL_FORMATS.map((format) => (
              <a
                key={`${form}-${format}`}
                href="#"
                role="menuitem"
                className="lf-lang__item"
                data-testid={`form-${form}-${format}`}
                onClick={(e) => {
                  e.preventDefault()
                  pick(form, format)
                }}
                onKeyDown={(e) => {
                  if (e.key === ' ') {
                    e.preventDefault()
                    pick(form, format)
                  }
                }}
              >
                <span>{t(OFFICIAL_FORMS[form].labelId)}</span>
                <span className="lf-lang__code">{t(`stock.form.fmt.${format}`)}</span>
              </a>
            )),
          )}
          <div className="lf-lang__item" aria-hidden="false" data-testid="official-form-lang">
            <span>{t('stock.form.lang', { lang: t(`stock.form.langName.${lang}`) })}</span>
          </div>
        </div>
      )}
    </div>
  )
}
