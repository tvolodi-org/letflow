import { Dialog } from '@/components/ui/Dialog'
import { fillEmail, type PasswordResetMessages } from '@/pages/admin/passwordResetMessages'

type Props = {
  open: boolean
  email: string
  isSubmitting: boolean
  messages: PasswordResetMessages
  onCancel: () => void
  onConfirm: () => void
}

export function PasswordResetDialog({ open, email, isSubmitting, messages, onCancel, onConfirm }: Props) {
  return (
    <Dialog
      open={open}
      title={messages.confirmTitle}
      confirmText={messages.confirm}
      cancelText={messages.cancel}
      isLoading={isSubmitting}
      onConfirm={onConfirm}
      onCancel={onCancel}
      testId="password-reset-dialog"
    >
      <p data-testid="password-reset-dialog-body">{fillEmail(messages.confirmBody, email)}</p>
    </Dialog>
  )
}
