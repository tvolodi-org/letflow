/** ReasonDialog — T-1983. One short single-answer dialog for activate, retire and rollback: a required reason picked from
 *  a fixed list of codes (the server accepts only a code, not free text), the effect in one sentence, errors inside. */
import { useIntl } from 'react-intl'
import type { OfficialFormTemplateMeta, TemplateAction, TemplateRefusal } from '@/api/officialFormTemplates'
import { Dialog } from '@/components/ui/Dialog'
import { Select } from '@/components/ui/Select'
import { RefusalList } from './RefusalList'
import { REASON_CODES } from './officialFormsModel'

interface Props {
  action: TemplateAction
  row: OfficialFormTemplateMeta
  /** Every row of the same form, to name the version that gets retired. */
  rows: OfficialFormTemplateMeta[]
  formLabel: string
  reason: string
  onReason: (code: string) => void
  loading: boolean
  /** Message id of the failed attempt, or null. */
  errorKey: string | null
  refusals: TemplateRefusal[] | null
  onConfirm: () => void
  onCancel: () => void
}

export function ReasonDialog({ action, row, rows, formLabel, reason, onReason, loading, errorKey, refusals, onConfirm, onCancel }: Props) {
  const intl = useIntl()
  const t = (id: string, values?: Record<string, string | number>) => intl.formatMessage({ id }, values)
  const lang = t(`officialForms.locale.${row.locale}`)
  const current = rows.find((r) => r.status === 'active' && r.locale === row.locale && r.id !== row.id)
  let effect: string
  if (action === 'activate') {
    effect = current
      ? t('officialForms.effect.activateReplace', { n: row.version_no, lang, old: current.version_no })
      : t('officialForms.effect.activate', { n: row.version_no, lang })
  } else if (action === 'retire') {
    effect = t('officialForms.effect.retire', { lang })
  } else {
    effect = t('officialForms.effect.rollback', { n: row.version_no, lang })
  }
  const confirmId = { activate: 'confirmActivate', retire: 'confirmRetire', rollback: 'confirmRollback' }[action]
  return (
    <Dialog
      open
      testId="official-forms-dialog"
      title={t(`officialForms.dialog.${action}`)}
      subtitle={t('officialForms.dialog.subtitle', { form: formLabel, lang, n: row.version_no })}
      confirmText={t(`officialForms.dialog.${confirmId}`)}
      cancelText={t('officialForms.dialog.cancel')}
      confirmVariant={action === 'retire' ? 'danger' : 'primary'}
      confirmDisabled={reason === ''}
      isLoading={loading}
      error={refusals == null && errorKey != null ? t(errorKey) : null}
      onConfirm={onConfirm}
      onCancel={onCancel}
    >
      <p data-testid="official-forms-effect">{effect}</p>
      <Select
        label={t('officialForms.dialog.reason')}
        placeholder={t('officialForms.dialog.reasonPlaceholder')}
        value={reason}
        onChange={onReason}
        options={REASON_CODES[action].map((code) => ({ value: code, label: t(`officialForms.reason.${code}`) }))}
        data-testid="official-forms-reason"
      />
      {refusals != null && <RefusalList refusals={refusals} leadId="officialForms.refusal.leadStale" />}
    </Dialog>
  )
}
