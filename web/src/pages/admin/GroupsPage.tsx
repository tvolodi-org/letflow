import { useMemo, useState } from 'react'
import { P, useAccess } from '@/auth/access'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { groupsApi, usersApi } from '@/api/identity'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { Group, User } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { deferClickState } from '@/utils/deferClickState'

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

function formatUser(user: User): string {
  return `${user.display_name} <${user.email}>`
}

export default function GroupsPage() {
  const canManage = useAccess().can(P.UsersGroupsRolesManage)
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ name: '', display_name: '', description: '' })
  const [activeGroup, setActiveGroup] = useState<GroupRow | null>(null)
  const [pendingDelete, setPendingDelete] = useState<GroupRow | null>(null)
  const [selectedUserId, setSelectedUserId] = useState('')

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

  const { data: users } = useQuery({
    queryKey: tenantKeys.admin.users({ page_size: 200 }),
    queryFn: () => usersApi.list({ page_size: 200 }),
    enabled: Boolean(activeGroup),
  })

  // ISS-0823: 200 is the server's max page_size. When next_cursor is set the
  // tenant has >200 users and the dropdown below is incomplete. We cannot
  // silently drop users, so we show a visible warning in that case.
  const userListTruncated = Boolean(users?.next_cursor)

  const createGroup = useMutation({
    mutationFn: (body: typeof form) => groupsApi.create(body),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() })
      setCreating(false)
      setForm({ name: '', display_name: '', description: '' })
    },
  })

  const addMember = useMutation({
    mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) => groupsApi.addMember(id, userId),
    onSuccess: () => {
      if (activeGroup) {
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groupMembers(groupId(activeGroup)) })
      }
      setSelectedUserId('')
    },
  })

  const removeMember = useMutation({
    mutationFn: ({ groupId: id, userId }: { groupId: string; userId: string }) => groupsApi.removeMembers(id, userId),
    onSuccess: () => {
      if (activeGroup) {
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() })
        qc.invalidateQueries({ queryKey: tenantKeys.admin.groupMembers(groupId(activeGroup)) })
      }
    },
  })

  const deleteGroup = useMutation({
    mutationFn: (id: string) => groupsApi.delete(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: tenantKeys.admin.groups() }),
  })

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
      setSelectedUserId('')
    })
  }
  const submitAddMember = (id: string, userId: string) => {
    deferClickState(() => addMember.mutate({ groupId: id, userId }))
  }
  const submitRemoveMember = (id: string, userId: string) => {
    deferClickState(() => removeMember.mutate({ groupId: id, userId }))
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

  const availableUsers = useMemo(() => {
    const list = users?.items ?? []
    const memberIds = new Set(members.map((user) => user.id))
    return list.filter((user) => {
      const id = user.id ?? user.user_id ?? ''
      return id !== '' && !memberIds.has(id)
    })
  }, [members, users?.items])

  const columns: DataTableColumn<GroupRow>[] = [
    { id: 'name', header: 'Name', accessor: (g) => <span style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--text-sm)' }}>{g.name}</span> },
    { id: 'display_name', header: 'Display name', accessor: groupTitle },
    // ISS-0811: Members column removed — group_map/1 does not emit member_count
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
        columns={[{ widthPercent: 25 }, { widthPercent: 30 }, { widthPercent: 10 }, { widthPercent: 25 }, { widthPercent: 10 }]}
      >
      <DataTable
        columns={columns}
        data={groups}
        emptyMessage="No groups found."
      />

      {activeGroup && (
        <div role="dialog" aria-modal="true" aria-label="Manage group members" style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 30 }}>
          <div style={{ background: 'var(--surface-card)', width: 'min(720px, 100%)', borderRadius: '12px', padding: '1.25rem', maxHeight: '85vh', overflow: 'auto' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: '1rem', alignItems: 'start', marginBottom: '1rem' }}>
              <div>
                <h3 style={{ margin: 0 }}>Manage members</h3>
                <p style={{ margin: '.25rem 0 0', color: 'var(--text-secondary)' }}>{groupTitle(activeGroup)}</p>
              </div>
              <Button variant="ghost" size="sm" onClick={closeManageMembers}>Close</Button>
            </div>

            <div style={{ display: 'flex', gap: '.5rem', marginBottom: '1rem', alignItems: 'end', flexWrap: 'wrap' }}>
              <label style={{ display: 'grid', gap: '.25rem', minWidth: '18rem', flex: '1 1 18rem' }}>
                <span style={{ fontSize: '.875rem', fontWeight: 600 }}>Add member</span>
                <select value={selectedUserId} onChange={(event) => setSelectedUserId(event.target.value)} style={{ padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)' }}>
                  <option value="">Select a user</option>
                  {availableUsers.map((user) => {
                    const id = user.id ?? user.user_id ?? ''
                    return <option key={id} value={id}>{formatUser(user)}</option>
                  })}
                </select>
                {userListTruncated && (
                  <p role="note" data-testid="user-list-truncated-warning" style={{ margin: '.3rem 0 0', fontSize: 'var(--text-sm)', color: 'var(--color-warning-dark)' }}>
                    This tenant has more than 200 users. The list above shows only the first 200 — some users may not appear.
                  </p>
                )}
              </label>
              <Button
                variant="primary"
                size="md"
                loading={addMember.isPending}
                disabled={!selectedUserId}
                onClick={() => {
                  if (!selectedUserId) return
                  submitAddMember(groupId(activeGroup), selectedUserId)
                }}
              >
                Add member
              </Button>
            </div>

            <div>
              <h4 style={{ margin: '0 0 .75rem' }}>Current members</h4>
              {membersListTruncated && (
                <p role="note" data-testid="members-list-truncated-warning" style={{ margin: '0 0 .5rem', fontSize: 'var(--text-sm)', color: 'var(--color-warning-dark)' }}>
                  This group has more than 50 members. The list below shows only the first 50 — some members may not appear.
                </p>
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
                        <Button variant="danger" size="sm" onClick={() => submitRemoveMember(groupId(activeGroup), id)}>
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
        <div role="dialog" aria-modal="true" aria-label="Delete group" style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 40 }}>
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
    </div>
  )
}
