/** MasterDetail — sticky master on desktop, stacked under 900px (CSS). */
import type { ReactNode } from 'react'

export interface MasterDetailProps {
  master: ReactNode
  detail: ReactNode
  /** Filter row above the master list (show-retired switch, count): the design's `.lf-md__tools`. */
  tools?: ReactNode
}

export function MasterDetail({ master, detail, tools }: MasterDetailProps) {
  return (
    <div className="lf-md" data-testid="master-detail">
      <aside className="lf-md__master lf-card" data-testid="master-detail-master">
        {tools != null && (
          <div className="lf-md__tools" data-testid="master-detail-tools">
            {tools}
          </div>
        )}
        <div className="lf-card__body">{master}</div>
      </aside>
      <section className="lf-card" data-testid="master-detail-detail">
        {detail}
      </section>
    </div>
  )
}
