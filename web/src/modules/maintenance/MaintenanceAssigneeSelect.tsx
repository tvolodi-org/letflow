/** MaintenanceAssigneeSelect — GH 4801 / REQ-899. The picker of the person who does a work order: the active users
 *  of the tenant (GET /identity/users, the active ones only, one page of at most 200). A user the server reports
 *  as inactive is dropped here as well. When the list cannot be read the picker says so and the caller still
 *  saves without an assignee. Pure presentation: the server checks the chosen user again (assignee_not_found). */
import { useIntl } from 'react-intl'
import { useAdminUsers } from '@/hooks/useAdminUsers'
import { Select } from '@/components/ui/Select'
import type { User } from '@/types/api'

export const ASSIGNEE_PAGE_SIZE = 200

const FILTERS = { search: '', status: 'active', page_size: ASSIGNEE_PAGE_SIZE } as const

/** The name a person shows under: the display name, else the user name. */
export const userLabel = (u: Pick<User, 'display_name' | 'username'>) =>
  u.display_name !== '' ? u.display_name : u.username

/** The active users the picker lists. */
export function useAssignees() {
  const query = useAdminUsers(FILTERS)
  const users = (query.data?.items ?? []).filter((u) => u.status === 'active')
  return { users, isError: query.isError, isPending: query.isPending }
}

export function MaintenanceAssigneeSelect(props: {
  value: string
  onChange: (userId: string) => void
  users: User[]
  isError: boolean
  error?: string
}) {
  const intl = useIntl()
  const t = (id: string) => intl.formatMessage({ id })
  return (
    <>
      <Select
        name="assignee_user_id"
        label={t('maintenance.orders.assigneeLabel')}
        width="l"
        value={props.value}
        options={props.users.map((u) => ({ value: u.id, label: userLabel(u) }))}
        placeholder={t('maintenance.orders.assigneePlaceholder')}
        error={props.error}
        onChange={props.onChange}
      />
      {props.isError && (
        <p className="lf-error" data-testid="assignee-load-error">
          {t('maintenance.orders.usersLoadError')}
        </p>
      )}
    </>
  )
}
