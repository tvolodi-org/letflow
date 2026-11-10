import { useMemo, useRef, useState } from 'react'
import { useModalFocus } from '@/components/ui/useModalFocus'
import { P, useAccess } from '@/auth/access'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { groupsApi, rolesApi, usersApi } from '@/api/identity'
import { roleLabel } from '@/auth/access'
import { useDebounce } from '@/hooks/useDebounce'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { useFeedbackMessages } from '@/components/ui/feedbackMessages'
import { saveErrorText } from '@/utils/saveError'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { Group, GroupMember, Role, User } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { deferClickState } from '@/utils/deferClickState'
import StorekeeperAssetsGrantCard from './StorekeeperAssetsGrantCard'
import { fillGroups, groupsMessages } from './groupsMessages'

type GroupRow = Group & {
  group_id?: string
  // is_system and member_count are not emitted by group_map/1 (ISS-0811) -- do not rely on them
}

function groupId(group: GroupRow): string {
  return group.group_id ?? group.id ?? ''
}

function groupTitle(group: GroupRow): string {
  return group.display_name?.trim() || group.name || groupId(group) || 'Unnamed group'
}

/** The group-bound platform role that makes its members tenant administrators. */
const TENANT_ADMIN_ROLE = 'TENANT_ADMIN'

function rolesOfGroup(roles: Role[], id: string): Role[] {
  return roles.filter((r) => r.kind === 'platform_role' && r.group_id != null && r.group_id === id)
}

function userId(user: User): string {
  return user.id ?? user.user_id ?? ''
}

function errorCode(err: unknown): string | null {
  const e = err as { code?: unknown; body?: { code?: unknown; error?: { code?: unknown } } } | null
  const c = e?.code ?? e?.body?.code ?? e?.body?.error?.code
  return typeof c === 'string' ? c : null
}

function isLastAdminRefusal(err: unknown): boolean {
  const status = (err as { status?: unknown } | null)?.status
  const code = errorCode(err)
  return status === 409 && (code === 'last_tenant_wide_admin' || code === 'last_interactive_tenant_wide_admin')
}

export default function GroupsPage() {
  const canManage = useAccess().can(P.UsersGroupsRolesManage)
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ name: '', display_name: '', description: '' })
  const [activeGroup, setActiveGroup] = useState<GroupRow | null>(null)
  const [pendingDelete, setPendingDelete] = useState<GroupRow | null>(null)
  const [pendingRemove, setPendingRemove] = useState<{ groupId: string; member: GroupMember } | null>(null)
  const membersRef = useRef<HTMLDivElement | null>(null)
  const deleteRef = useRef<HTMLDivElement | null>(null)
  useModalFocus(membersRef, { open: activeGroup != null && pendingDelete == null && pendingRemove == null, onClose: () => setActiveGroup(null) })
  useModalFocus(deleteRef, { open: pendingDelete != null, onClose: () => setPendingDelete(null) })
  const uiLocale = useUiLocale()
  const gm = groupsMessages[uiLocale]
  const feedback = useFeedbackMessages()
  const [search, setSearch] = useState('')
  const searchApplied = useDebounce(search.trim(), 300)
  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [adding, setAdding] = useState(false)
  const [addResult, setAddResult] = useState<{ ok: number; failed: string[] } | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const removeRef = useRef<HTMLDivElement | null>(null)
  useModalFocus(removeRef, {
    open: pendingRemove != null,
    onClose: () => setPendingRemove(null),
  })

  const { data, isLoading, isError, error, refetch } = useQuery({
    queryKey: tenantKeys.admin.groups(),
    queryFn: () => groupsApi.list(),
  })

  const groups = useMemo(() => (data?.items ?? []) as GroupRow[], [data?.items])
  const activeGroupId = groupId(activeGroup ?? ({} as GroupRow))
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const { data: membersPage } = useQuery({
    queryKey: tenantKeys.admin.groupMembers(activeGroupId),
    queryFn: () => groupsApi.members(activeGroupId),
    enabled: Boolean(activeGroup),
  })

  const members = useMemo(() => membersPage?.items ?? [], [membersPage?.items])

  // ISS-0816/ISS-0828: @default_page_size 50 applies to members. When next_cursor is set
  // the group has >50 members and the current-members list is incomplete.
  const membersListTruncated = Boolean(membersPage?.next_cursor)

  // T-1610: the user picker is a search result (50 per page), not the first 200 users.
  const { data: users } = useQuery({
    queryKey: tenantKeys.admin.users({ search: searchApplied || undefined, page_size: 50 }),
    queryFn: () => usersApi.list({ search: searchApplied || undefined, page_size: 50 }),
    enabled: Boolean(activeGroup),
  })
  const moreUsersMatch = Boolean(users?.next_cursor)

  // T-1610: the roles list tells which group gives which role (Roles column, last-administrator warning).
  const { data: rolesData } = useQuery({
    queryKey: tenantKeys.admin.roles(),
    queryFn: () => rolesApi.list(),
  })
  const roles = useMemo(() => (rolesData?.items ?? []) as Role[], [rolesData?.items])

  const createGroup = useMutation({
    mutationFn: (body: typeof form) => groupsApi.create(body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() })
      setCreating(false)
      setForm({ name: '', display_name: '', description: '' })
    },
  })

  const removeMember = useMutation({
    mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) => groupsApi.removeMembers(id, userId),
    onSuccess: () => {
      setActionError(null)
      if (activeGroup) {
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groupMembers(groupId(activeGroup)) })
      }
    },
    // T-1610: a 409 used to be silent.
    onError: (err: unknown) => setActionError(isLastAdminRefusal(err) ? gm.removeRefused : saveErrorText(err, feedback)),
  })

  const deleteGroup = useMutation({
    mutationFn: (id: string) => groupsApi.delete(id),
    onSuccess: () => {
      setActionError(null)
      qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() })
    },
    onError: (err: unknown) => setActionError(isLastAdminRefusal(err) ? gm.deleteRefused : saveErrorText(err, feedback)),
  })

  // The TENANT_ADMIN group: the group bound to the TENANT_ADMIN platform role. A UI hint only; the server 409
  // (last_tenant_wide_admin) stays the authority, token-owner administrators being invisible here.
  const adminGroupId = useMemo(
    () => roles.find((r) => r.name === TENANT_ADMIN_ROLE && r.kind === 'platform_role')?.group_id ?? null,
    [roles],
  )
  const activeMembers = members.filter((m) => m.status === 'active')
  const isLastAdminHint = (id: string, member: GroupMember): boolean =>
    adminGroupId != null &&
    id === adminGroupId &&
    !membersListTruncated &&
    member.status === 'active' &&
    activeMembers.length === 1

  // ISS-0899 follow-up (freeze confirmed empirically -- see this fix's
  // handoff/spec header comment): GroupsPage exhibits the identical
  // synchronous-setState-inside-native-click-dispatch freeze first found in
  // ISS-0662 (EntityCrudPage/DataTable), ISS-0737 (DefinitionListPage) and
  // ISS-0739 (InstanceBoardPage) -- deferring every click-triggered setState
  // by one macrotask (deferClickState, see that helper's moduledoc) clears
  // it the same way it did there.
  const openCreateGroup = () => {
    deferClickState(() => setCreating(true))
  }
  const cancelCreateGroup = () => {
    deferClickState(() => setCreating(false))
  }
  const submitCreateGroup = () => {
    deferClickState(() => createGroup.mutate(form))
  }
  const openManageMembers = (group: GroupRow) => {
    deferClickState(() => setActiveGroup(group))
  }
  const closeManageMembers = () => {
    deferClickState(() => {
      setActiveGroup(null)
      setSelectedIds([])
      setSearch('')
      setAddResult(null)
      setActionError(null)
    })
  }
  // T-1610 bulk add: one existing idempotent POST per user, sequentially; one failure must not stop the rest.
  const submitAddSelected = (id: string) => {
    const ids = [...selectedIds]
    if (ids.length === 0 || adding) return
    deferClickState(() => {
      void (async () => {
        setAdding(true)
        const failed: string[] = []
        let ok = 0
        for (const uid of ids) {
          try {
            await groupsApi.addMember(id, uid)
            ok += 1
          } catch {
            failed.push(uid)
          }
        }
        setAdding(false)
        setAddResult({ ok, failed })
        setSelectedIds(failed)
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groupMembers(id) })
      })()
    })
  }
  const submitRemoveMember = (id: string, member: GroupMember) => {
    if (isLastAdminHint(id, member)) {
      deferClickState(() => setPendingRemove({ groupId: id, member }))
      return
    }
    deferClickState(() => removeMember.mutate({ groupId: id, userId: member.id }))
  }
  const confirmRemoveAnyway = () => {
    const target = pendingRemove
    deferClickState(() => {
      if (target) removeMember.mutate({ groupId: target.groupId, userId: target.member.id })
      setPendingRemove(null)
    })
  }
  const cancelRemove = () => {
    deferClickState(() => setPendingRemove(null))
  }
  const openDeleteGroup = (group: GroupRow) => {
    deferClickState(() => setPendingDelete(group))
  }
  const cancelDeleteGroup = () => {
    deferClickState(() => setPendingDelete(null))
  }
  const confirmDeleteGroup = (id: string) => {
    deferClickState(() => {
      deleteGroup.mutate(id)
      setPendingDelete(null)
    })
  }
  const toggleSelected = (uid: string) =>
    setSelectedIds((prev) => (prev.includes(uid) ? prev.filter((x) => x !== uid) : [...prev, uid]))

  const availableUsers = useMemo(() => {
    const list = users?.items ?? []
    const memberIds = new Set(members.map((user) => user.id))
    return list.filter((user) => {
      const id = userId(user)
      return id !== '' && !memberIds.has(id)
    })
  }, [members, users?.items])
  const allShownSelected = availableUsers.length > 0 && availableUsers.every((u) => selectedIds.includes(userId(u)))
  const userNames = (ids: string[]) =>
    ids.map((uid) => (users?.items ?? []).find((u) => userId(u) === uid)?.display_name ?? uid).join(', ')

  const columns: DataTableColumn<GroupRow>[] = [
    { id: 'name', header: 'Name', accessor: (g) => <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-sm)' }}>{g.name}</span> },
    { id: 'display_name', header: 'Display name', accessor: groupTitle },
    // ISS-0811: Members column removed — group_map/1 does not emit member_count
    {
      id: 'roles',
      header: gm.rolesHeader,
      accessor: (g) => {
        const given = rolesOfGroup(roles, groupId(g))
        return given.length === 0 ? gm.noRoles : given.map((r) => roleLabel(r.name, uiLocale)).join(', ')
      },
    },
    {
      id: 'description',
      header: 'Description',
      accessor: (g) => <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>{g.description ?? '—'}</span>,
    },
    {
      id: 'actions',
      header: 'Actions',
      accessor: (g) => {
        return (
          <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
            {canManage && (
              <Button variant="primary" size="sm" onClick={() => openManageMembers(g)}>
                Manage members
              </Button>
            )}
            {/* ISS-0811: is_system and member_count never sent by group_map/1;
                Delete shown for all groups — backend enforces deletion constraints */}
            {canManage && (
              <Button variant="danger" size="sm" data-testid={`delete-group-${g.id}`} onClick={() => openDeleteGroup(g)}>
                Delete
              </Button>
            )}
          </div>
        )
      },
    },
  ]

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Groups</h2>
        {canManage && (
          <span style={{ marginLeft: 'auto' }}>
            <Button variant="primary" size="sm" onClick={openCreateGroup}>
              + New Group
            </Button>
          </span>
        )}
      </div>

      {actionError && !activeGroup && (
        <p role="alert" data-testid="group-action-error" style={{ margin: '0 0 1rem' }}>{actionError}</p>
      )}

      {canManage && <StorekeeperAssetsGrantCard />}

      {creating && (
        <div style={{ background: 'var(--surface-page)', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create group</h3>
          {(['name', 'display_name', 'description'] as const).map((f) => (
            <div key={f} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{f.replace('_', ' ')}</label>
              <input
                value={form[f]}
                onChange={(e) => setForm((p) => ({ ...p, [f]: e.target.value }))}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)', boxSizing: 'border-box' }}
              />
            </div>
          ))}
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <Button variant="primary" size="sm" onClick={submitCreateGroup}>Save</Button>
            <Button variant="secondary" size="sm" onClick={cancelCreateGroup}>Cancel</Button>
          </div>
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(error) : undefined
        }
        columns={[{ widthPercent: 20 }, { widthPercent: 25 }, { widthPercent: 15 }, { widthPercent: 25 }, { widthPercent: 15 }]}
      >
      <DataTable
        columns={columns}
        data={groups}
        emptyMessage="No groups found."
      />

      {activeGroup && (
        <div ref={membersRef} tabIndex={-1} role="dialog" aria-modal="true" aria-label="Manage group members" style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 60 }}>
          <div style={{ background: 'var(--surface-card)', width: 'min(720px, 100%)', borderRadius: '12px', padding: '1.25rem', maxHeight: '85vh', overflow: 'auto' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: '1rem', alignItems: 'start', marginBottom: '1rem' }}>
              <div>
                <h3 style={{ margin: 0 }}>Manage members</h3>
                <p style={{ margin: '.25rem 0 0', color: 'var(--text-secondary)' }}>{groupTitle(activeGroup)}</p>
                {rolesOfGroup(roles, activeGroupId).length > 0 && (
                  <p data-testid="group-gives-roles" style={{ margin: '.25rem 0 0', fontSize: 'var(--text-sm)' }}>
                    {fillGroups(gm.givesRole, {
                      roles: rolesOfGroup(roles, activeGroupId).map((r) => roleLabel(r.name, uiLocale)).join(', '),
                    })}
                  </p>
                )}
              </div>
              <Button variant="ghost" size="sm" onClick={closeManageMembers}>Close</Button>
            </div>

            <div style={{ display: 'grid', gap: '.5rem', marginBottom: '1rem' }}>
              <label style={{ display: 'grid', gap: '.25rem' }}>
                <span style={{ fontSize: '.875rem', fontWeight: 600 }}>{gm.searchLabel}</span>
                <input
                  type="search"
                  value={search}
                  placeholder={gm.searchPlaceholder}
                  onChange={(event) => setSearch(event.target.value)}
                  style={{ padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)' }}
                />
              </label>
              {availableUsers.length === 0 ? (
                <p data-testid="user-search-empty" style={{ margin: 0, color: 'var(--text-secondary)' }}>
                  {(users?.items ?? []).length === 0 ? gm.noMatch : gm.allAlreadyMembers}
                </p>
              ) : (
                <div role="group" aria-label={gm.searchLabel} style={{ display: 'grid', gap: '.25rem', maxHeight: '14rem', overflow: 'auto' }}>
                  <label style={{ display: 'flex', gap: '.5rem', alignItems: 'center', fontWeight: 600 }}>
                    <input
                      type="checkbox"
                      checked={allShownSelected}
                      onChange={() =>
                        setSelectedIds(allShownSelected ? [] : availableUsers.map((u) => userId(u)))
                      }
                    />
                    {gm.selectAllShown}
                  </label>
                  {availableUsers.map((user) => {
                    const id = userId(user)
                    return (
                      <label key={id} style={{ display: 'flex', gap: '.5rem', alignItems: 'center' }}>
                        <input type="checkbox" checked={selectedIds.includes(id)} onChange={() => toggleSelected(id)} />
                        <span>
                          {user.display_name}{' '}
                          <span style={{ color: 'var(--text-secondary)', fontSize: 'var(--text-sm)' }}>{user.email}</span>
                          {user.status === 'inactive' && (
                            <span style={{ marginLeft: '.4rem', fontSize: 'var(--text-sm)', color: 'var(--text-secondary)' }}>
                              ({gm.inactiveTag})
                            </span>
                          )}
                        </span>
                      </label>
                    )
                  })}
                </div>
              )}
              {moreUsersMatch && (
                <p role="note" data-testid="more-users-match-note" style={{ margin: 0, fontSize: 'var(--text-sm)', color: 'var(--color-warning-dark)' }}>
                  {gm.moreMatch}
                </p>
              )}
              <div>
                <Button
                  variant="primary"
                  size="md"
                  loading={adding}
                  disabled={selectedIds.length === 0}
                  onClick={() => submitAddSelected(groupId(activeGroup))}
                >
                  {fillGroups(gm.addSelected, { n: selectedIds.length })}
                </Button>
              </div>
              {addResult && (
                <div role="status" data-testid="add-summary">
                  <p style={{ margin: 0 }}>{fillGroups(gm.addSummary, { ok: addResult.ok, failed: addResult.failed.length })}</p>
                  {addResult.failed.length > 0 && (
                    <p style={{ margin: '.25rem 0 0', color: 'var(--color-warning-dark)', fontSize: 'var(--text-sm)' }}>
                      {fillGroups(gm.addFailedNames, { names: userNames(addResult.failed) })}
                    </p>
                  )}
                </div>
              )}
            </div>

            <div>
              <h4 style={{ margin: '0 0 .75rem' }}>Current members</h4>
              {membersListTruncated && (
                <p role="note" data-testid="members-list-truncated-warning" style={{ margin: '0 0 .5rem', fontSize: 'var(--text-sm)', color: 'var(--color-warning-dark)' }}>
                  This group has more than 50 members. The list below shows only the first 50 — some members may not appear.
                </p>
              )}
              {actionError && (
                <p role="alert" data-testid="group-action-error-dialog" style={{ margin: '0 0 .5rem' }}>{actionError}</p>
              )}
              {members.length === 0 ? (
                <p style={{ margin: 0, color: 'var(--text-secondary)' }}>No members in this group.</p>
              ) : (
                <div style={{ display: 'grid', gap: '.5rem' }}>
                  {members.map((user) => {
                    const id = user.id
                    return (
                      <div key={id} style={{ display: 'flex', justifyContent: 'space-between', gap: '1rem', alignItems: 'center', border: '1px solid var(--border-default)', borderRadius: '8px', padding: '.7rem .85rem' }}>
                        <div>
                          <div style={{ fontWeight: 600 }}>{user.display_name}</div>
                          <div style={{ color: 'var(--text-secondary)', fontSize: '.875rem' }}>{user.email}</div>
                        </div>
                        <Button variant="danger" size="sm" onClick={() => submitRemoveMember(groupId(activeGroup), user)}>
                          Remove
                        </Button>
                      </div>
                    )
                  })}
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      </QueryStateBoundary>

      {pendingDelete && (
        <div ref={deleteRef} tabIndex={-1} role="dialog" aria-modal="true" aria-label="Delete group" style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 70 }}>
          <div style={{ background: 'var(--surface-card)', width: 'min(520px, 100%)', borderRadius: '12px', padding: '1.25rem' }}>
            <h3 style={{ marginTop: 0 }}>Delete group?</h3>
            <p style={{ color: 'var(--text-secondary)' }}>Delete {groupTitle(pendingDelete)} only if it is empty. This action cannot be undone.</p>
            <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end' }}>
              <Button variant="secondary" size="md" onClick={cancelDeleteGroup}>Cancel</Button>
              <Button
                variant="danger"
                size="md"
                onClick={() => confirmDeleteGroup(groupId(pendingDelete))}
              >
                Delete group
              </Button>
            </div>
          </div>
        </div>
      )}

      {pendingRemove != null && (
        <div ref={removeRef} tabIndex={-1} role="dialog" aria-modal="true" aria-label={gm.lastAdminTitle} style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 80 }}>
          <div style={{ background: 'var(--surface-card)', width: 'min(520px, 100%)', borderRadius: '12px', padding: '1.25rem' }}>
            <h3 style={{ marginTop: 0 }}>{gm.lastAdminTitle}</h3>
            <p data-testid="last-admin-warning" style={{ color: 'var(--text-secondary)' }}>{gm.lastAdminText}</p>
            <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end' }}>
              <Button variant="secondary" size="md" onClick={cancelRemove}>{gm.cancel}</Button>
              <Button
                variant="danger"
                size="md"
                onClick={confirmRemoveAnyway}
              >
                {gm.removeAnyway}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
