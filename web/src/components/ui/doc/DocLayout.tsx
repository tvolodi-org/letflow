/** DocLayout — the platform document form (`lf-doc`, letflow-design platform/preview/document-form.html): a list pane, a
 *  title bar with actions, a header card and a lines card in one grid. Wide: list | header | lines; medium: list and
 *  header, lines below; narrow (<900 px): the selected document replaces the list (`data-detail="open"`) and a back
 *  button shows. The arrangement is the registered layout `row` (rule 11); no per-screen CSS. Generic: no module words. */
import React from 'react'
import { ArrowLeft } from 'lucide-react'
import { Button } from '../Button'

export interface DocLayoutProps {
  /** True when a document (or a new one) is open: on narrow screens it replaces the list. */
  detailOpen: boolean
  children: React.ReactNode
  'data-testid'?: string
}

export function DocLayout({ detailOpen, children, ...rest }: DocLayoutProps) {
  return (
    <div className="lf-doc" data-layout="row" data-detail={detailOpen ? 'open' : undefined} data-testid={rest['data-testid']}>
      {children}
    </div>
  )
}

export interface DocBarProps {
  /** Title: kind name and the mono number. */
  title: React.ReactNode
  /** Status pill or other trailing marker of the title. */
  status?: React.ReactNode
  actions?: React.ReactNode
  editing?: boolean
  /** Line under the bar (why an action is missing, a warning). */
  reason?: React.ReactNode
  /** Narrow screens: back to the list. */
  onBack?: () => void
  backLabel?: string
  children?: React.ReactNode
}

/** The `lf-doc__top` cell: the bar plus any banners passed as children. */
export function DocBar({ title, status, actions, editing, reason, onBack, backLabel, children }: DocBarProps) {
  return (
    <div className="lf-doc__top">
      <div className={editing ? 'lf-doc__bar is-editing' : 'lf-doc__bar'}>
        {onBack && (
          <div className="lf-doc__backrow">
            <Button variant="ghost" size="sm" className="lf-doc__back" icon={<ArrowLeft className="lf-icon" aria-hidden="true" />} onClick={onBack}>
              {backLabel}
            </Button>
          </div>
        )}
        <div className="lf-doc__id">
          <h2 className="lf-doc__title">{title}</h2>
          {status}
        </div>
        <div className="lf-doc__actions">{actions}</div>
        {reason && <p className="lf-doc__reason">{reason}</p>}
      </div>
      {children}
    </div>
  )
}

export function DocCard(props: {
  area: 'header' | 'lines'
  title: string
  count?: number
  children: React.ReactNode
  'data-testid'?: string
}) {
  return (
    <section className={`lf-card lf-doc__${props.area}`} aria-label={props.title} data-testid={props['data-testid']}>
      <div className="lf-doc__head">
        <h3 className="lf-doc__section">
          {props.title}
          {props.count !== undefined && <> <span className="lf-count">{props.count}</span></>}
        </h3>
      </div>
      {props.children}
    </section>
  )
}

/** View: label/value list. Edit: a grid of form fields. */
export function DocFields(props: { editing?: boolean; children: React.ReactNode; 'data-testid'?: string }) {
  return props.editing ? (
    <div className="lf-doc__fields" data-testid={props['data-testid']}>{props.children}</div>
  ) : (
    <dl className="lf-doc__fields" data-testid={props['data-testid']}>{props.children}</dl>
  )
}

export function DocField(props: { label: string; value: React.ReactNode; mono?: boolean; full?: boolean; empty?: boolean }) {
  return (
    <div className={props.full ? 'lf-doc__field lf-doc__field--full' : 'lf-doc__field'}>
      <dt className="lf-doc__label">{props.label}</dt>
      <dd className={props.empty ? 'lf-doc__value is-empty' : props.mono ? 'lf-doc__value mono' : 'lf-doc__value'}>{props.value}</dd>
    </div>
  )
}

/** An edit-mode field cell (wraps a Field/Select). */
export function DocEdit(props: { full?: boolean; children: React.ReactNode }) {
  return <div className={props.full ? 'lf-doc__field lf-doc__field--full' : 'lf-doc__field'}>{props.children}</div>
}

export function DocGroup({ children }: { children: React.ReactNode }) {
  return <div className="lf-doc__group">{children}</div>
}

/** The pane shown when no document is selected. */
export function DocBlank(props: { title: string; text: string }) {
  return (
    <section className="lf-card lf-doc__blank" data-testid="document-blank">
      <div className="lf-doc__empty">
        <div className="lf-empty">
          <p className="lf-empty__title">{props.title}</p>
          <p className="lf-empty__text">{props.text}</p>
        </div>
      </div>
    </section>
  )
}
