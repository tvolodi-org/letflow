/** HelpPanel — REQ-366 §2.3
 *
 *  The actual content panel, rendered by `HelpTrigger` on click. A slide-in
 *  side panel — the exact visual container is a UI-library-consistency
 *  choice against this app's existing `ConfirmDialog`/`ConfirmPromoteModal`
 *  pattern (fixed-position overlay + `role="dialog"`), not a new component
 *  library (design §2.3's own note: WF-02 Step 2b forbids introducing one).
 *
 *  Render order, per design §2.3:
 *    1. content.title
 *    2. <HelpMarkdown source={content.body} />
 *    3. content.media items, if any (§5) — rendered, not authored
 *    4. content.stale ? <StalenessBadge kind="stale" />
 *                     : <StalenessBadge kind="reviewed" confirmedAt={...} />
 */

import type React from 'react'
import { useEffect, useRef } from 'react'
import type { ResolvedHelpContent } from '@/types/help'
import { isHelpMediaImage } from '@/types/help'
import { useModalFocus } from '@/components/ui/useModalFocus'
import { HelpMarkdown } from './HelpMarkdown'
import { StalenessBadge } from './StalenessBadge'

export interface HelpPanelProps {
  content: ResolvedHelpContent
  onClose: () => void
}

/** `href`/`src` scheme check (design §5.2) — media is a separate structured
 *  field, not markdown text, so it never passes through `HelpMarkdown`'s
 *  `rehype-sanitize` pipeline at all; this is the small, explicit
 *  equivalent check for the one place this component renders `src` itself. */
const SAFE_IMAGE_SCHEMES = ['http:', 'https:']

function isSafeImageSrc(url: string): boolean {
  try {
    const parsed = new URL(url, window.location.origin)
    return SAFE_IMAGE_SCHEMES.includes(parsed.protocol)
  } catch {
    return false
  }
}

export function HelpPanel(props: HelpPanelProps): React.ReactElement {
  const { content, onClose } = props
  const closeRef = useRef<HTMLButtonElement | null>(null)
  const boxRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    closeRef.current?.focus()
  }, [])

  useModalFocus(boxRef, { onClose })

  // §5.1 -- renders nothing (no placeholder, no error) for an unrecognised
  // shape; the common case (media: []) renders nothing at all.
  const imageMedia = content.media.filter(isHelpMediaImage).filter((item) => isSafeImageSrc(item.url))

  return (
    <div
      ref={boxRef}
      tabIndex={-1}
      data-testid="help-panel-overlay"
      role="dialog"
      aria-modal="true"
      aria-labelledby="help-panel-title"
      style={{
        position: 'fixed',
        inset: 0,
        background: 'var(--surface-overlay)',
        zIndex: 'var(--z-dialog)' as unknown as number,
        display: 'flex',
        justifyContent: 'flex-end',
      }}
      onClick={onClose}
    >
      <div
        data-testid="help-panel"
        onClick={(e) => e.stopPropagation()}
        style={{
          background: 'var(--surface-card)',
          width: 'min(420px, 90vw)',
          height: '100%',
          overflowY: 'auto',
          padding: 'var(--space-6)',
          boxShadow: 'var(--shadow-modal-lg)',
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 'var(--space-4)' }}>
          <h2 id="help-panel-title" data-testid="help-panel-title" style={{ margin: 0, color: 'var(--text-primary)' }}>
            {content.title}
          </h2>
          <button
            ref={closeRef}
            type="button"
            data-testid="help-panel-close"
            aria-label="Close help"
            onClick={onClose}
            style={{
              background: 'none',
              border: 'none',
              cursor: 'pointer',
              fontSize: 'var(--text-lg)',
              color: 'var(--text-secondary)',
            }}
          >
            ×
          </button>
        </div>

        <div data-testid="help-panel-body" style={{ color: 'var(--text-primary)', lineHeight: 1.6 }}>
          <HelpMarkdown source={content.body} />
        </div>

        {imageMedia.length > 0 && (
          <div data-testid="help-panel-media" style={{ marginTop: 'var(--space-4)', display: 'flex', flexDirection: 'column', gap: 'var(--space-2)' }}>
            {imageMedia.map((item, index) => (
              // No author-supplied alt text exists in the reserved media
              // shape (design §5, no element shape defined beyond url/type).
              <img key={`${item.url}-${index}`} src={item.url} alt="" style={{ maxWidth: '100%', borderRadius: 'var(--radius-md)' }} />
            ))}
          </div>
        )}

        <div style={{ marginTop: 'var(--space-4)' }}>
          {content.stale ? (
            <StalenessBadge kind="stale" />
          ) : (
            <StalenessBadge kind="reviewed" confirmedAt={content.confirmedAt} />
          )}
        </div>
      </div>
    </div>
  )
}
