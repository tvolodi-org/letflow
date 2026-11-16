/** DecisionDialog -- T-2007: the one-field dialog of a decision on a problem report (a short single-answer action,
 *  design-system rule 2a). Presentational: the page owns the text, the checks and the request. */
import { useIntl } from 'react-intl'
import { Dialog } from '@/components/ui/Dialog'
import { Field } from '@/components/ui/Field'
import type { DecisionAction } from '@/api/platformProblemReports'

export interface DecisionDialogProps {
  action: DecisionAction | null
  text: string
  onText: (value: string) => void
  fieldError?: string
  error?: string | null
  busy: boolean
  onConfirm: () => void
  onCancel: () => void
}

export function DecisionDialog({ action, text, onText, fieldError, error, busy, onConfirm, onCancel }: DecisionDialogProps) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id: `problemReports.${id}` })
  // Keep the last action while the dialog closes so the title does not flash empty.
  const shown: DecisionAction = action ?? 'answer'
  return (
    <Dialog
      open={action !== null}
      title={t(`dialog.title.${shown}`)}
      confirmText={t('dialog.confirm')}
      cancelText={t('dialog.cancel')}
      onConfirm={onConfirm}
      onCancel={onCancel}
      isLoading={busy}
      error={error}
      testId="pr-decision-dialog"
    >
      <Field label={t(`field.${shown}`)} hint={t(`hint.${shown}`)} error={fieldError}>
        <textarea rows={6} value={text} data-testid="pr-decision-text" onChange={(e) => onText(e.target.value)} />
      </Field>
    </Dialog>
  )
}
