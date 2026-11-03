/** DetailHeader — path (caption), title, status and wrapping actions of the detail pane. */
import type { ReactNode } from 'react'

export interface DetailHeaderProps {
  title: string
  path?: string
  status?: ReactNode
  actions?: ReactNode
}

export function DetailHeader({ title, path, status, actions }: DetailHeaderProps) {
  return (
    <div className="lf-detail-head" data-testid="detail-header">
      <div className="lf-detail-head__title">
        {path != null && <span className="lf-detail-head__path">{path}</span>}
        <h2>{title}</h2>
      </div>
      {(status != null || actions != null) && (
        <div className="lf-btn-row">
          {status}
          {actions}
        </div>
      )}
    </div>
  )
}
