/** Registry — the lf-registry shell: the list pane on the left, the details pane on the right (NOTES.md "Layouts of
 *  the registry", rule 12). Viewing, editing and creating a record happen in the details pane, never in a modal.
 *  Under 900 px the selected record replaces the list (`data-detail="open"`, back button in the head). The shell knows
 *  no module words: the list and the details come in as nodes, built from the pieces of this folder. */
import { useState, type KeyboardEvent, type ReactNode, type Ref } from 'react'
import { Tabs, type TabItem } from '../Tabs'
import { DEFAULT_REGISTRY_LAYOUT, REGISTRY_LAYOUTS, type RegistryLayout } from './registryLayouts'

export interface RegistrySectionTab {
  id: string
  label: string
  count?: number
}

export interface RegistryProps {
  layout?: RegistryLayout
  /** The tab shown first in the `tabs` layout (default `overview`). */
  defaultTab?: string
  /** The sections of the details pane as tabs (`tabs` layout only). */
  sectionTabs?: RegistrySectionTab[]
  tabsLabel?: string
  list: ReactNode
  details: ReactNode
  /** A record (or the create form) is open: under 900 px it replaces the list. */
  detailOpen: boolean
  /** Escape closes the open record (rule 2a). */
  onClose?: () => void
  /** Ref of the root `div.lf-reg` (the splitter attaches to it). */
  gridRef?: Ref<HTMLDivElement>
}

export function Registry(props: RegistryProps) {
  const layout = props.layout ?? DEFAULT_REGISTRY_LAYOUT
  const asTabs = REGISTRY_LAYOUTS[layout].sectionsAsTabs
  const [tab, setTab] = useState(props.defaultTab ?? 'overview')
  const items: TabItem[] = props.sectionTabs ?? []

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key !== 'Escape' || !props.detailOpen || !props.onClose) return
    // a popup (calendar) or a dialog handles its own Escape first
    if (e.defaultPrevented) return
    props.onClose()
  }

  return (
    <div
      ref={props.gridRef}
      className="lf-reg"
      data-testid="registry"
      data-layout={layout}
      data-detail={props.detailOpen ? 'open' : 'closed'}
      data-tab={asTabs ? tab : undefined}
      onKeyDown={onKeyDown}
    >
      {props.list}
      <div className="lf-reg__details" data-testid="registry-details">
        {asTabs && items.length > 0 && props.detailOpen && (
          <div className="lf-reg__tablist">
            <Tabs items={items} selected={tab} onChange={setTab} aria-label={props.tabsLabel} />
          </div>
        )}
        {props.details}
      </div>
    </div>
  )
}
