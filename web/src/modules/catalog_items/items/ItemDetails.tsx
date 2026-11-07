/** ItemDetails — T-1402. The details pane of the Items screen: head (code, title, status), Overview, Related (stock
 *  by location, from the balances read) and History (last stock movements). References show "code - title" through
 *  the reference-label hook, never an id. Item create / edit / retire has no server route yet (see ItemsPage):
 *  the head carries the view-only line instead of buttons. */
import { useId } from 'react'
import { useIntl } from 'react-intl'
import { Link } from 'react-router-dom'
import { useAccess } from '@/auth/access'
import {
  RegistryBlank, RegistryFields, RegistryHead, RegistryHistory, RegistryNote, RegistrySection,
  type RegistryFieldItem,
} from '@/components/ui/registry'
import { StatusPill } from '@/components/ui/StatusPill'
import { formatDateTimeInZone } from '@/i18n/format'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useReferenceLabels } from '@/lib/references'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import { classifyError } from '@/utils/classifyError'
import { useItemBalances, useItemMovements } from '../CatalogItemsShell'
import { STOCK_READ_ATOM } from '../catalogItemsPermissions'
import type { ItemMovementRow } from '../catalogItemsStock.api'
import { causeKey, type ItemRow } from './itemsModel'

const TIME_ZONE = 'Asia/Almaty'

export function ItemDetails(props: { item: ItemRow; onBack: () => void }) {
  const { item } = props
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id: `catalog_items.items.${id}` }, values)
  const access = useAccess()
  const canStock = access.can(STOCK_READ_ATOM)
  const uid = useId()
  const docTypes = REFERENCE_MESSAGES[useUiLocale()].docType

  const balances = useItemBalances(item.id, canStock)
  const movements = useItemMovements(item.id, canStock)

  const balRows = balances.data?.rows ?? []
  const label = useReferenceLabels([
    {
      catalog_uom: [item.uomId, ...balRows.map((r) => r.unit_ref)].filter(Boolean),
      location_node: balRows.map((r) => r.location),
      org_unit: balRows.map((r) => r.org_unit),
      catalog_lot: balRows.map((r) => r.lot).filter((l): l is string => !!l),
    },
  ])

  const fields: RegistryFieldItem[] = [
    { key: 'code', label: t('field.code'), value: item.code, mono: true, empty: item.code === '' },
    { key: 'title', label: t('field.title'), value: item.name, empty: item.name === '' },
    { key: 'unit', label: t('field.unit'), value: label('catalog_uom', item.uomId), empty: item.uomId === '' },
    { key: 'kind', label: t('field.kind'), value: item.kind === 'material' || item.kind === 'service' ? t(`kind.${item.kind}`) : item.kind, empty: item.kind === '' },
    { key: 'tracking', label: t('field.tracking'), value: t(`tracking.${item.tracking}`) },
    { key: 'status', label: t('field.status'), value: t(item.active ? 'status.active' : 'status.retired') },
  ]
  if (item.externalRef !== '') fields.push({ key: 'external', label: t('field.externalRef'), value: item.externalRef, mono: true, full: true })

  function forbidden(e: unknown) {
    return classifyError(e) === 'permission-denied'
  }

  function related() {
    if (!canStock || (balances.isError && forbidden(balances.error))) return <RegistryNote testId="registry-related-noperm">{t('related.noPermission')}</RegistryNote>
    if (balances.isPending) return <RegistryNote testId="registry-related-loading">{t('related.loading')}</RegistryNote>
    if (balances.isError) return <RegistryNote testId="registry-related-error">{t('related.error')}</RegistryNote>
    if (balRows.length === 0) return <RegistryNote testId="registry-related-empty">{t('related.empty')}</RegistryNote>
    return (
      <>
        <div className="lf-reg__body lf-table-wrap">
        <table className="lf-table lf-table--compact lf-table--rel" data-testid="registry-related">
          <thead>
            <tr>
              <th scope="col">{t('rel.location')}</th>
              <th scope="col">{t('rel.orgUnit')}</th>
              <th scope="col">{t('rel.lot')}</th>
              <th scope="col" className="is-num">{t('rel.quantity')}</th>
            </tr>
          </thead>
          <tbody>
            {balRows.map((r, i) => (
              <tr key={`${r.location}|${r.org_unit}|${r.lot ?? ''}|${r.unit_ref}|${i}`}>
                <td>{label('location_node', r.location)}</td>
                <td>{label('org_unit', r.org_unit)}</td>
                <td>{r.lot ? label('catalog_lot', r.lot) : ''}</td>
                <td className="is-num mono">
                  {r.quantity} {label('catalog_uom', r.unit_ref)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
        {balances.data?.next_cursor && <RegistryNote testId="registry-related-more">{t('related.more')}</RegistryNote>}
      </>
    )
  }

  /** The cause once, the document type only when it differs from the cause, then the document number. */
  function historyText(m: ItemMovementRow) {
    const cause = t(`cause.${causeKey(m.cause)}`)
    const type = m.document_type ? (docTypes[m.document_type] ?? m.document_type) : null
    const parts = [type && type !== cause ? type : null, m.document_number || null].filter(Boolean)
    return (
      <>
        {cause}
        {parts.length > 0 ? <span className="lf-reg__who"> · {parts.join(' · ')}</span> : null}
      </>
    )
  }

  function history() {
    if (!canStock || (movements.isError && forbidden(movements.error))) return <RegistryNote testId="registry-history-noperm">{t('history.noPermission')}</RegistryNote>
    if (movements.isPending) return <RegistryNote testId="registry-history-loading">{t('history.loading')}</RegistryNote>
    if (movements.isError) return <RegistryNote testId="registry-history-error">{t('history.error')}</RegistryNote>
    const rows = movements.data.rows
    if (rows.length === 0) return <RegistryNote testId="registry-history-empty">{t('history.empty')}</RegistryNote>
    return (
      <RegistryHistory
        items={rows.map((m) => ({
          id: m.entry_id,
          iso: m.event_time ?? undefined,
          when: formatDateTimeInZone(m.event_time, { timeZone: TIME_ZONE, locale: intl.locale }),
          text: (
            <>
              {historyText(m)}
            </>
          ),
        }))}
      />
    )
  }

  return (
    <>
      <RegistryHead
        backLabel={t('back')}
        onBack={props.onBack}
        code={item.code}
        title={item.name}
        status={
          <StatusPill tone={item.active ? 'success' : 'neutral'} glyph={item.active ? 'dot' : 'ring'}>
            {t(item.active ? 'status.active' : 'status.retired')}
          </StatusPill>
        }
        reason={
          <>
            {t('viewOnly')}{' '}
            <Link className="lf-link" to="/admin/import" data-testid="registry-import-link">
              {t('importLink')}
            </Link>
          </>
        }
      />
      <RegistrySection pane="overview" id={`${uid}-ov`} title={t('sec.overview')}>
        <RegistryFields fields={fields} />
      </RegistrySection>
      <RegistrySection pane="related" id={`${uid}-rel`} title={t('sec.related')} count={canStock && balances.data ? balRows.length : undefined}>
        {related()}
      </RegistrySection>
      <RegistrySection pane="history" id={`${uid}-hist`} title={t('sec.history')} count={canStock && movements.data ? movements.data.rows.length : undefined}>
        {history()}
      </RegistrySection>
    </>
  )
}

export function ItemNotFound() {
  const intl = useIntl()
  return (
    <RegistryBlank
      title={intl.formatMessage({ id: 'catalog_items.items.notFound.title' })}
      text={intl.formatMessage({ id: 'catalog_items.items.notFound.text' })}
    />
  )
}

export function ItemBlank() {
  const intl = useIntl()
  return (
    <RegistryBlank
      title={intl.formatMessage({ id: 'catalog_items.items.blank.title' })}
      text={intl.formatMessage({ id: 'catalog_items.items.blank.text' })}
    />
  )
}
