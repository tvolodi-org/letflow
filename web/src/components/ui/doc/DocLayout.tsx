/** DocLayout — the platform document form (`lf-doc`, letflow-design platform/preview/document-form.html): a list pane, a
 *  title bar with actions, a header card and a lines card in one grid. Wide: list | header | lines; medium: list and
 *  header, lines below; narrow (<900 px): the selected document replaces the list (`data-detail="open"`) and a back
 *  button shows. The arrangement is the registered layout `row` (rule 11); no per-screen CSS. Generic: no module words. */
import React, { createContext, useContext, useRef, useState } from 'react'
import { AlertTriangle, ArrowLeft } from 'lucide-react'
import { Button } from '../Button'
import { DEFAULT_DOC_LAYOUT, DOC_LAYOUTS, defaultTabFor, type DocLayoutName, type DocPane } from './docLayouts'

export interface DocLayoutProps {
  /** True when a document (or a new one) is open: on narrow screens it replaces the list. */
  detailOpen: boolean
  children: React.ReactNode
  'data-testid'?: string
  /** The registered layout (docLayouts.ts); `row` when absent. */
  layout?: DocLayoutName
  /** Whether a document is open and how it opens: a new one on its default tab, an existing one on its own. */
  docState?: 'new' | 'existing' | 'none'
  /** Identity of the open document; the tab the user chose is kept only while this stays the same. */
  docKey?: string
}

interface DocTabsContext {
  tabsLayout: boolean
  activeTab: DocPane | null
  setTab: (pane: DocPane) => void
}

const NO_TABS: DocTabsContext = { tabsLayout: false, activeTab: null, setTab: () => undefined }
const DocTabs = createContext<DocTabsContext>(NO_TABS)

/** Tab state of the surrounding DocLayout (a no-op context outside one). */
export function useDocTabs(): DocTabsContext {
  return useContext(DocTabs)
}

export function DocLayout({ detailOpen, children, layout = DEFAULT_DOC_LAYOUT, docState = 'none', docKey = '', ...rest }: DocLayoutProps) {
  // The user's choice is kept per document key: another document (or a draft turned into a saved one) falls back to the default.
  const [chosen, setChosen] = useState<{ key: string; pane: DocPane } | null>(null)
  const tabsLayout = DOC_LAYOUTS[layout].tabs !== null && docState !== 'none'
  const fallback = docState === 'none' ? null : defaultTabFor(layout, docState)
  const activeTab = tabsLayout ? (chosen && chosen.key === docKey ? chosen.pane : fallback) : null
  const ctx: DocTabsContext = { tabsLayout, activeTab, setTab: (pane) => setChosen({ key: docKey, pane }) }
  return (
    <div
      className="lf-doc"
      data-layout={layout}
      data-tab={activeTab ?? undefined}
      data-detail={detailOpen ? 'open' : undefined}
      data-testid={rest['data-testid']}
    >
      <DocTabs.Provider value={ctx}>{children}</DocTabs.Provider>
    </div>
  )
}

const tabId = (pane: DocPane) => `lf-doc-tab-${pane}`
const panelId = (pane: DocPane) => `lf-doc-panel-${pane}`

export interface DocTabListProps {
  labels: Record<DocPane, string>
  ariaLabel: string
  lineCount?: number
  /** Problem count per pane; a pane with problems shows a danger badge (also when it is the hidden one). */
  problems?: Record<DocPane, number>
  problemLabel: (count: number) => string
}

/** The tab block of a tab layout (a direct grid child of `.lf-doc`, placed after `DocBar`); renders nothing otherwise. */
export function DocTabList({ labels, ariaLabel, lineCount, problems, problemLabel }: DocTabListProps) {
  const { tabsLayout, activeTab, setTab } = useDocTabs()
  const listRef = useRef<HTMLDivElement>(null)
  if (!tabsLayout) return null
  const panes: readonly DocPane[] = ['header', 'lines']
  const move = (to: number) => {
    const pane = panes[to]
    if (!pane) return
    setTab(pane)
    listRef.current?.querySelectorAll<HTMLElement>('[role="tab"]')[to]?.focus()
  }
  const onKeyDown = (event: React.KeyboardEvent, index: number) => {
    const last = panes.length - 1
    let target: number | null = null
    if (event.key === 'ArrowRight') target = index === last ? 0 : index + 1
    else if (event.key === 'ArrowLeft') target = index === 0 ? last : index - 1
    else if (event.key === 'Home') target = 0
    else if (event.key === 'End') target = last
    if (target === null) return
    event.preventDefault()
    move(target)
  }
  const tabbable = Math.max(0, panes.findIndex((p) => p === activeTab))
  return (
    <div className="lf-doc__tablist lf-tabs" role="tablist" aria-label={ariaLabel} ref={listRef} data-testid="document-tabs">
      {panes.map((pane, index) => {
        const n = problems?.[pane] ?? 0
        return (
          <button
            key={pane}
            type="button"
            role="tab"
            id={tabId(pane)}
            className="lf-tab"
            aria-selected={pane === activeTab}
            aria-controls={panelId(pane)}
            tabIndex={index === tabbable ? 0 : -1}
            onClick={() => setTab(pane)}
            onKeyDown={(e) => onKeyDown(e, index)}
            data-testid={`document-tab-${pane}`}
          >
            {labels[pane]}
            {pane === 'lines' && lineCount !== undefined && <span className="lf-count">{lineCount}</span>}
            {n > 0 && (
              <span className="lf-count lf-count--danger" role="img" aria-label={problemLabel(n)} data-testid={`document-tab-${pane}-problems`}>
                <AlertTriangle className="lf-icon" aria-hidden="true" />
                {n}
              </span>
            )}
          </button>
        )
      })}
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
  const { tabsLayout } = useDocTabs()
  const panel = tabsLayout ? { role: 'tabpanel', id: panelId(props.area), 'aria-labelledby': tabId(props.area), tabIndex: 0 } : {}
  return (
    <section className={`lf-card lf-doc__${props.area}`} aria-label={props.title} data-testid={props['data-testid']} {...panel}>
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
