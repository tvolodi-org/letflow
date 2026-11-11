import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { P, useAccess, AccessPending, roleLabel, roleDescription } from '@/auth/access'
import { DeactivateUserDialog } from '@/components/admin/users/DeactivateUserDialog'
import { PasswordResetDialog } from '@/components/admin/users/PasswordResetDialog'
import { CoreHelpLink } from '@/pages/help/CoreHelpLink'
import { useAdminGroups, useAdminRoles, useAdminUser, useDeactivateAdminUser, useSendPasswordResetInstructions, useUpdateAdminUser } from '@/hooks/useAdminUsers'
import type { User } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Banner } from '@/components/ui/Banner'
import { Button } from '@/components/ui/Button'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { useFeedbackMessages } from '@/components/ui/feedbackMessages'
import { saveErrorText } from '@/utils/saveError'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { usersMessages } from './usersMessages'
import { conflictText, fillEmail, hintText, passwordResetBlock, passwordResetMessages } from './passwordResetMessages'

function userId(user: User): string {
  return user.user_id ?? user.id
}

function userStatus(user: User): 'ACTIVE' | 'INACTIVE' {
  if (user.status === 'active') return 'ACTIVE'
  if (user.status === 'inactive') return 'INACTIVE'
  return user.is_active ? 'ACTIVE' : 'INACTIVE'
}

export default function UserDetailPage() {
  const { userId: routeUserId = '' } = useParams()
  const navigate = useNavigate()
  const access = useAccess()
  const feedback = useFeedbackMessages()
  const uiLocale = useUiLocale()
  const pm = passwordResetMessages[uiLocale]
  const um = usersMessages[uiLocale]
  const isAllowed = access.can(P.UsersGroupsRolesManage)

  const userQuery = useAdminUser(routeUserId)
  const rolesQuery = useAdminRoles()
  const groupsQuery = useAdminGroups()
  const updateUser = useUpdateAdminUser(routeUserId)
  const deactivateUser = useDeactivateAdminUser(routeUserId)
  const sendReset = useSendPasswordResetInstructions(routeUserId)

  const [displayName, setDisplayName] = useState('')
  const [email, setEmail] = useState('')
  const [status, setStatus] = useState<'ACTIVE' | 'INACTIVE'>('ACTIVE')
  const [selectedRoleIds, setSelectedRoleIds] = useState<string[]>([])
  const [selectedGroupIds, setSelectedGroupIds] = useState<string[]>([])
  const [showDeactivate, setShowDeactivate] = useState(false)
  const [submitMessage, setSubmitMessage] = useState<string | null>(null)
  const [showReset, setShowReset] = useState(false)
  const [resetMessage, setResetMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null)
  const formRef = useRef<HTMLFormElement>(null)

  useEffect(() => {
    if (!userQuery.data) return
    const user = userQuery.data
    setDisplayName(user.display_name)
    setEmail(user.email)
    setStatus(userStatus(user))
    setSelectedRoleIds(user.role_ids ?? [])
    setSelectedGroupIds(user.group_ids ?? [])
  }, [userQuery.data])

  const pageUserId = useMemo(() => {
    if (!userQuery.data) return routeUserId
    return userId(userQuery.data) || routeUserId
  }, [routeUserId, userQuery.data])

  // Decided on the loaded record, not on unsaved form edits, so the button never offers what the route would refuse.
  const resetBlock = userQuery.data ? passwordResetBlock(userQuery.data) : null
  const storedEmail = userQuery.data?.email ?? ''

  if (!access.isReady) return <AccessPending access={access} />

  if (!isAllowed) {
    return (
      <div style={{ padding: '1.5rem' }}>
        <h2>User details</h2>
        <p>You do not have permission to manage users.</p>
      </div>
    )
  }

  return (
    <div style={{ padding: '1.5rem', maxWidth: 900 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 12 }}>
        <Button variant="ghost" size="sm" onClick={() => navigate('/admin/users')}>Back</Button>
        <h2 style={{ margin: 0 }}>User details</h2>
      </div>

      <QueryStateBoundary
        state={(userQuery.isLoading ? 'loading' : userQuery.isError ? classifyError(userQuery.error) : 'success') as RendererState}
        onRetry={() => { void userQuery.refetch() }}
        columns={[{ widthPercent: 50 }, { widthPercent: 50 }]}
      >
      {userQuery.data && (
        <form
          ref={formRef}
          data-testid="admin-user-detail-form"
          onSubmit={(event) => {
            event.preventDefault()
            setSubmitMessage(null)
            updateUser.mutate(
              {
                display_name: displayName.trim(),
                email: email.trim(),
                // Backend accepts only lowercase "active"/"inactive" (ISS-0814)
                status: status.toLowerCase() as 'active' | 'inactive',
                is_active: status === 'ACTIVE',
                role_ids: selectedRoleIds,
                group_ids: selectedGroupIds,
              },
              {
                onSuccess: () => setSubmitMessage(um.saved),
                onError: (error) => setSubmitMessage(saveErrorText(error, feedback)),
              },
            )
          }}
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Username</span>
              <input value={userQuery.data.username ?? ''} disabled readOnly data-testid="admin-user-username" />
            </label>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Status</span>
              <select value={status} onChange={(event) => setStatus(event.target.value as 'ACTIVE' | 'INACTIVE')} data-testid="admin-user-status">
                <option value="ACTIVE">ACTIVE</option>
                <option value="INACTIVE">INACTIVE</option>
              </select>
            </label>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Display name</span>
              <input value={displayName} onChange={(event) => setDisplayName(event.target.value)} data-testid="admin-user-display-name" />
            </label>
            <label>
              <span style={{ display: 'block', fontWeight: 600, marginBottom: 4 }}>Email</span>
              <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} data-testid="admin-user-email" />
            </label>
          </div>

          <div style={{ marginTop: 16 }}>
            <h3 style={{ marginBottom: 8 }}>Role assignments</h3>
            <div style={{ border: '1px solid var(--border-default)', borderRadius: 6, padding: 10 }}>
              {(rolesQuery.data?.items ?? []).map((role) => {
                const checked = selectedRoleIds.includes(role.id)
                return (
                  <label key={role.id} style={{ display: 'block', marginBottom: 6 }}>
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(event) => {
                        setSelectedRoleIds((prev) => {
                          if (event.target.checked) return [...prev, role.id]
                          return prev.filter((id) => id !== role.id)
                        })
                      }}
                    />
                    {' '}{roleLabel(role.name)}
                    {roleDescription(role.name) && (
                      <span style={{ display: 'block', fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>
                        {roleDescription(role.name)}
                      </span>
                    )}
                  </label>
                )
              })}
            </div>
          </div>

          <div style={{ marginTop: 16 }}>
            <h3 style={{ marginBottom: 8 }}>Group memberships</h3>
            <div style={{ border: '1px solid var(--border-default)', borderRadius: 6, padding: 10 }}>
              {(groupsQuery.data?.items ?? []).map((group) => {
                const gid = group.group_id ?? group.id
                const checked = selectedGroupIds.includes(gid)
                return (
                  <label key={gid} style={{ display: 'block', marginBottom: 6 }}>
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={(event) => {
                        setSelectedGroupIds((prev) => {
                          if (event.target.checked) return [...prev, gid]
                          return prev.filter((id) => id !== gid)
                        })
                      }}
                    />
                    {' '}{group.display_name || group.name}
                  </label>
                )
              })}
            </div>
          </div>

          <div style={{ marginTop: 'var(--space-4)', display: 'grid', gap: 'var(--space-2)' }}>
            {resetBlock === null ? (
              <span data-testid="admin-user-send-reset">
                <Button
                  variant="secondary"
                  size="md"
                  type="button"
                  disabled={sendReset.isPending}
                  onClick={() => { setResetMessage(null); setShowReset(true) }}
                >
                  {pm.button}
                </Button>
              </span>
            ) : (
              <div data-testid="admin-user-reset-hint"><Banner tone="info">{hintText(resetBlock, pm)}</Banner></div>
            )}
            <span data-testid="admin-user-reset-help"><CoreHelpLink topic="passwordReset" /></span>
            {/* Always rendered: a live region that exists before its text arrives is announced reliably. */}
            <div aria-live="polite" data-testid="admin-user-reset-live">
              {resetMessage && (
                <div data-testid="admin-user-reset-message">
                  <Banner tone={resetMessage.tone}>{resetMessage.text}</Banner>
                </div>
              )}
            </div>
          </div>

          {submitMessage && <p role="status" data-testid="admin-user-submit-message">{submitMessage}</p>}

          <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
            <span data-testid="admin-user-save">
              <Button
                variant="primary"
                size="md"
                loading={updateUser.isPending}
                onClick={() => formRef.current?.requestSubmit()}
              >
                {updateUser.isPending ? 'Saving...' : 'Save changes'}
              </Button>
            </span>
            {status === 'ACTIVE' && (
              <span data-testid="admin-user-deactivate">
                <Button variant="secondary" size="md" onClick={() => setShowDeactivate(true)}>
                  Deactivate
                </Button>
              </span>
            )}
          </div>
        </form>
      )}
      </QueryStateBoundary>

      <PasswordResetDialog
        open={showReset}
        email={storedEmail}
        isSubmitting={sendReset.isPending}
        messages={pm}
        onCancel={() => setShowReset(false)}
        onConfirm={() => {
          sendReset.mutate(undefined, {
            onSuccess: () => {
              setShowReset(false)
              setResetMessage({ tone: 'success', text: fillEmail(pm.sent, storedEmail) })
            },
            onError: (error) => {
              setShowReset(false)
              const status = (error as { status?: unknown })?.status
              const detail = (error as { details?: { detail?: unknown } })?.details?.detail
              setResetMessage({ tone: 'danger', text: status === 409 ? conflictText(detail, pm) ?? saveErrorText(error, feedback) : saveErrorText(error, feedback) })
            },
          })
        }}
      />

      <DeactivateUserDialog
        open={showDeactivate}
        displayName={displayName || pageUserId}
        isSubmitting={deactivateUser.isPending}
        onCancel={() => setShowDeactivate(false)}
        onConfirm={() => {
          deactivateUser.mutate(undefined, {
            onSuccess: () => {
              setShowDeactivate(false)
              setStatus('INACTIVE')
              setSubmitMessage(um.deactivated)
            },
            onError: (error) => {
              setSubmitMessage(saveErrorText(error, feedback))
            },
          })
        }}
      />
    </div>
  )
}
