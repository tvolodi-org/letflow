/** ListDetail — T-1886. The single list + detail shell: a list pane on the left, one record on the right.
 *  Used for master data tables, work lists and table + side panel screens. The divider is collapsible; the
 *  list size is remembered per user and screen. Under 900 px of work area the record replaces the list,
 *  with a back button. Escape closes the record unless `escapeCloses === false` or already handled.
 *  Design verdict: docs/design-system/master-detail-verdict.md sections 4.1–4.5. */
import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { Tabs, type TabItem } from '../Tabs'
import { SplitWrap, useSplit } from '../layout/Splitter'
import { useLayoutMessages } from '../layout/layoutMessages'
import { isWideHost } from '../layout/isWideHost'
import { EmptyState } from '../EmptyState'
import { Button } from '../Button'
import { useUiMessages } from '../uiMessages'
import { DEFAULT_REGISTRY_LAYOUT, REGISTRY_LAYOUTS, type RegistryLayout } from '../registry/registryLayouts'
import { ListDetailBackContext } from './listDetailBack'

export { type RegistryLayout }

export interface RegistrySectionTab {
  id: string
  label: string
  count?: number
}

export interface ListDetailProps {
  /** Layout screen id, required: the divider and its size are remembered per user under screens.<screen>. */
  screen: string
  /** 'table' (default) or 'tree' (adds lf-reg--tree, list width from --master-width). */
  kind?: 'table' | 'tree'
  /** Registered registry layout: 'split' (default) or 'tabs'. */
  layout?: RegistryLayout
  /** Title row + count + create action of the list pane (lf-reg__listhead). */
  listHeader?: ReactNode
  /** Filters, search, show-retired (lf-reg__tools). */
  tools?: ReactNode
  /** DataTable (compact) or TreeView; lives in lf-reg__body. */
  list?: ReactNode
  /** A list that draws its whole pane itself (`RegistryList`: head, tools, body, foot in one `section.lf-reg__list`).
   *  Replaces `listHeader`, `tools`, `list` and `listFooter`. */
  listPane?: ReactNode
  /** Pager / truncation notice (lf-reg__foot). */
  listFooter?: ReactNode
  /** The record: DetailHeader + sections, or the create / edit form. */
  detail: ReactNode
  /** Detail pane when nothing is selected (wide screens); default: generic empty state. */
  empty?: ReactNode
  /** A record or a create form is open: under 900 px of work area it replaces the list. */
  detailOpen: boolean
  /** Back button (narrow) and Escape (any width): the screen clears its selection. */
  onClose: () => void
  /** Escape closes the record unless this is false (a dialog or an unsaved edit owns the key). */
  escapeCloses?: boolean
  /** Default list width in percent of the work area while nothing is stored (balances use 60). */
  listDefault?: number
  /** Smallest list width in px (default 260; balances 320). */
  listMin?: number
  /** Accessible name of the list pane and the divider, from the screen's own catalog (en/ru/kk). */
  listLabel: string
  /** 'tabs' layout only. */
  sectionTabs?: RegistrySectionTab[]
  defaultTab?: string
  /** T-1946: id of the first item of the list (null while loading or when the list is empty). The first time the
   *  screen shows a list with no record open, on a wide host, the component asks the screen to select it through
   *  `onDefaultSelect`. A record the URL or the screen already opened wins; a narrow host (single pane) keeps the
   *  list first; after a close or a delete the component never re-selects. */
  defaultSelectId?: string | null
  onDefaultSelect?: (id: string) => void
}

/** Preset split options used by ListDetail (LIST_SPLIT). Exported so tests can reference the id. */
export const LIST_SPLIT_ID = 'list'

export function ListDetail({
  screen,
  kind,
  layout = DEFAULT_REGISTRY_LAYOUT,
  listHeader,
  tools,
  list,
  listFooter,
  listPane,
  detail,
  empty,
  detailOpen,
  onClose,
  escapeCloses = true,
  listDefault,
  listMin = 260,
  listLabel,
  sectionTabs,
  defaultTab,
  defaultSelectId,
  onDefaultSelect,
}: ListDetailProps) {
  const asTabs = REGISTRY_LAYOUTS[layout].sectionsAsTabs
  const [tab, setTab] = useState(defaultTab ?? 'overview')
  const items: TabItem[] = sectionTabs ?? []

  const gridRef = useRef<HTMLDivElement>(null)
  const layerRef = useRef<HTMLDivElement>(null)
  const lm = useLayoutMessages()
  const ui = useUiMessages()

  // LIST_SPLIT preset: id list, sized before, unit pct, collapsible list pane, clampStored on.
  useSplit(gridRef, layerRef, {
    id: LIST_SPLIT_ID,
    screen,
    unit: 'pct',
    vars: ['--lf-pane-1'],
    sized: 'before',
    min: [listMin],
    flexMin: 360,
    collapsible: [0],
    clampStored: true,
    labels: [listLabel],
    ...(listDefault !== undefined ? { defaults: [listDefault] } : {}),
    panes: () => {
      const a = gridRef.current?.querySelector<HTMLElement>(':scope > .lf-reg__list') ?? null
      const b = gridRef.current?.querySelector<HTMLElement>(':scope > .lf-reg__details') ?? null
      return a && b ? [a, b] : []
    },
    enabled: () => isWideHost(gridRef.current),
  })

  // Default selection: decided once per mount. Any open record (URL, create form, a click) ends the chance.
  const defaultDone = useRef(false)
  useEffect(() => {
    if (defaultDone.current) return
    if (detailOpen) {
      defaultDone.current = true
      return
    }
    if (!defaultSelectId || !onDefaultSelect) return
    defaultDone.current = true
    if (!isWideHost(gridRef.current)) return
    onDefaultSelect(defaultSelectId)
  }, [detailOpen, defaultSelectId, onDefaultSelect])

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key !== 'Escape' || !detailOpen) return
    if (!escapeCloses) return
    // a popup (calendar) or a dialog handles its own Escape first
    if (e.defaultPrevented) return
    onClose()
  }

  const defaultEmpty = <EmptyState title={lm.selectRecord} data-testid="list-detail-empty" />

  return (
    <SplitWrap layerRef={layerRef}>
      <div
        ref={gridRef}
        className={kind === 'tree' ? 'lf-reg lf-reg--tree' : 'lf-reg'}
        data-testid="registry"
        data-layout={layout}
        data-detail={detailOpen ? 'open' : 'closed'}
        data-tab={asTabs ? tab : undefined}
        onKeyDown={onKeyDown}
      >
        {listPane ?? (
          <section className="lf-card lf-reg__list" aria-label={listLabel}>
            {listHeader != null && <div className="lf-reg__listhead">{listHeader}</div>}
            {tools != null && <div className="lf-reg__tools">{tools}</div>}
            <div className="lf-reg__body">{list}</div>
            {listFooter != null && <div className="lf-reg__foot">{listFooter}</div>}
          </section>
        )}
        <div className="lf-reg__details" data-testid="registry-details">
          {detailOpen && (
            <div className="lf-reg__backrow">
              <Button
                variant="ghost"
                size="sm"
                className="lf-reg__back"
                onClick={onClose}
                data-testid="list-detail-back"
              >
                {ui.back}
              </Button>
            </div>
          )}
          {asTabs && items.length > 0 && detailOpen && (
            <div className="lf-reg__tablist">
              <Tabs items={items} selected={tab} onChange={setTab} aria-label={listLabel} />
            </div>
          )}
          <ListDetailBackContext.Provider value={detailOpen ? onClose : null}>
            {detailOpen ? detail : (empty ?? defaultEmpty)}
          </ListDetailBackContext.Provider>
        </div>
      </div>
    </SplitWrap>
  )
}
