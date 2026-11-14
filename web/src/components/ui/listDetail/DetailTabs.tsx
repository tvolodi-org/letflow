/** DetailTabs — tabs inside the detail pane of a ListDetail screen (T-1954). They sit under the DetailHeader, so the
 *  record's actions stay in the header and never move into a tab. Every panel stays mounted and the inactive ones
 *  are `hidden`: a form that spans two tabs keeps its state, and no query runs again on a tab switch. The ids are
 *  scoped per instance (`idPrefix`, default from useId), so two panes on one page do not clash. */
import { useId, type ReactNode } from 'react'
import { Tabs } from '../Tabs'

export interface DetailTab {
  id: string
  label: string
  count?: number
  panel: ReactNode
}

export interface DetailTabsProps {
  tabs: DetailTab[]
  /** An unknown id falls back to the first tab. */
  selected: string
  onChange: (id: string) => void
  'aria-label': string
  idPrefix?: string
}

export function DetailTabs(props: DetailTabsProps) {
  const generated = useId().replace(/:/g, '')
  const prefix = props.idPrefix ?? `dt${generated}`
  const current = props.tabs.some((x) => x.id === props.selected) ? props.selected : (props.tabs[0]?.id ?? '')
  return (
    <div className="lf-detail-tabs" data-testid="detail-tabs">
      <Tabs
        idPrefix={prefix}
        items={props.tabs.map(({ id, label, count }) => ({ id, label, count }))}
        selected={current}
        onChange={props.onChange}
        aria-label={props['aria-label']}
      />
      {props.tabs.map((x) => (
        <div
          key={x.id}
          role="tabpanel"
          id={`${prefix}-panel-${x.id}`}
          aria-labelledby={`${prefix}-tab-${x.id}`}
          className="lf-detail-tabs__panel"
          data-testid={`detail-tab-panel-${x.id}`}
          hidden={x.id !== current}
        >
          {x.panel}
        </div>
      ))}
    </div>
  )
}
