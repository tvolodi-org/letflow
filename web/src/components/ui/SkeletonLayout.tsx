/** SkeletonLayout — loading state (NOTES.md §2): rows of `Skeleton` bars.
 *  Layout comes from the `lf-form` / `lf-skeleton-row` classes; the only inline style is the
 *  bar width inside `Skeleton` (it is the prop). */
import React from 'react'
import { Skeleton } from './Skeleton'
import { useUiMessages } from './uiMessages'

export interface SkeletonColumn {
  widthPercent: number
}

interface SkeletonLayoutProps {
  columns: SkeletonColumn[]
  rowCount?: number
}

export function SkeletonLayout({ columns, rowCount = 5 }: SkeletonLayoutProps): React.ReactElement {
  const m = useUiMessages()
  return (
    <div className="lf-form" aria-busy="true" aria-label={m.loadingContent}>
      {Array.from({ length: rowCount }).map((_, rowIdx) => (
        <div key={rowIdx} className="lf-skeleton-row">
          {columns.map((col, colIdx) => (
            <Skeleton key={colIdx} width={`${col.widthPercent}%`} />
          ))}
        </div>
      ))}
    </div>
  )
}
