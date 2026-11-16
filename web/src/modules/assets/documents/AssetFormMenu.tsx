/** AssetFormMenu — T-1921. One "Official form" disclosure menu on the asset document screen: per form a .docx and a PDF
 *  item, and a line naming the language that will be printed. A copy of the stock `OfficialFormMenu` (the assets
 *  module does not import `modules/stock`), same markup, classes and test ids. Escape closes and returns focus, an
 *  outside mousedown closes, arrows move. The download itself belongs to the caller (`onPick`). */
import { useEffect, useRef, useState } from 'react'
import { useIntl } from 'react-intl'
import { ChevronDown, FileText } from 'lucide-react'
import { PortalMenu } from '@/components/ui/PortalMenu'
import { getUiLocale } from '@/i18n/uiLocaleStore'
import { ASSET_FORMS, ASSET_FORM_FORMATS, assetFormLang, type AssetFormFormat, type AssetFormId, type AssetFormLang } from './assetForms'

/** A plain print item shown above the official forms in the one Print menu (T-2020). */
export interface AssetPrintMenuItem {
  key: string
  label: string
  testId: string
  onPick: () => void
}

export interface AssetFormMenuProps {
  forms: AssetFormId[]
  /** Key of the running download (`form-<id>-<format>`); the trigger shows it as busy. */
  busyKey: string | null
  onPick: (form: AssetFormId, format: AssetFormFormat, lang: AssetFormLang) => void
  /** T-2020: plain print items. With any, the trigger reads "Print" and one menu holds all of them. */
  plain?: AssetPrintMenuItem[]
  /** Opens at once (harness screenshots). */
  initialOpen?: boolean
}

export function AssetFormMenu({ forms, busyKey, onPick, plain = [], initialOpen = false }: AssetFormMenuProps) {
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
  const label = t(plain.length > 0 ? 'assets.doc.print.menu' : 'assets.doc.form.menu')
  const lang = assetFormLang(getUiLocale())

  const pick = (form: AssetFormId, format: AssetFormFormat) => {
    setOpen(false)
    trigger.current?.focus()
    onPick(form, format, assetFormLang(getUiLocale()))
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
            ASSET_FORM_FORMATS.map((format) => (
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
                <span>{t(ASSET_FORMS[form].labelId)}</span>
                <span className="lf-lang__code">{t(`assets.doc.form.fmt.${format}`)}</span>
              </a>
            )),
          )}
          {forms.length > 0 && (
            <div className="lf-lang__item" aria-hidden="false" data-testid="official-form-lang">
              <span>{t('assets.doc.form.lang', { lang: t(`assets.doc.form.langName.${lang}`) })}</span>
            </div>
          )}
        </PortalMenu>
      )}
    </div>
  )
}
