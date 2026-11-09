/** Harness fixtures of the dialogs that use the shared focus hook (task T-1586). Invented data only. */
import { DeactivateUserDialog } from '@/components/admin/users/DeactivateUserDialog'
import { ConflictResolver } from '@/components/ui/ConflictResolver'
import type { HarnessScreen } from '../types'

const noop = () => undefined

export const a11yDialogScreens: HarnessScreen[] = [
  {
    name: 'a11y-deactivate-dialog',
    routes: [],
    render: () => <DeactivateUserDialog open displayName="Aigerim Sarsenova" isSubmitting={false} onCancel={noop} onConfirm={noop} />,
  },
  {
    name: 'a11y-conflict-resolver',
    routes: [],
    render: () => (
      <ConflictResolver
        serverPayload={{ name: 'Warehouse A', capacity: 120 }}
        localDraft={{ name: 'Warehouse A1', capacity: 150 }}
        conflictVersion="v7"
        onRefetch={noop}
        onSaveMerged={noop}
        onDiscardConfirmed={noop}
      />
    ),
  },
]
