/** RefusalList — T-1983. One plain-language item per refusal of a template check (the server sends only the code, the
 *  rule, a place and a closed-list placeholder name, never company text). Unknown codes get a generic hint + the code. */
import { useIntl } from 'react-intl'
import { Banner } from '@/components/ui/Banner'
import type { TemplateRefusal } from '@/api/officialFormTemplates'
import { isKnownRefusalCode, placeParts, refusalMessageId } from './officialFormsModel'

export function RefusalList({ refusals, leadId = 'officialForms.refusal.lead' }: { refusals: TemplateRefusal[]; leadId?: string }) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string>) => intl.formatMessage({ id }, values)
  return (
    <Banner tone="danger" title={t(leadId)}>
      <div role="alert" data-testid="official-forms-refusals">
        <ul>
          {refusals.map((r, i) => {
            const place = placeParts(r.place)
              .map((p) => t(`officialForms.place.${p.key}`, { n: p.value }))
              .join(', ')
            return (
              <li key={i} data-testid="official-forms-refusal">
                {t(refusalMessageId(r))}
                {!isKnownRefusalCode(r.code) && r.code != null && (
                  <>
                    {' '}
                    <span className="mono">{r.code}</span>
                  </>
                )}
                {place !== '' && <> {t('officialForms.refusal.at', { place })}</>}
                {r.name != null && r.name !== '' && (
                  <>
                    {' '}
                    <span className="mono">{r.name}</span>
                  </>
                )}
              </li>
            )
          })}
        </ul>
      </div>
    </Banner>
  )
}
