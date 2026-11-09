/** AssetCardDepreciation — T-1530. A read-only block of the typed or imported depreciation values of a card, labelled
 *  "information only, not calculated" (D-061). Values are shown exactly as stored: no arithmetic, no rounding, no
 *  derived row. A row with no value is hidden; with no value at all the whole block is. */
import { Fragment } from 'react'
import { useIntl } from 'react-intl'
import { formatDate } from '@/i18n/format'
import type { EntityRecord } from '@/types/api'
import { textOf } from './assetsModel'

export function AssetCardDepreciation({ record }: { record: EntityRecord }) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const asOf = textOf(record, 'depreciation_as_of').trim()
  const rows: [string, string, boolean][] = [
    [t('assets.field.depMethod'), textOf(record, 'depreciation_method').trim(), false],
    [t('assets.field.depRate'), textOf(record, 'depreciation_rate').trim(), true],
    [t('assets.field.accumulated'), textOf(record, 'accumulated_depreciation').trim(), true],
    [t('assets.field.bookValue'), textOf(record, 'book_value').trim(), true],
    [t('assets.field.asOf'), asOf === '' ? '' : formatDate(asOf, undefined, intl.locale), true],
  ]
  const shown = rows.filter(([, value]) => value !== '')
  if (shown.length === 0) return null
  return (
    <section data-testid="asset-depreciation" aria-label={t('assets.section.depreciation')}>
      <h3 className="h4">{t('assets.section.depreciation')}</h3>
      <p className="caption lf-faint" data-testid="asset-depreciation-note">
        {t('assets.depreciation.infoOnly')}
      </p>
      <dl className="lf-dl">
        {shown.map(([label, value, mono]) => (
          <Fragment key={label}>
            <dt>{label}</dt>
            <dd className={mono ? 'mono' : undefined}>{value}</dd>
          </Fragment>
        ))}
      </dl>
    </section>
  )
}
