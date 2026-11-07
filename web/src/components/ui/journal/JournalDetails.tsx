/** JournalDetails — the details pane of the journal: bar (Back, previous/next with "n of N", Close for the sheet),
 *  head (kind + document link + status), then the sections the module passes in; JournalLegs draws the legs both
 *  inline under a row (compact) and in the pane. Classes `lf-jrn__*` and `lf-reg__*` come from components.css. */
import { useEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import { ArrowLeft, ChevronLeft, ChevronRight, Layers, Maximize2, X } from 'lucide-react'
import { Link } from 'react-router-dom'
import { Button } from '../Button'
import { EmptyState } from '../EmptyState'
import { StatusPill, type StatusGlyph, type StatusTone } from '../StatusPill'
import { useColResize, type ColSpec } from '../layout/ColumnResize'
import { useLayoutMessages } from '../layout/layoutMessages'
import { RegistryDetailsSkeleton, RegistrySection } from '../registry'
import type { JournalLeg, JournalOp, JournalSign, JournalStatus } from './journalTypes'

const STATUS_LOOK: Record<JournalStatus, { tone: StatusTone; glyph: StatusGlyph }> = {
  posted: { tone: 'success', glyph: 'dot' },
  reversed: { tone: 'neutral', glyph: 'dash' },
  reversal: { tone: 'warning', glyph: 'ring' },
}

export function JournalStatusPill({ status, label }: { status: JournalStatus; label: string }) {
  const look = STATUS_LOOK[status]
  return <StatusPill tone={look.tone} glyph={look.glyph}>{label}</StatusPill>
}

/** "code - title" as the design's reference: mono code, separator, title (cut with an ellipsis by the CSS). */
export function JournalRef({ text, full, className }: { text: string; /** Tooltip with the whole text when `text` is shortened. */ full?: string; className?: string }) {
  const at = text.indexOf(' - ')
  if (at < 0) {
    return <span className={className ? `lf-ref ${className}` : 'lf-ref'}><span className="lf-ref__title">{text}</span></span>
  }
  return (
    <span className={className ? `lf-ref ${className}` : 'lf-ref'} title={full ?? text}>
      <span className="lf-ref__code">{text.slice(0, at)}</span>
      <span className="lf-ref__sep" aria-hidden="true">–</span>
      <span className="lf-ref__title">{text.slice(at + 3)}</span>
    </span>
  )
}

const SIGN_GLYPH: Record<'pos' | 'neg', { glyph: string; word: string }> = {
  pos: { glyph: '+', word: '+' },
  neg: { glyph: '−', word: '−' },
}

/** A quantity with its sign glyph (decorative) and the sign as text for assistive technology. */
export function JournalSigned({ sign, text }: { sign: JournalSign; text: string }) {
  if (sign === '') return <>{text}</>
  const g = SIGN_GLYPH[sign]
  return (
    <>
      <span className={`lf-jrn__sign lf-jrn__sign--${sign}`} aria-hidden="true">{g.glyph}</span>
      <span className="sr-only">{g.word}</span>
      {text}
    </>
  )
}

export interface JournalLegsLabels {
  legs: string
  heldBy: string
  hiddenUnit: string
  change: string
  /** Column names of the legs table. */
  location: string
  item: string
}

/** Widths of the legs table in percent of the table (the last column, the change, takes the rest). */
const LEG_COLS: ColSpec[] = [
  { id: 'loc', w: 40, min: 120 },
  { id: 'item', w: 34, min: 120 },
  { id: 'chg', w: 0, min: 80 },
]

/** The legs as a table with resizable columns; the CSS shows it when the details pane is 520 px wide or more. */
export function JournalLegTable({ legs, labels, screen }: { legs: JournalLeg[]; labels: JournalLegsLabels; screen: string }) {
  const ref = useRef<HTMLTableElement>(null)
  const word = useLayoutMessages().resizeColumn
  useColResize(ref, {
    id: 'legs',
    screen,
    cols: LEG_COLS,
    label: (_id, th) => `${word}: ${th.textContent?.trim() ?? ''}`,
  })
  return (
    <table className="lf-jrn__legtable" ref={ref} aria-label={labels.legs} data-testid="journal-legtable">
      <thead>
        <tr>
          <th scope="col" data-col="loc">{labels.location}</th>
          <th scope="col" data-col="item">{labels.item}</th>
          <th scope="col" data-col="chg" className="is-num">{labels.change}</th>
        </tr>
      </thead>
      <tbody>
        {legs.map((l) => (
          <tr key={l.id} data-testid="journal-legrow">
            {l.hidden ? (
              <td colSpan={2}><span className="lf-muted">{labels.hiddenUnit}</span></td>
            ) : (
              <>
                <td>
                  <JournalRef text={l.location} />
                  {l.holder !== '' && <div><span className="lf-jrn__holder">{labels.heldBy} {l.holder}</span></div>}
                </td>
                <td><JournalRef text={l.item} /></td>
              </>
            )}
            <td className="is-num">
              <span className="lf-jrn__delta"><JournalSigned sign={l.sign} text={l.qty} /></span>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

export function JournalLegs({ legs, compact, labels }: { legs: JournalLeg[]; compact?: boolean; labels: JournalLegsLabels }) {
  return (
    <ul className={compact ? 'lf-jrn__legs lf-jrn__legs--compact' : 'lf-jrn__legs'} aria-label={labels.legs} data-testid="journal-legs">
      {legs.map((l) => (
        <li className="lf-jrn__leg" key={l.id} data-testid="journal-leg">
          <div className="lf-jrn__leg-main">
            {l.hidden ? (
              <span className="lf-muted">{labels.hiddenUnit}</span>
            ) : (
              <>
                <JournalRef text={l.location} />
                <JournalRef text={l.item} />
              </>
            )}
            {l.holder !== '' && <span className="lf-jrn__holder">{labels.heldBy} {l.holder}</span>}
          </div>
          <div className="lf-jrn__leg-num">
            <span className="lf-jrn__delta" aria-label={labels.change}>
              <JournalSigned sign={l.sign} text={l.qty} />
            </span>
          </div>
        </li>
      ))}
    </ul>
  )
}

export interface JournalDetailsLabels {
  pane: string
  back: string
  prev: string
  next: string
  close: string
  sections: string
  /** "3 of 12" */
  position: string
  legsTitle: string
  legs: JournalLegsLabels
  blankTitle: string
  blankText: string
  /** Label of the wide-screen Details button (only drawn with `onOpenFull`). */
  details?: string
}

export interface JournalDetailsProps {
  labels: JournalDetailsLabels
  /** null: nothing selected (blank pane). */
  op: JournalOp | null
  loading?: boolean
  hasPrev: boolean
  hasNext: boolean
  onBack: () => void
  onPrev: () => void
  onNext: () => void
  /** Wide screens: opens the full-screen view (Back, previous/next). No button when absent. */
  onOpenFull?: () => void
  /** Sections after the head: fields card, links card (the module builds them from RegistryFields / RegistrySection). */
  fields: ReactNode
  links: ReactNode
  /** Screen id of the remembered layout (column widths of the legs table). */
  layoutScreen: string
}

/** True while the element is 520 px wide or more (the width at which the CSS swaps the leg cards for the table). The
 *  state change re-renders, so the column handles bind after a drag of the divider crosses that width. */
function useTableMode(ref: RefObject<HTMLElement>, active: boolean): void {
  const [, setMode] = useState(false)
  useEffect(() => {
    const el = ref.current
    if (!el || !active || typeof ResizeObserver === 'undefined') return
    let last = el.clientWidth >= 520
    const ro = new ResizeObserver(() => {
      const now = el.clientWidth >= 520
      if (now !== last) {
        last = now
        setMode(now)
      }
    })
    ro.observe(el)
    return () => ro.disconnect()
  }, [ref, active])
}

export function JournalDetails(p: JournalDetailsProps) {
  const L = p.labels
  const rootRef = useRef<HTMLDivElement>(null)
  useTableMode(rootRef, !p.loading && p.op !== null)
  if (p.loading) {
    return <div className="lf-jrn__details" aria-label={L.pane}><RegistryDetailsSkeleton /></div>
  }
  if (!p.op) {
    return (
      <div className="lf-jrn__details" aria-label={L.pane} data-testid="journal-details">
        <div className="lf-card lf-reg__blank" data-testid="journal-blank">
          <EmptyState icon={<Layers className="lf-icon lf-empty__icon" aria-hidden="true" />} title={L.blankTitle} text={L.blankText} />
        </div>
      </div>
    )
  }
  const op = p.op
  return (
    <div className="lf-jrn__details" id="jr-details" ref={rootRef} aria-label={L.pane} data-testid="journal-details">
      <div className="lf-jrn__handle" aria-hidden="true" />
      <div className="lf-jrn__bar">
        <div className="lf-reg__backrow">
          <Button
            variant="ghost"
            size="sm"
            className="lf-reg__back"
            icon={<ArrowLeft className="lf-icon" aria-hidden="true" />}
            onClick={p.onBack}
            data-testid="journal-back"
          >
            {L.back}
          </Button>
        </div>
        <nav className="lf-jrn__nav" aria-label={L.sections}>
          <Button variant="secondary" size="sm" iconOnly label={L.prev} icon={<ChevronLeft className="lf-icon" aria-hidden="true" />} disabled={!p.hasPrev} onClick={p.onPrev} data-testid="journal-prev" />
          <span className="lf-jrn__pos" aria-live="polite" data-testid="journal-pos">{L.position}</span>
          <Button variant="secondary" size="sm" iconOnly label={L.next} icon={<ChevronRight className="lf-icon" aria-hidden="true" />} disabled={!p.hasNext} onClick={p.onNext} data-testid="journal-next" />
        </nav>
        <Button variant="ghost" size="sm" iconOnly label={L.close} className="lf-jrn__close" icon={<X className="lf-icon" aria-hidden="true" />} onClick={p.onBack} data-testid="journal-close" />
      </div>
      <div className="lf-reg__head">
        <div className="lf-reg__id">
          <h2 className="lf-reg__name">
            <span className="lf-jrn__kind">{op.kindIcon}{op.kindLabel}</span>
            {op.docText !== '' &&
              (op.docHref ? (
                <Link className="lf-jrn__doclink" to={op.docHref} data-testid="journal-head-doc">{op.docText}</Link>
              ) : (
                <span className="lf-jrn__doclink">{op.docText}</span>
              ))}
          </h2>
          <JournalStatusPill status={op.status} label={op.statusLabel} />
          {p.onOpenFull && (
            <Button
              variant="secondary"
              size="sm"
              className="lf-jrn__fullbtn"
              icon={<Maximize2 className="lf-icon" aria-hidden="true" />}
              onClick={p.onOpenFull}
              data-testid="journal-open-full"
            >
              {L.details}
            </Button>
          )}
        </div>
      </div>
      {p.fields}
      <RegistrySection pane="legs" id="jr-legs" title={L.legsTitle} count={op.legs.length}>
        <JournalLegs legs={op.legs} labels={L.legs} />
        <JournalLegTable legs={op.legs} labels={L.legs} screen={p.layoutScreen} />
      </RegistrySection>
      {p.links}
    </div>
  )
}
