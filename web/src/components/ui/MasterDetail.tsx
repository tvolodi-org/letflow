/** MasterDetail — sticky master on desktop, stacked under 900px (CSS). */
import type { ReactNode } from 'react'

export interface MasterDetailProps {
  master: ReactNode
  detail: ReactNode
}

export function MasterDetail({ master, detail }: MasterDetailProps) {
  return (
    <div className="lf-md" data-testid="master-detail">
      <aside className="lf-md__master lf-card" data-testid="master-detail-master">
        <div className="lf-card__body">{master}</div>
      </aside>
      <section className="lf-card" data-testid="master-detail-detail">
        {detail}
      </section>
    </div>
  )
}
