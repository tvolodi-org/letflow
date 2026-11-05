/** SignersDialog — GH 3761 / REQ-720 criterion 2. The people who must sign (chair, members, responsibles) as check
 *  boxes, all unchecked; confirming sends the checked ids only. The server decides what is complete. */
import { useState } from 'react'
import { useIntl } from 'react-intl'
import { Checkbox } from '@/components/ui/Checkbox'
import { Dialog } from '@/components/ui/Dialog'
import type { Signer } from './countsModel'

export function SignersDialog(props: {
  title: string
  signers: Signer[]
  nameOf: (id: string) => string
  isLoading: boolean
  error: string | null
  onConfirm: (ids: string[]) => void
  onCancel: () => void
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  const [checked, setChecked] = useState<string[]>([])
  const toggle = (id: string, on: boolean) => setChecked((xs) => (on ? [...xs, id] : xs.filter((x) => x !== id)))
  return (
    <Dialog
      open
      title={props.title}
      subtitle={t('counts.signers.hint')}
      confirmText={t('counts.signers.confirm')}
      cancelText={t('counts.signers.cancel')}
      isLoading={props.isLoading}
      error={props.error}
      onConfirm={() => props.onConfirm(checked)}
      onCancel={props.onCancel}
      testId="signers-dialog"
    >
      <div className="lf-form" data-testid="signers-list">
        {props.signers.map((s) => (
          <Checkbox
            key={s.id}
            label={`${props.nameOf(s.id)} — ${t(`counts.signers.role.${s.role}`)}`}
            checked={checked.includes(s.id)}
            onChange={(on) => toggle(s.id, on)}
            data-testid={`signer-${s.id}`}
          />
        ))}
      </div>
    </Dialog>
  )
}
