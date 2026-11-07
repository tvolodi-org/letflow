/** LFLinesEditor — the lines of a document at volume, in two modes (design repo: NOTES.md "Lines editor", CSS lf-le*).
 *  GRID: the lines are cells of a table; Enter/Tab/arrows move, Enter in the last cell adds a row, Excel paste, duplicate and
 *  delete per row, scanner adds or increments. LINE BY LINE: one line in a form (Save and add next / Save and close) and the
 *  saved lines in a compact table. Rows are virtual (fixed height from the token), the panel scrolls inside itself.
 *  Generic: a caller describes its lines with `columns` (see types.ts); this file knows no module words. */
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { AlertTriangle, CheckCircle2, Copy, ScanLine, Search, Trash2, Upload, Plus } from 'lucide-react'
import { Button } from '../Button'
import { nextCell } from './gridKeys'
import { parsePaste } from './pasteRows'
import { useVirtualRows } from './useVirtualRows'
import { useLinesT } from './linesMessages'
import { EmptyState, ErrorState, LoadingState, NoMatchState, NoPermissionState } from './LinesStates'
import { useColResize } from '../layout/ColumnResize'
import { useLayoutMessages } from '../layout/layoutMessages'
import type { LeError, LeImportController, LeMode, LFLinesEditorProps } from './types'

/** Under this panel width the grid is off and the line-by-line mode is used (a phone). The design says 700 px for a full
 *  page; the lines card of a document beside the list and the header is ~630 px at 1440, so the limit is lower here and the
 *  grid scrolls sideways inside its panel (min-width on the table, base.css). */
const NARROW_PX = 560

interface Notice {
  kind: 'ok' | 'warn'
  text: string
  details?: { row: number; reason: string }[]
}

interface FormState<L> {
  open: boolean
  idx: number // -1 = a new line
  draft: L
  showErr: boolean
}

function dedupe(errs: LeError[]): LeError[] {
  const seen = new Set<string>()
  return errs.filter((e) => {
    const k = `${e.col ?? ''}|${e.message}`
    if (seen.has(k)) return false
    seen.add(k)
    return true
  })
}

export function LFLinesEditor<L>(props: LFLinesEditorProps<L>) {
  const { lines, onChange, columns, blank, duplicate, isBlank, max, mode, onModeChange, readOnly = false, state = 'ready', screenId } = props
  const t = useLinesT()
  const rootRef = useRef<HTMLDivElement>(null)
  const tableRef = useRef<HTMLTableElement>(null)
  const lm = useLayoutMessages()
  const [narrow, setNarrow] = useState(false)
  const effMode: LeMode = narrow ? 'form' : mode
  useColResize(tableRef, {
    id: props.resize?.id ?? 'lines',
    screen: props.resize?.screen ?? '',
    cols: props.resize?.cols ?? [],
    label: (_id, th) => `${lm.resizeColumn}: ${th.textContent?.trim() ?? ''}`,
    enabled: () => !!props.resize && ((rootRef.current?.closest('.lf-doc') ?? rootRef.current)?.clientWidth ?? 0) > 640,
  })

  useEffect(() => {
    const el = rootRef.current
    if (!el) return
    const read = () => {
      const w = el.getBoundingClientRect().width
      setNarrow(w > 0 && w < NARROW_PX)
    }
    read()
    if (typeof ResizeObserver !== 'function') return
    const ro = new ResizeObserver(read)
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  // ---- line identity: rows are positional for the server; the editor keeps a parallel id list for focus and "touched" ----
  const idsRef = useRef<number[]>([])
  const seq = useRef(0)
  const [touched, setTouched] = useState<ReadonlySet<number>>(new Set())
  const ids = idsRef.current
  while (ids.length < lines.length) ids.push(++seq.current)
  if (ids.length > lines.length) ids.length = lines.length

  const [opened, setOpened] = useState(false)
  const emptyDoc = lines.length === 1 && isBlank(lines[0]!) && !opened && touched.size === 0 && !props.showErrors
  const base = useMemo(() => (emptyDoc ? [] : lines), [emptyDoc, lines])

  const apply = useCallback(
    (next: L[], nextIds: number[]) => {
      idsRef.current = nextIds
      onChange(next.length > 0 ? next : [blank()])
      if (next.length === 0) idsRef.current = [++seq.current]
    },
    [onChange, blank],
  )
  // `ids` is a ref array mutated in place; `lines` is the dependency that says it changed.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const baseIds = useMemo(() => (emptyDoc ? [] : [...ids]), [emptyDoc, ids, lines])
  const touch = useCallback((id: number) => setTouched((s) => (s.has(id) ? s : new Set(s).add(id))), [])

  // ---- search, errors ----
  const [search, setSearch] = useState('')
  const view = useMemo(() => {
    const q = search.trim().toLowerCase()
    const out: number[] = []
    lines.forEach((l, i) => {
      if (q === '' || props.searchText(l).toLowerCase().includes(q)) out.push(i)
    })
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lines, search, props.searchText])

  const errorsByLine = useMemo(() => {
    const out = new Map<number, LeError[]>()
    lines.forEach((l, i) => {
      const own = props.errors?.[i] ?? []
      const live = props.validateLine && (props.showErrors || touched.has(ids[i]!)) ? props.validateLine(l) : []
      const all = dedupe([...own, ...live])
      if (all.length > 0) out.set(i, all)
    })
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lines, props.errors, props.validateLine, props.showErrors, touched])
  const errLines = useMemo(() => [...errorsByLine.keys()], [errorsByLine])

  // ---- flash, live region, notices ----
  const [flash, setFlash] = useState<number | null>(null)
  useEffect(() => {
    if (flash === null) return
    const h = setTimeout(() => setFlash(null), 1500)
    return () => clearTimeout(h)
  }, [flash])
  const [live, setLive] = useState('')
  const [notice, setNotice] = useState<Notice | null>(null)
  const atMax = !readOnly && lines.length >= max && !emptyDoc
  const announce = (s: string) => setLive(s)

  // ---- virtual rows (grid and saved table) ----
  const gridV = useVirtualRows(view.length, '--lines-row-h', 40)
  const savedV = useVirtualRows(view.length, '--lines-row-h-compact', 36)

  // ---- focus ----
  const pending = useRef<{ id: number; col: string } | null>(null)
  const [, bump] = useState(0)
  const focusCell = (index: number, col: string) => {
    pending.current = { id: idsRef.current[index]!, col }
    const pos = view.indexOf(index)
    if (pos >= 0) gridV.scrollToRow(pos)
    bump((n) => n + 1)
  }
  useEffect(() => {
    const p = pending.current
    if (!p) return
    const cell = rootRef.current?.querySelector<HTMLElement>(`tr[data-id="${p.id}"] td[data-col="${p.col}"]`)
    const ctl = cell?.querySelector<HTMLElement>('input, select, button')
    if (ctl) {
      ctl.focus()
      pending.current = null
    }
  })
  const editableCols = columns.filter((c) => c.cell)
  const firstCol = editableCols[0]?.key ?? 'item'

  // ---- add, duplicate, delete ----
  const addLine = () => {
    if (atMax) {
      setNotice({ kind: 'warn', text: t('maxHit', { max }) })
      return
    }
    setOpened(true)
    if (effMode === 'form') {
      openForm(-1)
      return
    }
    if (emptyDoc) {
      // The sole blank line becomes the first row.
      focusCell(0, firstCol)
      return
    }
    apply([...base, blank()], [...baseIds, ++seq.current])
    focusCell(base.length, firstCol)
  }
  const dupLine = (i: number) => {
    if (lines.length >= max) {
      setNotice({ kind: 'warn', text: t('maxHit', { max }) })
      return
    }
    const next = [...lines]
    const nid = [...ids]
    next.splice(i + 1, 0, duplicate(lines[i]!))
    nid.splice(i + 1, 0, ++seq.current)
    apply(next, nid)
    touch(nid[i + 1]!)
    focusCell(i + 1, firstCol)
  }
  const delLine = (i: number) => {
    const next = lines.filter((_, j) => j !== i)
    const nid = ids.filter((_, j) => j !== i)
    apply(next, nid)
    announce(t('deleted', { n: i + 1 }))
    if (next.length > 0) {
      pending.current = { id: nid[Math.min(i, next.length - 1)]!, col: firstCol }
      bump((n) => n + 1)
    }
  }
  const patchLine = (i: number, p: Partial<L>) => onChange(lines.map((l, j) => (j === i ? { ...l, ...p } : l)))

  // ---- grid keyboard ----
  const onGridKey = (e: React.KeyboardEvent<HTMLElement>) => {
    if (e.defaultPrevented || readOnly) return
    const target = e.target as HTMLElement
    const td = target.closest<HTMLElement>('td[data-col]')
    const tr = target.closest<HTMLElement>('tr[data-id]')
    if (!td || !tr) return
    const id = Number(tr.dataset['id'])
    const i = ids.indexOf(id)
    if (i < 0) return
    const colKey = td.dataset['col']!
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'd') {
      e.preventDefault()
      dupLine(i)
      return
    }
    if ((e.ctrlKey || e.metaKey) && e.key === 'Delete') {
      e.preventDefault()
      delLine(i)
      return
    }
    const isInput = target instanceof HTMLInputElement
    const isButton = target instanceof HTMLButtonElement
    const k = e.key
    if (isButton || e.ctrlKey || e.altKey || e.metaKey) return
    if (k !== 'Enter' && k !== 'Tab' && k !== 'ArrowUp' && k !== 'ArrowDown' && k !== 'ArrowLeft' && k !== 'ArrowRight') return
    if (target instanceof HTMLSelectElement && k !== 'Enter' && k !== 'Tab') return
    if ((k === 'ArrowLeft' || k === 'ArrowRight') && isInput) {
      const edge = k === 'ArrowLeft' ? 0 : target.value.length
      if (target.selectionStart !== edge || target.selectionEnd !== edge) return
    }
    const pos = view.indexOf(i)
    const nav = nextCell({
      cols: editableCols.map((c) => c.key),
      isSkipped: (row, col) => !!columns.find((c) => c.key === col)?.skip?.(lines[view[row]!]!),
      rows: view.length,
      row: pos,
      col: editableCols.findIndex((c) => c.key === colKey),
      key: k,
      shift: e.shiftKey,
      full: lines.length >= max,
    })
    if (nav.kind === 'stay') return
    e.preventDefault()
    touch(id)
    if (nav.kind === 'cell') {
      focusCell(view[nav.row]!, editableCols[nav.col]!.key)
    } else if (nav.kind === 'add') {
      if (search.trim() !== '') setSearch('')
      addLine()
    } else {
      setNotice({ kind: 'warn', text: t('maxHit', { max }) })
      announce(t('maxHit', { max }))
    }
  }

  // ---- paste ----
  const onPaste = (e: React.ClipboardEvent<HTMLElement>) => {
    if (readOnly || state !== 'ready' || props.noPermission) return
    const target = e.target as HTMLElement
    const td = target.closest<HTMLElement>('td[data-col]')
    const tr = target.closest<HTMLElement>('tr[data-id]')
    // Outside the table only the empty state takes a paste (the toolbar fields keep theirs).
    if (!td && !(emptyDoc && !(target instanceof HTMLInputElement))) return
    const m = parsePaste(e.clipboardData.getData('text'))
    if (!m.multi) return
    e.preventDefault()
    const pasteCols = columns.filter((c) => c.cell)
    let startCol = pasteCols.findIndex((c) => c.key === td?.dataset['col'])
    if (startCol < 0) startCol = 0
    const startRow = tr ? ids.indexOf(Number(tr.dataset['id'])) : 0
    if (emptyDoc) setOpened(true)
    const next = [...base]
    const nid = [...baseIds]
    const details: { row: number; reason: string }[] = []
    let added = 0
    let refused = 0
    m.rows.forEach((cells, r) => {
      const at = startRow + r
      let line: L
      if (at < next.length) line = next[at]!
      else if (next.length >= max) {
        refused += 1
        details.push({ row: r + 1, reason: t('r.max') })
        return
      } else {
        line = blank()
        next.push(line)
        nid.push(++seq.current)
      }
      cells.forEach((text, k) => {
        const col = pasteCols[startCol + k]
        if (!col?.paste) return
        const res = col.paste(line, text)
        line = res.line
        if (res.reason) details.push({ row: r + 1, reason: res.reason })
      })
      next[at < next.length ? at : next.length - 1] = line
      added += 1
    })
    setTouched((st) => new Set([...st, ...nid]))
    apply(next, nid)
    const text = refused > 0 ? t('pastedRefused', { n: added, m: refused, max }) : t('pasted', { n: added })
    setNotice({ kind: refused > 0 || details.length > 0 ? 'warn' : 'ok', text, details })
    announce(text)
  }

  // ---- scan ----
  const [scanText, setScanText] = useState('')
  const [scanMsg, setScanMsg] = useState<{ text: string; err: boolean } | null>(null)
  const scanRef = useRef<HTMLInputElement>(null)
  const doScan = () => {
    const code = scanText.trim()
    if (!code || !props.scan) return
    const res = props.scan(code, base)
    let msg: { text: string; err: boolean }
    if (res.status === 'unknown') msg = { text: t('scanUnknown', { code }), err: true }
    else if (res.status === 'new' && base.length >= max) msg = { text: t('scanFull', { max }), err: true }
    else {
      const nid = res.status === 'new' ? [...baseIds, ++seq.current] : [...baseIds]
      if (res.status === 'new') setOpened(true)
      apply(res.lines, nid)
      const at = res.index ?? res.lines.length - 1
      const lineId = nid[at]!
      touch(lineId)
      setFlash(lineId)
      const pos = view.indexOf(at)
      if (pos >= 0 || search.trim() === '') (effMode === 'grid' ? gridV : savedV).scrollToRow(pos >= 0 ? pos : at)
      msg =
        res.status === 'new'
          ? { text: t('scannedNew', { code, n: at + 1 }), err: false }
          : { text: t('scanned', { code, q: res.qty ?? '' }), err: false }
    }
    setScanMsg(msg)
    announce(msg.text)
    setScanText('')
    scanRef.current?.focus()
  }

  // ---- import ----
  const importRows = useCallback(
    (rows: { line: L; reason?: string }[]) => {
      const room = Math.max(0, max - base.length)
      const take = rows.slice(0, room)
      const next = [...base, ...take.map((r) => r.line)]
      const nid = [...baseIds, ...take.map(() => ++seq.current)]
      setOpened(true)
      apply(next, nid)
      setTouched((st) => new Set([...st, ...nid]))
      const refused = rows.length - take.length
      const details = [
        ...rows.map((r, k) => (r.reason ? { row: k + 1, reason: r.reason } : null)).filter((x): x is { row: number; reason: string } => x !== null),
        ...rows.slice(room).map((_, k) => ({ row: room + k + 1, reason: t('r.max') })),
      ]
      const text = refused > 0 ? t('imported', { n: take.length, m: refused }) : t('importedAll', { n: take.length })
      setNotice({ kind: refused > 0 ? 'warn' : 'ok', text, details })
      announce(text)
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [base, baseIds, max, apply, touch, t],
  )

  const showResult = useCallback(
    (r: { added: number; refused: { row: number; reason: string }[] }) => {
      const text = r.refused.length > 0 ? t('imported', { n: r.added, m: r.refused.length }) : t('importedAll', { n: r.added })
      setNotice({ kind: r.refused.length > 0 ? 'warn' : 'ok', text, details: r.refused })
      announce(text)
    },
    [t],
  )
  const showError = useCallback(
    (message: string) => {
      setNotice({ kind: 'warn', text: message })
      announce(message)
    },
    [],
  )

  // ---- line by line form ----
  const [form, setForm] = useState<FormState<L>>({ open: false, idx: -1, draft: blank(), showErr: false })
  function openForm(idx: number) {
    setForm({ open: true, idx, draft: idx >= 0 ? lines[idx]! : blank(), showErr: false })
  }
  const formErrs = props.validateLine ? props.validateLine(form.draft) : []
  const saveForm = (andNext: boolean) => {
    if (formErrs.length > 0) {
      setForm((f) => ({ ...f, showErr: true }))
      announce(formErrs.map((e) => e.message).join('. '))
      return
    }
    const at = form.idx
    if (at < 0) {
      if (base.length >= max) {
        setNotice({ kind: 'warn', text: t('maxHit', { max }) })
        return
      }
      setOpened(true)
      const nid = [...baseIds, ++seq.current]
      apply([...base, form.draft], nid)
      touch(nid[nid.length - 1]!)
      announce(t('saved', { n: base.length + 1 }))
    } else {
      onChange(lines.map((l, j) => (j === at ? form.draft : l)))
      touch(ids[at]!)
      announce(t('saved', { n: at + 1 }))
    }
    if (andNext && base.length + (at < 0 ? 1 : 0) < max) {
      setForm({ open: true, idx: -1, draft: blank(), showErr: false })
      requestAnimationFrame(() => rootRef.current?.querySelector<HTMLElement>('.lf-le__form [data-le-first] input, .lf-le__form [data-le-first] select')?.focus())
    } else setForm((f) => ({ ...f, open: false }))
  }
  const formErrFor = (col: string): string | undefined => (form.showErr ? formErrs.find((e) => e.col === col)?.message : undefined)

  // ---- next error ----
  const errCursor = useRef(-1)
  const nextError = () => {
    if (errLines.length === 0) return
    const after = errLines.find((i) => i > errCursor.current) ?? errLines[0]!
    errCursor.current = after
    const firstBad = errorsByLine.get(after)?.find((e) => e.col)?.col ?? firstCol
    if (effMode === 'form') {
      openForm(after)
      setForm((f) => ({ ...f, showErr: true }))
    } else {
      setSearch('')
      focusCell(after, editableCols.some((c) => c.key === firstBad) ? firstBad : firstCol)
    }
    setFlash(ids[after]!)
  }

  // ---- status line (errors of the focused row) ----
  const [focusLine, setFocusLine] = useState<number | null>(null)
  const statusErrs = focusLine !== null ? errorsByLine.get(ids.indexOf(focusLine)) : undefined

  // ================================ render ================================
  const showImport = !readOnly && props.onImport
  const importCtl: LeImportController<L> = { importRows, showResult, showError }
  const rowErrorMark = (i: number) => {
    const n = i + 1
    return errorsByLine.has(i) ? (
      <span className="lf-le__errmark" title={t('rowErr', { n })} role="img" aria-label={t('rowErr', { n })}>
        <AlertTriangle className="lf-icon" aria-hidden="true" />
      </span>
    ) : null
  }

  const cellCtx = (i: number, key: string, inForm: boolean) => {
    const errs = errorsByLine.get(i)?.filter((e) => e.col === key) ?? []
    return {
      line: lines[i]!,
      index: i,
      id: `ln-${i}-${key}`,
      invalid: errs.length > 0,
      describedBy: errs.length > 0 ? `ln-${i}-err` : undefined,
      patch: (p: Partial<L>) => patchLine(i, p),
      onBlur: () => touch(ids[i]!),
      inForm,
    }
  }

  const gridRow = (i: number, pos: number): ReactNode => {
    const l = lines[i]!
    const errs = errorsByLine.get(i)
    const id = ids[i]!
    return (
      <tr
        key={id}
        className={`lf-le__row${errs ? ' is-error' : ''}${flash === id ? ' is-flash' : ''}`}
        role="row"
        aria-rowindex={pos + 2}
        data-id={id}
        data-testid={readOnly ? 'line-row' : 'line-editor-row'}
      >
        <td className="is-idx" role="gridcell">
          {rowErrorMark(i)}
          {i + 1}
        </td>
        {columns.map((c) => {
          const editable = !readOnly && c.cell
          return (
            <td
              key={c.key}
              className={c.num ? 'is-num' : undefined}
              role="gridcell"
              data-col={c.key}
              data-label={c.label}
              title={errs?.filter((e) => e.col === c.key).map((e) => e.message).join('. ') || undefined}
            >
              {editable ? (c.skip?.(l) ? '—' : c.cell!(cellCtx(i, c.key, false))) : c.view(l)}
            </td>
          )
        })}
        {!readOnly && (
          <td className="is-act" role="gridcell">
            <Button variant="ghost" size="sm" iconOnly icon={<Copy className="lf-icon" aria-hidden="true" />} label={t('dup', { n: i + 1 })} onClick={() => dupLine(i)} disabled={lines.length >= max} />
            <Button variant="ghost" size="sm" iconOnly icon={<Trash2 className="lf-icon" aria-hidden="true" />} label={t('del', { n: i + 1 })} onClick={() => delLine(i)} />
          </td>
        )}
      </tr>
    )
  }

  const spacer = (h: number, span: number, k: string) =>
    h > 0 ? (
      <tr key={k} className="lf-le__sp" aria-hidden="true">
        <td colSpan={span} style={{ height: h }} />
      </tr>
    ) : null

  const totals = props.totals?.(lines)
  const gridBody = () => {
    const span = columns.length + 1 + (readOnly ? 0 : 1)
    const w = gridV.win
    const totIdx = totals ? columns.findIndex((c) => c.key === totals.col) : -1
    return (
      <>
        <div className="lf-le__scroll" ref={gridV.ref} onScroll={gridV.onScroll} tabIndex={0} role="grid" aria-label={t('lines')} aria-rowcount={view.length + 1} data-testid="lines-scroll">
          <table ref={tableRef} className={`lf-le__table${columns.length > 5 ? ' lf-le__table--wide' : ''}`} role="presentation" data-testid={readOnly ? 'document-lines' : undefined}>
            <thead>
              <tr>
                <th className="is-idx" scope="col">
                  {t('c.idx')}
                </th>
                {columns.map((c) => (
                  <th key={c.key} scope="col" data-col={props.resize ? c.colId : undefined} className={[c.num ? 'is-num' : '', c.grow ? 'is-grow' : '', `is-col-${c.key}`].filter(Boolean).join(' ')}>
                    {c.label}
                  </th>
                ))}
                {!readOnly && (
                  <th className="is-act" scope="col">
                    <span className="sr-only">{t('c.act')}</span>
                  </th>
                )}
              </tr>
            </thead>
            <tbody onKeyDown={onGridKey} onFocus={(e) => setFocusLine(Number((e.target as HTMLElement).closest<HTMLElement>('tr[data-id]')?.dataset['id'] ?? NaN) || null)}>
              {spacer(w.padTop, span, 'top')}
              {view.slice(w.first, w.last).map((i, k) => gridRow(i, w.first + k))}
              {spacer(w.padBottom, span, 'bot')}
            </tbody>
            <tfoot>
              <tr>
                {totals && totIdx >= 0 ? (
                  <>
                    <td colSpan={totIdx + 1}>
                      <span className="lf-le__totlab">{t('totals')}</span> · <span className="lf-le__totlab">{t('lines')}</span> <span className="mono">{lines.length}</span>
                    </td>
                    <td className="is-num">{totals.node}</td>
                    <td colSpan={span - totIdx - 2} />
                  </>
                ) : (
                  <td colSpan={span}>
                    <span className="lf-le__totlab">{t('totals')}</span> · <span className="lf-le__totlab">{t('lines')}</span> <span className="mono">{lines.length}</span>
                  </td>
                )}
              </tr>
            </tfoot>
          </table>
        </div>
        <div className={`lf-le__status${statusErrs ? ' is-error' : ''}`} aria-live="polite">
          {statusErrs ? (
            <span>
              {statusErrs.map((e) => (e.col ? `${columns.find((c) => c.key === e.col)?.label ?? e.col}: ${e.message}` : e.message)).join('. ')}
            </span>
          ) : (
            <span className="lf-faint">{readOnly ? '' : t('gridHint')}</span>
          )}
        </div>
      </>
    )
  }

  const savedCols = columns.filter((c) => !c.savedHidden)
  const savedTable = () => {
    const w = savedV.win
    const span = savedCols.length + 1
    return (
      <div className="lf-le__saved">
        <h3 className="lf-le__formtitle">{t('savedLines')}</h3>
        <div className="lf-le__scroll lf-le__scroll--saved" ref={savedV.ref} onScroll={savedV.onScroll} tabIndex={0} data-testid="lines-saved">
          <table className="lf-le__table lf-le__table--saved" role="presentation">
            <thead>
              <tr>
                <th className="is-idx" scope="col">
                  #
                </th>
                {savedCols.map((c) => (
                  <th key={c.key} scope="col" className={c.num ? 'is-num' : undefined}>
                    {c.label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {spacer(w.padTop, span, 'top')}
              {view.slice(w.first, w.last).map((i) => {
                const id = ids[i]!
                const errs = errorsByLine.has(i)
                const sel = form.open && form.idx === i
                return (
                  <tr
                    key={id}
                    className={`lf-le__row lf-le__row--saved${readOnly ? ' is-ro' : ''}${errs ? ' is-error' : ''}${sel ? ' is-sel' : ''}${flash === id ? ' is-flash' : ''}`}
                    data-id={id}
                    data-testid="line-saved-row"
                    {...(readOnly
                      ? {}
                      : {
                          tabIndex: 0,
                          role: 'button',
                          'aria-label': t('editLine', { n: i + 1 }),
                          onClick: () => openForm(i),
                          onKeyDown: (e: React.KeyboardEvent) => {
                            if (e.key === 'Enter' || e.key === ' ') {
                              e.preventDefault()
                              openForm(i)
                            }
                          },
                        })}
                  >
                    <td className="is-idx">
                      {rowErrorMark(i)}
                      {i + 1}
                    </td>
                    {savedCols.map((c) => (
                      <td key={c.key} className={c.num ? 'is-num' : undefined}>
                        <span className="lf-le__cut">{c.view(lines[i]!)}</span>
                      </td>
                    ))}
                  </tr>
                )
              })}
              {spacer(w.padBottom, span, 'bot')}
            </tbody>
          </table>
        </div>
      </div>
    )
  }

  const formBody = () => {
    if (readOnly) return <div className="lf-le__formwrap lf-le__formwrap--ro">{savedTable()}</div>
    const n = form.idx >= 0 ? form.idx + 1 : base.length + 1
    return (
      <div className="lf-le__formwrap">
        <div className={`lf-le__formcol${form.open ? '' : ' lf-le__formcol--closed'}`}>
          {form.open ? (
            <form
              className="lf-le__form"
              noValidate
              onSubmit={(e) => {
                e.preventDefault()
                saveForm(true)
              }}
              onKeyDown={(e) => {
                if (e.key === 'Escape' && !e.defaultPrevented) setForm((f) => ({ ...f, open: false }))
              }}
            >
              <h3 className="lf-le__formtitle">{form.idx >= 0 ? t('editLine', { n }) : t('newLine', { n })}</h3>
              <div className="lf-le__formrow">
                {editableCols.map((c, k) => {
                  const err = formErrFor(c.key)
                  const hidden = c.skip?.(form.draft)
                  if (hidden) return null
                  return (
                    <div key={c.key} className="lf-field" data-le-first={k === 0 ? '' : undefined}>
                      <label className="lf-label" htmlFor={`lf-le-f-${screenId}-${c.key}`}>
                        {c.label}
                      </label>
                      {c.cell!({
                        line: form.draft,
                        index: form.idx,
                        id: `lf-le-f-${screenId}-${c.key}`,
                        invalid: err !== undefined,
                        describedBy: err ? `lf-le-f-${screenId}-${c.key}-e` : undefined,
                        patch: (p) => setForm((f) => ({ ...f, draft: { ...f.draft, ...p } })),
                        onBlur: () => undefined,
                        inForm: true,
                      })}
                      {err && (
                        <span className="lf-error" id={`lf-le-f-${screenId}-${c.key}-e`} role="alert">
                          {err}
                        </span>
                      )}
                    </div>
                  )
                })}
              </div>
              <div className="lf-form__actions">
                <Button variant="primary" type="submit" disabled={form.idx < 0 && atMax}>
                  {t('saveNext')}
                </Button>
                <Button variant="secondary" onClick={() => saveForm(false)} disabled={form.idx < 0 && atMax}>
                  {t('saveClose')}
                </Button>
                <Button variant="ghost" onClick={() => setForm((f) => ({ ...f, open: false }))}>
                  {t('cancel')}
                </Button>
                {form.idx >= 0 && (
                  <span className="lf-le__del">
                    <Button
                      variant="danger"
                      onClick={() => {
                        delLine(form.idx)
                        setForm((f) => ({ ...f, open: false }))
                      }}
                    >
                      {t('delete')}
                    </Button>
                  </span>
                )}
              </div>
            </form>
          ) : (
            <Button variant="primary" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={() => openForm(-1)} disabled={atMax}>
              {t('add')}
            </Button>
          )}
        </div>
        {savedTable()}
      </div>
    )
  }

  const body = () => {
    if (props.noPermission) return <NoPermissionState />
    if (state === 'loading') return <LoadingState />
    if (state === 'error') return <ErrorState onRetry={props.onRetry} />
    if (readOnly && lines.length === 0) return <EmptyState readOnly />
    if (emptyDoc && effMode === 'grid' && !readOnly) return <EmptyState onAdd={addLine} onImport={showImport ? () => props.onImport!(importCtl) : undefined} importDisabledReason={props.importDisabledReason} />
    if (effMode === 'grid') {
      return (
        <>
          {gridBody()}
          {search.trim() !== '' && view.length === 0 && <NoMatchState onClear={() => setSearch('')} />}
        </>
      )
    }
    return formBody()
  }

  const stateReady = !props.noPermission && state === 'ready'
  const showTools = stateReady
  const countText = search.trim() !== '' ? t('countView', { a: view.length, n: lines.length }) : t('count', { n: emptyDoc ? 0 : lines.length, max })
  const gridDisabledWhy = narrow ? t('gridOff') : undefined

  return (
    <div className="lf-le" ref={rootRef} onPaste={onPaste} data-mode={effMode} data-readonly={readOnly ? 'true' : 'false'} data-testid={props['data-testid'] ?? 'lines-editor'}>
      {showTools && (
        <div className="lf-le__toolbar">
          <div className="lf-seg" role="group" aria-label={t('modeLabel')}>
            <button type="button" aria-pressed={effMode === 'grid'} disabled={narrow} title={gridDisabledWhy} onClick={() => onModeChange('grid')} data-testid="mode-grid">
              {t('grid')}
              {narrow && <span className="sr-only"> — {t('gridOff')}</span>}
            </button>
            <button type="button" aria-pressed={effMode === 'form'} onClick={() => onModeChange('form')} data-testid="mode-form">
              {t('form')}
            </button>
          </div>
          {props.scan && !readOnly && (
            <div className="lf-field lf-le__scanf">
              <label className="lf-label sr-only" htmlFor={`${screenId}-scan`}>
                {t('scanLabel')}
              </label>
              <div className="lf-control lf-control--mono">
                <span className="lf-control__lead">
                  <ScanLine className="lf-icon" aria-hidden="true" />
                </span>
                <input
                  id={`${screenId}-scan`}
                  ref={scanRef}
                  autoComplete="off"
                  spellCheck={false}
                  placeholder={t('scan')}
                  value={scanText}
                  onChange={(e) => setScanText(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault()
                      doScan()
                    }
                  }}
                />
              </div>
              {scanMsg && (
                <span className={`lf-error lf-le__scanmsg${scanMsg.err ? '' : ' is-ok'}`} role="status">
                  {scanMsg.err ? <AlertTriangle className="lf-icon" aria-hidden="true" /> : <CheckCircle2 className="lf-icon" aria-hidden="true" />}
                  <span>{scanMsg.text}</span>
                </span>
              )}
            </div>
          )}
          <div className="lf-field lf-le__searchf">
            <label className="lf-label sr-only" htmlFor={`${screenId}-q`}>
              {t('searchLabel')}
            </label>
            <div className="lf-control">
              <span className="lf-control__lead">
                <Search className="lf-icon" aria-hidden="true" />
              </span>
              <input id={`${screenId}-q`} autoComplete="off" placeholder={t('search')} value={search} onChange={(e) => setSearch(e.target.value)} />
            </div>
          </div>
          <div className="lf-le__tools">
            {errLines.length > 0 && (
              <Button variant="secondary" size="sm" className="lf-le__errbtn" onClick={nextError}>
                {errLines.length === 1 ? t('errors1') : t('errorsN', { n: errLines.length })} – {t('next')}
              </Button>
            )}
            {showImport && (
              <Button variant="secondary" size="sm" icon={<Upload className="lf-icon" aria-hidden="true" />} onClick={() => props.onImport!(importCtl)} disabled={props.importDisabledReason !== undefined || atMax} title={props.importDisabledReason}>
                {t('imp')}
              </Button>
            )}
            {!readOnly && effMode === 'grid' && !emptyDoc && (
              <Button variant="secondary" size="sm" icon={<Plus className="lf-icon" aria-hidden="true" />} onClick={addLine} disabled={atMax}>
                {t('add')}
              </Button>
            )}
            <span className={`lf-le__count mono-s${atMax ? ' is-max' : ''}`} aria-live="polite">
              {countText}
            </span>
          </div>
        </div>
      )}
      <div className="lf-le__notices">
        {atMax && !readOnly && (
          <div className="lf-banner lf-banner--warning" role="status" data-testid="lines-max">
            <AlertTriangle className="lf-icon lf-icon--18" aria-hidden="true" />
            <div>
              <strong>{t('max', { max })}</strong>
              <p>{t('maxText', { max })}</p>
            </div>
          </div>
        )}
        {props.listError && (
          <p role="alert" className="lf-error">
            {props.listError}
          </p>
        )}
        {notice && (
          <div className={`lf-banner lf-banner--${notice.kind === 'ok' ? 'success' : 'warning'}`} role="status" data-testid="lines-notice">
            <AlertTriangle className="lf-icon lf-icon--18" aria-hidden="true" />
            <div>
              <span>{notice.text}</span>
              {notice.details && notice.details.length > 0 && (
                <details className="lf-le__reasons">
                  <summary>
                    {t('reasons')} ({notice.details.length})
                  </summary>
                  <ul>
                    {notice.details.slice(0, 50).map((d, k) => (
                      <li key={k}>
                        <span className="mono-s">{t('row', { n: d.row })}</span> {d.reason}
                      </li>
                    ))}
                  </ul>
                </details>
              )}
            </div>
            <Button variant="ghost" size="sm" onClick={() => setNotice(null)}>
              {t('close')}
            </Button>
          </div>
        )}
      </div>
      <div className="lf-le__body">{body()}</div>
      <div className="lf-le__live sr-only" role="status" aria-live="polite">
        {live}
      </div>
    </div>
  )
}
