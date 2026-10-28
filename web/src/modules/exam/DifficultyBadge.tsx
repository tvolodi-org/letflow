/** DifficultyBadge — GH 3423 / REQ-612
 *
 *  The difficulty of a question as a small badge: one distinct style per value (easy green, medium
 *  amber, hard red, from the design-system tokens), the localized word as text and
 *  `data-testid="difficulty-badge-<value>"`. An unknown value renders as plain text.
 */

import { useIntl } from 'react-intl'
import { DIFFICULTIES, type Difficulty } from './questionEditorModel'

const STYLES: Record<Difficulty, { background: string; color: string }> = {
  easy: { background: 'var(--color-success-light)', color: 'var(--color-success-dark)' },
  medium: { background: 'var(--color-warning-light)', color: 'var(--color-warning-dark)' },
  hard: { background: 'var(--color-error-light)', color: 'var(--color-error-dark)' },
}

export function DifficultyBadge({ value }: { value: unknown }) {
  const intl = useIntl()
  const known = DIFFICULTIES.find((d) => d === value)
  if (!known) return <span>{typeof value === 'string' ? value : ''}</span>
  return (
    <span
      data-testid={`difficulty-badge-${known}`}
      className={`difficulty-badge difficulty-badge-${known}`}
      style={{
        ...STYLES[known],
        display: 'inline-block',
        padding: '0 var(--space-2)',
        borderRadius: 'var(--radius-md)',
        fontSize: 'var(--text-sm)',
      }}
    >
      {intl.formatMessage({ id: `exam.question.difficulty.${known}` })}
    </span>
  )
}
