/** AssetCardOperations — T-1880 / D-135. The "Operations" section of the card panel: one button per card action
 *  (Commission, Change responsible, Hand over, Write off), the same rule as the Actions menu (`cardActionState`). A
 *  disabled button shows its reason as visible text under the row, so touch users see why. Without AssetsPost the section
 *  is not rendered. */
import { useIntl } from 'react-intl'
import { useNavigate } from 'react-router-dom'
import { useAccess } from '@/auth/access/useAccess'
import { Button } from '@/components/ui/Button'
import type { EntityRecord } from '@/types/api'
import { ASSETS_POST } from './assetsPermissions'
import { CARD_ACTIONS, cardActionState, newDocumentHref } from './cardActions'
import { useCardFacts } from './AssetsShell'

export function AssetCardOperations({ card }: { card: EntityRecord }) {
  const { can } = useAccess()
  if (!can(ASSETS_POST)) return null
  return <Operations card={card} />
}

function Operations({ card }: { card: EntityRecord }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const navigate = useNavigate()
  const facts = useCardFacts(card, true)
  const states = CARD_ACTIONS.map((a) => ({ a, state: cardActionState(a.id, facts) }))
  const reasons = states.flatMap(({ a, state }) => (state.allowed ? [] : [{ id: a.id, label: t(a.labelId), text: t(state.reasonId) }]))
  return (
    <section className="lf-form__section" data-testid="asset-operations">
      <h3 className="lf-form__title">{t('assets.cardActions.title')}</h3>
      <div className="lf-btn-row">
        {states.map(({ a, state }) => (
          <Button
            key={a.id}
            variant="secondary"
            size="sm"
            disabled={!state.allowed}
            title={state.allowed ? undefined : t(state.reasonId)}
            data-testid={`card-op-${a.id}`}
            onClick={() => navigate(newDocumentHref(a.kind, [card.record_id]))}
          >
            {t(a.labelId)}
          </Button>
        ))}
      </div>
      {reasons.map((r) => (
        <p className="caption lf-faint" key={r.id} data-testid={`card-op-reason-${r.id}`}>
          {r.label}: {r.text}
        </p>
      ))}
    </section>
  )
}
