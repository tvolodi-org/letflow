/** EmptyState — text and (optional) action for a list with nothing in it
 *  (NOTES.md §2). Works alone or inside a table wrapper (`.lf-table-wrap
 *  .lf-empty` squares the corners in CSS).
 */

import React from 'react'
import { Inbox } from 'lucide-react'

export interface EmptyStateProps {
  /** Icon element; default is a neutral inbox. Give it `className="lf-icon lf-empty__icon"`. */
  icon?: React.ReactNode
  title: string
  text?: React.ReactNode
  /** Usually a Button. */
  action?: React.ReactNode
  'data-testid'?: string
}

export function EmptyState(props: EmptyStateProps): React.ReactElement {
  const { icon, title, text, action } = props
  return (
    <div className="lf-empty" data-testid={props['data-testid'] ?? 'empty-state'}>
      {icon ?? <Inbox className="lf-icon lf-empty__icon" aria-hidden="true" />}
      <p className="lf-empty__title">{title}</p>
      {text !== undefined && text !== null && <p className="lf-empty__text">{text}</p>}
      {action}
    </div>
  )
}
