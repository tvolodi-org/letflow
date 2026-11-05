/** RegistryDetails — the pieces of the details pane: head (back button, code + title, status, actions), a section
 *  card, a field list, the history list, the blank and loading states. Pure presentation; classes `lf-reg__*`. */
import type { ReactNode } from 'react'
import { ArrowLeft, Info, Layers } from 'lucide-react'
import { Button } from '../Button'
import { EmptyState } from '../EmptyState'

export interface RegistryHeadProps {
  backLabel: string
  onBack: () => void
  /** Mono code and the title; both are shown in the head. */
  code: string
  title: string
  status?: ReactNode
  editing?: boolean
  editingLabel?: string
  /** Edit / Retire buttons; omitted when the user cannot write. */
  actions?: ReactNode
  /** One info line shown instead of the buttons (the user cannot write). */
  reason?: ReactNode
  /** Under the head (validation banner). */
  below?: ReactNode
}

export function RegistryHead(p: RegistryHeadProps) {
  return (
    <div className="lf-reg__top">
      <div className={p.editing ? 'lf-reg__head is-editing' : 'lf-reg__head'} data-testid="registry-head">
        <div className="lf-reg__backrow">
          <Button
            variant="ghost"
            size="sm"
            className="lf-reg__back"
            icon={<ArrowLeft className="lf-icon" aria-hidden="true" />}
            onClick={p.onBack}
            data-testid="registry-back"
          >
            {p.backLabel}
          </Button>
        </div>
        <div className="lf-reg__id">
          <h2 className="lf-reg__name">
            {p.code !== '' && <span className="mono">{p.code}</span>}
            <span>{p.title}</span>
          </h2>
          {p.status}
          {p.editing && p.editingLabel && <span className="lf-faint">{p.editingLabel}</span>}
        </div>
        {p.actions && !p.editing && <div className="lf-reg__actions">{p.actions}</div>}
        {p.reason && !p.editing && (
          <p className="lf-reg__reason" data-testid="registry-reason">
            <Info className="lf-icon" aria-hidden="true" />
            <span>{p.reason}</span>
          </p>
        )}
      </div>
      {p.below}
    </div>
  )
}

export function RegistrySection(props: {
  pane: string
  id: string
  title: string
  count?: number
  children: ReactNode
}) {
  return (
    <section className="lf-card lf-reg__section" data-pane={props.pane} aria-labelledby={props.id} data-testid={`registry-section-${props.pane}`}>
      <div className="lf-reg__sechead">
        <h3 className="lf-reg__sectitle" id={props.id}>
          {props.title}
          {props.count !== undefined && <span className="lf-count">{props.count}</span>}
        </h3>
      </div>
      {props.children}
    </section>
  )
}

export interface RegistryFieldItem {
  key: string
  label: string
  value: ReactNode
  mono?: boolean
  full?: boolean
  /** The value is empty: shown as a dash in the faint colour. */
  empty?: boolean
}

export function RegistryFields({ fields }: { fields: RegistryFieldItem[] }) {
  return (
    <dl className="lf-reg__fields">
      {fields.map((f) => (
        <div className={f.full ? 'lf-reg__field lf-reg__field--full' : 'lf-reg__field'} key={f.key} data-field={f.key}>
          <dt className="lf-reg__label">{f.label}</dt>
          <dd className={['lf-reg__value', f.mono ? 'lf-reg__value--mono' : '', f.empty ? 'is-empty' : ''].filter(Boolean).join(' ')}>
            {f.empty ? '—' : f.value}
          </dd>
        </div>
      ))}
    </dl>
  )
}

export interface RegistryHistoryItem {
  id: string
  /** Already formatted by the date formatter. */
  when: string
  iso?: string
  text: ReactNode
}

export function RegistryHistory({ items }: { items: RegistryHistoryItem[] }) {
  return (
    <ol className="lf-reg__history" data-testid="registry-history">
      {items.map((h) => (
        <li key={h.id}>
          <time dateTime={h.iso}>{h.when}</time>
          <span>{h.text}</span>
        </li>
      ))}
    </ol>
  )
}

/** A short line inside a section (nothing to show, no permission). */
export function RegistryNote({ children, testId }: { children: ReactNode; testId?: string }) {
  return (
    <p className="lf-reg__blank lf-muted" data-testid={testId}>
      {children}
    </p>
  )
}

/** The details pane when no record is open or the open record was not found. */
export function RegistryBlank(props: { title: string; text?: string }) {
  return (
    <div className="lf-card lf-reg__blank" data-testid="registry-blank">
      <EmptyState icon={<Layers className="lf-icon lf-empty__icon" aria-hidden="true" />} title={props.title} text={props.text} />
    </div>
  )
}

export function RegistryDetailsSkeleton() {
  return (
    <section className="lf-card lf-reg__section" aria-busy="true" data-testid="registry-details-loading">
      <div className="lf-reg__sechead">
        <span className="lf-skel" />
      </div>
      <div className="lf-reg__skel lf-reg__skel--fields">
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i}>
            <span className="lf-skel" />
            <span className="lf-skel" />
          </div>
        ))}
      </div>
    </section>
  )
}
