/** RulePill — T-1989. On / Off status of one approval rule: a word and a glyph, never colour alone. */
import { useIntl } from 'react-intl'
import { StatusPill } from '@/components/ui/StatusPill'

export function RulePill({ on }: { on: boolean }) {
  const intl = useIntl()
  return (
    <StatusPill tone={on ? 'success' : 'warning'} glyph={on ? 'dot' : 'triangle'}>
      {intl.formatMessage({ id: on ? 'approvalRules.pill.on' : 'approvalRules.pill.off' })}
    </StatusPill>
  )
}
