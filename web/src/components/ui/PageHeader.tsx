/** PageHeader — NOTES.md section 2: eyebrow, title, one-sentence lede, actions (at most one primary). */
import type { ReactNode } from 'react'

export interface PageHeaderProps {
  title: string
  eyebrow?: string
  lede?: string
  actions?: ReactNode
}

export function PageHeader({ title, eyebrow, lede, actions }: PageHeaderProps) {
  return (
    <header className="lf-pagehead" data-testid="page-header">
      <div className="lf-pagehead__text">
        {eyebrow != null && <p className="eyebrow">{eyebrow}</p>}
        <h1 className="lf-pagehead__title">{title}</h1>
        {lede != null && <p className="lf-pagehead__lede">{lede}</p>}
      </div>
      {actions != null && (
        <div className="lf-pagehead__actions" data-testid="page-header-actions">
          {actions}
        </div>
      )}
    </header>
  )
}
