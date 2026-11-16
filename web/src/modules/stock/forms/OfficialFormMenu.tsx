/** OfficialFormMenu — T-1434 (E5e). One "Official form" disclosure menu: per form a .docx and a PDF item, and a line
 *  naming the language that will be printed. Built like LanguageSwitcher (aria-haspopup, role=menu, Escape closes and
 *  returns focus, outside mousedown closes, arrows move). The download itself belongs to the caller (`onPick`). */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { ChevronDown, FileText } from 'lucide-react'
import { PortalMenu } from '@/components/ui/PortalMenu'
import { getUiLocale } from '@/i18n/uiLocaleStore'
import { OFFICIAL_FORMATS, OFFICIAL_FORMS, officialFormLang, type OfficialFormFormat, type OfficialFormId, type OfficialFormLang } from './officialForms'

/** A plain (non-official) print or download item shown above the official forms in the one Print menu (T-2020). */
export interface PrintMenuItem {
  /** Busy key of the running download (`pdf.busyKey`), so the trigger shows it as busy. */
  key: string
  label: string
  testId: string
  onPick: () => void
}

export interface OfficialFormMenuProps {
  forms: OfficialFormId[]
  /** Key of the running download (`form-<id>-<format>`); the trigger shows it as busy. */
  busyKey: string | null
  onPick: (form: OfficialFormId, format: OfficialFormFormat, lang: OfficialFormLang) => void
  /** Forms shown but not offered yet: value = message id of the reason, shown under the item (T-1441). */
  disabledForms?: Partial<Record<OfficialFormId, string>>
  /** T-2020: plain print / download items. With any, the trigger reads "Print" and one menu holds all of them. */
  plain?: PrintMenuItem[]
  /** Opens at once (harness screenshots). */
  initialOpen?: boolean
}

export function OfficialFormMenu({ forms, busyKey, onPick, disabledForms, plain = [], initialOpen = false }: OfficialFormMenuProps) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  const [open, setOpen] = useState(initialOpen)
  const root = useRef<HTMLDivElement | null>(null)
  const menu = useRef<HTMLDivElement | null>(null)
  const trigger = useRef<HTMLButtonElement | null>(null)

  useEffect(() => {
    if (!open) return
    const away = (e: MouseEvent) => {
      const n = e.target as Node
      if (root.current != null && !root.current.contains(n) && !(menu.current?.contains(n) ?? false)) setOpen(false)
    }
    document.addEventListener('mousedown', away)
    return () => document.removeEventListener('mousedown', away)
  }, [open])

  if (forms.length === 0 && plain.length === 0) return null
  const busy =
    busyKey !== null &&
    ((busyKey.startsWith('form-') && forms.some((f) => busyKey.startsWith(`form-${f}-`))) || plain.some((p) => p.key === busyKey))
  const label = t(plain.length > 0 ? 'stock.print.menu' : 'stock.form.menu')
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
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      if (!open) {
        setOpen(true)
        return
      }
      const items = Array.from(menu.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])
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
        data-testid="official-form-menu"
        onClick={() => setOpen((o) => !o)}
      >
        <FileText className="lf-icon" aria-hidden="true" />
        {label}
        <ChevronDown className="lf-icon" aria-hidden="true" />
      </button>
      {open && (
        <PortalMenu anchor={trigger} menuRef={menu} label={label}>
          {plain.map((item) => (
            <a
              key={item.key}
              href="#"
              role="menuitem"
              className="lf-lang__item"
              data-testid={item.testId}
              onClick={(e) => {
                e.preventDefault()
                setOpen(false)
                trigger.current?.focus()
                item.onPick()
              }}
              onKeyDown={(e) => {
                if (e.key === ' ') {
                  e.preventDefault()
                  setOpen(false)
                  trigger.current?.focus()
                  item.onPick()
                }
              }}
            >
              <span>{item.label}</span>
            </a>
          ))}
          {plain.length > 0 && forms.length > 0 && <div className="lf-lang__sep" role="separator" />}
          {forms.map((form) =>
            OFFICIAL_FORMATS.map((format) => {
              const reason = disabledForms?.[form]
              return (
                <a
                  key={`${form}-${format}`}
                  href="#"
                  role="menuitem"
                  className="lf-lang__item"
                  aria-disabled={reason !== undefined ? 'true' : undefined}
                  data-testid={`form-${form}-${format}`}
                  onClick={(e) => {
                    e.preventDefault()
                    if (reason === undefined) pick(form, format)
                  }}
                  onKeyDown={(e) => {
                    if (e.key === ' ') {
                      e.preventDefault()
                      if (reason === undefined) pick(form, format)
                    }
                  }}
                >
                  <span>{t(OFFICIAL_FORMS[form].labelId)}</span>
                  <span className="lf-lang__code">{t(`stock.form.fmt.${format}`)}</span>
                  {reason !== undefined && <span className="lf-lang__code lf-formmenu__reason">{t(reason)}</span>}
                </a>
              )
            }),
          )}
          {forms.length > 0 && (
            <div className="lf-lang__item" aria-hidden="false" data-testid="official-form-lang">
              <span>{t('stock.form.lang', { lang: t(`stock.form.langName.${lang}`) })}</span>
            </div>
          )}
        </PortalMenu>
      )}
    </div>
  )
}
