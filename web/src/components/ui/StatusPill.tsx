/** StatusPill — design-system component (NOTES.md §2, README "Status").
 *
 *  A status is always a word and a glyph shape, never colour alone. The word
 *  is the translated `children`; a per-domain map (tone + glyph per status)
 *  lives next to the module that owns the status (see StatusBadge for the
 *  legacy per-domain maps). Classes come from `components.css`.
 */

import React from 'react'

export type StatusTone = 'success' | 'info' | 'warning' | 'danger' | 'neutral' | 'current'
export type StatusGlyph = 'dot' | 'ring' | 'half' | 'triangle' | 'dash'

export interface StatusPillProps {
  tone: StatusTone
  glyph?: StatusGlyph
  children: React.ReactNode
  'data-testid'?: string
  /** Extra data attributes for callers that need to target a pill in tests. */
  dataAttributes?: Record<`data-${string}`, string>
}

export function glyphClass(glyph: StatusGlyph): string {
  return glyph === 'dot' ? 'lf-glyph' : `lf-glyph lf-glyph--${glyph}`
}

export function StatusPill(props: StatusPillProps): React.ReactElement {
  const { tone, glyph = 'dot', children, dataAttributes } = props
  return (
    <span
      className={`lf-pill lf-pill--${tone}`}
      data-testid={props['data-testid'] ?? 'status-pill'}
      data-tone={tone}
      data-glyph={glyph}
      {...dataAttributes}
    >
      <span className={glyphClass(glyph)} aria-hidden="true" data-testid="status-pill-glyph" />
      {children}
    </span>
  )
}
