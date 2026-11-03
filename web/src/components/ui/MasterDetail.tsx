/** MasterDetail — sticky master on desktop. Under 900px (CSS only) a selected record REPLACES the list: `detailOpen`
 *  sets `data-detail="open"`, and the back button of the DetailHeader (`onBack`) returns to the list. */
import type { ReactNode } from 'react'
import { MasterDetailBackContext } from './masterDetailBack'

export interface MasterDetailProps {
  master: ReactNode
  detail: ReactNode
  /** Filter row above the master list (show-retired switch, count): the design's `.lf-md__tools`. */
  tools?: ReactNode
  /** A record (or a new-record form) is open in the detail panel. Narrow screens show it instead of the list. */
  detailOpen?: boolean
  /** Back button of the detail header (visible under 900px only): the screen clears its selection. */
  onBack?: () => void
}

export function MasterDetail({ master, detail, tools, detailOpen = false, onBack }: MasterDetailProps) {
  return (
    <div className="lf-md" data-testid="master-detail" data-detail={detailOpen ? 'open' : undefined}>
      <aside className="lf-md__master lf-card" data-testid="master-detail-master">
        {tools != null && (
          <div className="lf-md__tools" data-testid="master-detail-tools">
            {tools}
          </div>
        )}
        <div className="lf-card__body">{master}</div>
      </aside>
      <section className="lf-card lf-md__detail" data-testid="master-detail-detail">
        <MasterDetailBackContext.Provider value={onBack ?? null}>{detail}</MasterDetailBackContext.Provider>
      </section>
    </div>
  )
}
