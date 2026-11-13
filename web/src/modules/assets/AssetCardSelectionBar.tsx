/** AssetCardSelectionBar — T-1904 / D-135. The selection bar on the asset card list: shows the count of chosen cards,
 *  four action buttons (commission / change / handover / write off) and a Clear button. An action is allowed only when
 *  it is allowed for every chosen card; the first blocker's reason is shown as visible text. */
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { Button } from '@/components/ui/Button'
import { CARD_ACTIONS, newDocumentHref, selectionActionState, type CardFacts } from './cardActions'
import { MAX_LINES } from './documents/documentForm'

export function AssetCardSelectionBar(props: {
  chosen: { id: string; number: string; facts: CardFacts }[]
  onClear: () => void
}) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const navigate = useNavigate()
  const { chosen, onClear } = props
  const items = chosen.map((c) => ({ number: c.number, facts: c.facts }))
  return (
    <div role="region" aria-label={t('assets.cardActions.select.bar')} data-testid="card-selection-bar" className="lf-btn-row">
      <span>{t('assets.cardActions.select.count', { count: chosen.length })}</span>
      {CARD_ACTIONS.map((action) => {
        const state = selectionActionState(action.id, items)
        const disabled = !state.allowed
        const blockedMsg = disabled
          ? state.number !== ''
            ? t('assets.cardActions.select.blocked', { number: state.number, reason: t(state.reasonId) })
            : t(state.reasonId)
          : undefined
        return (
          <span key={action.id}>
            <Button
              variant="secondary"
              size="sm"
              disabled={disabled}
              title={blockedMsg}
              data-testid={`card-bulk-${action.id}`}
              onClick={() => navigate(newDocumentHref(action.kind, chosen.map((c) => c.id)))}
            >
              {t(action.labelId)}
            </Button>
            {disabled && blockedMsg && (
              <span className="sr-only" data-testid={`card-bulk-reason-${action.id}`}>{blockedMsg}</span>
            )}
          </span>
        )
      })}
      <Button variant="ghost" size="sm" onClick={onClear} data-testid="card-bulk-clear">
        {t('assets.cardActions.select.clear')}
      </Button>
      {chosen.length >= MAX_LINES && (
        <span role="status" data-testid="card-bulk-cap">
          {t('assets.cardActions.select.cap', { max: MAX_LINES })}
        </span>
      )}
    </div>
  )
}
