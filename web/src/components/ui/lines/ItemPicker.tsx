/** ItemPicker — a text input that finds a catalog item by code or name (cell of the grid and field of the form).
 *  Exact code / `CODE – Title` / barcode / unique title resolves without the list; unknown text stays in the input and
 *  is reported by the validation of the line. The list (`lf-ref-pop`) opens below the input; arrows, Enter, Escape. */
import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { LeCatalog, LeItem } from './types'
import { useLinesT } from './linesMessages'

export interface ItemPickerProps {
  id: string
  value: string
  catalog: LeCatalog
  label: string
  invalid?: boolean
  describedBy?: string
  onPick: (item: LeItem | null) => void
  onBlur?: () => void
}

const label = (i: LeItem) => (i.code ? `${i.code} – ${i.title}` : i.title)

export function ItemPicker({ id, value, catalog, label: aria, invalid, describedBy, onPick, onBlur }: ItemPickerProps) {
  const t = useLinesT()
  const listId = useId()
  const current = value ? catalog.byId(value) : null
  const [text, setText] = useState(current ? label(current) : '')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const [rect, setRect] = useState<DOMRect | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const editing = useRef(false)
  const shown = current ? label(current) : ''

  // The line changed under us (duplicate, paste, scan, another row mounted in this slot): show its item.
  useEffect(() => {
    if (!editing.current) setText(shown)
  }, [shown])

  const results = open ? catalog.suggest(text) : []

  const pick = (i: LeItem) => {
    editing.current = false
    setText(label(i))
    setOpen(false)
    onPick(i)
  }

  return (
    <div className="lf-control">
      <input
        ref={inputRef}
        id={id}
        type="text"
        role="combobox"
        aria-expanded={open}
        aria-controls={open ? listId : undefined}
        aria-autocomplete="list"
        aria-label={aria}
        aria-invalid={invalid || undefined}
        aria-describedby={describedBy}
        autoComplete="off"
        spellCheck={false}
        placeholder={t('choose')}
        value={text}
        onChange={(e) => {
          editing.current = true
          setText(e.target.value)
          setActive(0)
          setRect(inputRef.current?.getBoundingClientRect() ?? null)
          setOpen(true)
          if (e.target.value === '' && value !== '') onPick(null)
        }}
        onKeyDown={(e) => {
          if (open && e.key === 'ArrowDown') {
            e.preventDefault()
            setActive((a) => Math.min(a + 1, Math.max(0, results.length - 1)))
          } else if (open && e.key === 'ArrowUp') {
            e.preventDefault()
            setActive((a) => Math.max(0, a - 1))
          } else if (open && e.key === 'Enter' && results[active] && catalog.resolve(text)?.id !== results[active]!.id) {
            e.preventDefault()
            pick(results[active]!)
          } else if (open && e.key === 'Escape') {
            e.preventDefault()
            e.stopPropagation()
            setOpen(false)
          }
        }}
        onBlur={() => {
          const hit = text.trim() === '' ? null : catalog.resolve(text)
          editing.current = false
          setOpen(false)
          if (hit && hit.id !== value) {
            setText(label(hit))
            onPick(hit)
          } else if (hit) setText(label(hit))
          onBlur?.()
        }}
      />
      {open &&
        rect &&
        createPortal(
          <div
            className="lf-ref-pop lf-le__pop"
            id={listId}
            role="listbox"
            style={{ top: rect.bottom + 2, left: rect.left, width: Math.max(rect.width, 280) }}
            onMouseDown={(e) => e.preventDefault()}
          >
            <div className="lf-ref-pop__list">
              {results.length === 0 && <div className="lf-ref-pop__state">{t('noMatch')}</div>}
              {results.map((r, k) => (
                <div key={r.id} className={`lf-ref-opt${k === active ? ' is-active' : ''}`} role="option" aria-selected={k === active} onClick={() => pick(r)}>
                  <span className="lf-ref">
                    {r.code && <span className="lf-ref__code">{r.code}</span>}
                    {r.code && <span className="lf-ref__sep" aria-hidden="true">–</span>}
                    <span className="lf-ref__title">{r.title}</span>
                  </span>
                </div>
              ))}
            </div>
          </div>,
          document.body,
        )}
    </div>
  )
}
