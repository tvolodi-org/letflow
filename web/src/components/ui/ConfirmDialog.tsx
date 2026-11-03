/** ConfirmDialog — generic confirm dialog (RND-UI-06 §2.6 OQ-1), built on Dialog.
 *
 *  Props body/confirmText/cancelText/isLoading are unchanged; `error` is new (write error
 *  shown inside the dialog). Used by ConflictResolver, delete confirmations, etc.
 */

import React from 'react'
import { Dialog } from './Dialog'

export interface ConfirmDialogProps {
  open: boolean
  title: string
  body: string
  confirmText?: string
  cancelText?: string
  confirmVariant?: 'primary' | 'danger'
  onConfirm: () => void
  onCancel: () => void
  isLoading?: boolean
  error?: string | null
}

export function ConfirmDialog(props: ConfirmDialogProps): React.ReactElement | null {
  const { body, ...rest } = props
  return (
    <Dialog {...rest} testId="confirm-dialog">
      <p>{body}</p>
    </Dialog>
  )
}
