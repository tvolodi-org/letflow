/** Skeleton — placeholder bar for loading states (NOTES.md §2).
 *
 *  Reduced motion: the shimmer is a CSS animation (`.lf-skel::after`) and the
 *  `prefers-reduced-motion: reduce` block in `components.css` switches every
 *  animation off, so the bar stays a static sunken block.
 *  `width` is the only inline style: it is the prop, not a colour or spacing.
 */

import React from 'react'

export interface SkeletonProps {
  /** Any CSS width; a number is read as px. Default: the full cell. */
  width?: string | number
}

export function Skeleton({ width }: SkeletonProps): React.ReactElement {
  return (
    <span
      className="lf-skel"
      aria-hidden="true"
      data-testid="skeleton"
      style={width === undefined ? undefined : { width }}
    />
  )
}
