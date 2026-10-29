/** SkipLink -- REQ-608: the "skip to main content" anchor, visually hidden until focused.
 *
 *  Activation focuses the #main-content element directly (no hash navigation), so the
 *  router location and URL are untouched. Colours are CSS custom properties only. */
import { useState } from 'react'
import type { MouseEvent } from 'react'

export const MAIN_CONTENT_ID = 'main-content'

const hiddenStyle = {
  position: 'absolute',
  width: '1px',
  height: '1px',
  overflow: 'hidden',
  clip: 'rect(0, 0, 0, 0)',
  whiteSpace: 'nowrap',
} as const

const visibleStyle = {
  position: 'fixed',
  top: 0,
  left: 0,
  zIndex: 1000,
  width: 'auto',
  padding: '0.5rem 1rem',
  background: 'var(--surface-sidebar)',
  color: 'var(--text-primary)',
} as const

export function SkipLink({ label }: { label: string }) {
  const [focused, setFocused] = useState(false)

  const onClick = (event: MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault()
    document.getElementById(MAIN_CONTENT_ID)?.focus()
  }

  return (
    <a
      href={`#${MAIN_CONTENT_ID}`}
      style={focused ? visibleStyle : hiddenStyle}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onClick={onClick}
    >
      {label}
    </a>
  )
}
