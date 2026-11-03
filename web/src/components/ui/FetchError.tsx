/** FetchError — load error state (NOTES.md §2): a danger Banner with a Retry action.
 *  Strings come from the ui message catalog (en, ru, kk); no inline styles. */
import React from 'react'
import { Banner } from './Banner'
import { Button } from './Button'
import { useUiMessages } from './uiMessages'

interface FetchErrorProps {
  onRetry: () => void
}

export function FetchError({ onRetry }: FetchErrorProps): React.ReactElement {
  const m = useUiMessages()
  return (
    <Banner
      tone="danger"
      action={
        <Button variant="secondary" size="sm" onClick={onRetry}>
          {m.retry}
        </Button>
      }
    >
      {m.loadError}
    </Banner>
  )
}
