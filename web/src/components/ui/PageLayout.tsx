/** PageLayout — design-system primitive (REQ-272, docs/frontend/design-system.md §8)
 *
 *  Page title (h1) + optional actions slot (top-right), content area
 *  constrained by --content-max-width, consistent vertical spacing between
 *  sections.
 */

import React from 'react'

export interface PageLayoutProps {
  title: string
  actions?: React.ReactNode
  children: React.ReactNode
}

export function PageLayout(props: PageLayoutProps): React.ReactElement {
  const { title, actions, children } = props

  return (
    <div data-testid="page-layout" style={{ background: 'var(--surface-page)' }}>
      <div
        data-testid="page-layout-header"
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          flexWrap: 'wrap',
          gap: 'var(--space-3)',
          marginBottom: 'var(--space-6)',
        }}
      >
        <h1 data-testid="page-layout-title" style={{ color: 'var(--text-primary)' }}>
          {title}
        </h1>
        {actions && <div data-testid="page-layout-actions">{actions}</div>}
      </div>
      <div
        data-testid="page-layout-content"
        style={{
          maxWidth: 'var(--content-max-width)',
          margin: '0 auto',
          display: 'flex',
          flexDirection: 'column',
          gap: 'var(--space-6)',
        }}
      >
        {children}
      </div>
    </div>
  )
}
