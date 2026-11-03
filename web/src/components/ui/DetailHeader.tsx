/** DetailHeader — path (caption), title, status and wrapping actions of the detail pane.
 *  Inside a MasterDetail with `onBack` it also holds the back button (shown under 900px by the CSS). */
import { ArrowLeft } from 'lucide-react'
import type { ReactNode } from 'react'
import { useMasterDetailBack } from './masterDetailBack'
import { useUiMessages } from './uiMessages'

export interface DetailHeaderProps {
  title: string
  path?: string
  status?: ReactNode
  actions?: ReactNode
}

export function DetailHeader({ title, path, status, actions }: DetailHeaderProps) {
  const onBack = useMasterDetailBack()
  const m = useUiMessages()
  return (
    <div className="lf-detail-head" data-testid="detail-header">
      <div className="lf-detail-head__title">
        {onBack != null && (
          <button type="button" className="lf-btn lf-btn--ghost lf-btn--s lf-md__back" onClick={onBack} data-testid="master-detail-back">
            <ArrowLeft className="lf-icon" aria-hidden="true" />
            <span>{m.back}</span>
          </button>
        )}
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
