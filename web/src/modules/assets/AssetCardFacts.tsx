/** AssetCardFacts — T-1333 / C13. The read-only facts of a retired asset card. Decimals are shown as stored
 *  (strings, mono); dates through the same format as DateField; empty values as a dash. */
import { Fragment } from 'react'
import { useIntl } from 'react-intl'
import { formatDate } from '@/i18n/format'
import type { EntityRecord } from '@/types/api'
import { textOf } from './assetsModel'

export function AssetCardFacts({ record }: { record: EntityRecord }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const dash = t('assets.common.dash')
  const date = (key: string) => formatDate(textOf(record, key), undefined, intl.locale)
  const kind = textOf(record, 'kind')
  const system = textOf(record, 'external_ref_system')
  const extId = textOf(record, 'external_ref_id')
  const rows: [string, string, boolean][] = [
    [t('assets.field.number'), textOf(record, 'inventory_number'), true],
    [t('assets.field.kind'), kind === '' ? '' : t(`assets.kind.${kind}`), false],
    [t('assets.field.acquisitionDate'), date('acquisition_date'), true],
    [t('assets.field.currency'), textOf(record, 'currency'), true],
    ...(kind === 'intangible' ? ([[t('assets.field.validUntil'), date('valid_until'), true]] as [string, string, boolean][]) : []),
    [t('assets.field.cost'), textOf(record, 'acquisition_cost'), true],
    ...(system !== '' || extId !== ''
      ? ([[t('assets.field.externalRef'), [system, extId].filter((x) => x !== '').join(' / '), true]] as [string, string, boolean][])
      : []),
  ]
  return (
    <dl className="lf-dl">
      {rows.map(([label, value, mono]) => (
        <Fragment key={label}>
          <dt>{label}</dt>
          <dd className={mono ? 'mono' : undefined}>{value === '' ? dash : value}</dd>
        </Fragment>
      ))}
    </dl>
  )
}
