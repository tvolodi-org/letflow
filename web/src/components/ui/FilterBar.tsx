/** FilterBar — design-system component (NOTES.md §2, docs/frontend/design-system.md §7.7)
 *
 *  Layout only: it holds no filter *values*. Each control inside it is the
 *  composing page's own. Active filters are shown as removable chips
 *  (`activeChips` + `onRemoveChip`); the clear link shows only when a filter is
 *  active. `activeCount` is the older count-only form, kept for callers that
 *  have no chip labels.
 */

import React from 'react'
import { X } from 'lucide-react'
import { Button } from './Button'

export interface FilterChip {
  id: string
  label: string
}

export interface FilterBarProps {
  children: React.ReactNode
  onClear?: () => void
  activeCount?: number
  activeChips?: FilterChip[]
  onRemoveChip?: (id: string) => void
  labels?: { clear: string; remove: string }
}

const DEFAULT_LABELS = { clear: 'Clear filters', remove: 'Remove filter' }

export function FilterBar(props: FilterBarProps): React.ReactElement {
  const { children, onClear, activeChips, onRemoveChip, activeCount } = props
  const labels = props.labels ?? DEFAULT_LABELS

  const count = activeChips ? activeChips.length : (activeCount ?? 0)
  const showClear = !!onClear && count > 0
  const showEnd = count > 0

  return (
    <div className="lf-toolbar" data-testid="filter-bar">
      {children}

      {showEnd && (
        <div className="lf-toolbar__end">
          {activeChips ? (
            activeChips.map((chip) => (
              <span key={chip.id} className="lf-chip" data-testid="filter-bar-chip">
                {chip.label}
                <button
                  type="button"
                  aria-label={`${labels.remove}: ${chip.label}`}
                  onClick={() => onRemoveChip?.(chip.id)}
                >
                  <X className="lf-icon" aria-hidden="true" />
                </button>
              </span>
            ))
          ) : (
            <span className="lf-count" data-testid="filter-bar-count">
              {count}
            </span>
          )}
          {showClear && (
            <Button variant="ghost" size="sm" onClick={onClear} data-testid="filter-bar-clear">
              {labels.clear}
            </Button>
          )}
        </div>
      )}
    </div>
  )
}
