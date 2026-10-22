import { useState } from 'react'
import { P, useAccess } from '@/auth/access'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { usersApi, rolesApi } from '@/api/identity'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { User } from '@/types/api'
import { useNavigate } from 'react-router-dom'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDate } from '@/i18n/format'

// NOTE: user active/inactive is rendered as a tokenized custom badge, not
// StatusBadge (REQ-272) -- StatusBadgeDomain has no "user" member (only
// definition|instance|task|timer|dlq), so it cannot type-check this status
// pair without extending the primitive itself, which is out of this
// mechanical migration's scope.

function roleList(user: User): string[] {
  return Array.isArray(user.roles) ? user.roles : []
}

function displayUsername(user: User): string {
  if (typeof user.username === 'string' && user.username.length > 0) return user.username
  if (typeof user.email === 'string' && user.email.length > 0) {
    return user.email.split('@')[0]
  }
  return 'unknown-user'
}

export default function UsersPage() {
  const canManage = useAccess().can(P.UsersGroupsRolesManage)
  const navigate = useNavigate()
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [creating, setCreating] = useState(false)
  const [searchDraft, setSearchDraft] = useState('')
  const [searchApplied, setSearchApplied] = useState('')
  const [form, setForm] = useState({ username: '', email: '', display_name: '', password: '' })
  const [createRoleIds, setCreateRoleIds] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)

  const usersQueryKey = tenantKeys.admin.users({ search: searchApplied || undefined })

  const { data, isLoading, isError, error: queryError, refetch } = useQuery({
    queryKey: usersQueryKey,
    queryFn: () => usersApi.list({ search: searchApplied || undefined }),
  })

  const { data: roles } = useQuery({
    queryKey: tenantKeys.admin.roles(),
    queryFn: () => rolesApi.list(),
  })

  const createUser = useMutation({
    mutationFn: () => usersApi.create({ ...form, role_ids: createRoleIds }),
    onSuccess: (createdUser) => {
      qc.invalidateQueries({ queryKey: tenantKeys.admin.users() })
      setCreating(false)
      setForm({ username: '', email: '', display_name: '', password: '' })
      setCreateRoleIds([])
      navigate(`/admin/users/${createdUser.id}`)
    },
    onError: (e) => {
      setError((e as Error).message)
    },
  })

  function toggleRole(roleId: string, selectedIds: string[], setter: (next: string[]) => void): void {
    setter(selectedIds.includes(roleId) ? selectedIds.filter((id) => id !== roleId) : [...selectedIds, roleId])
  }

  const columns: DataTableColumn<User>[] = [
    { id: 'username', header: 'Username', accessor: displayUsername },
    { id: 'display_name', header: 'Display name', accessor: (u) => u.display_name },
    { id: 'email', header: 'Email', accessor: (u) => u.email },
    {
      id: 'roles',
      header: 'Roles',
      accessor: (u) => (
        <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)' }}>{roleList(u).join(', ')}</span>
      ),
    },
    {
      id: 'status',
      header: 'Status',
      accessor: (u) => (
        <span style={{ color: u.status === 'active' ? 'var(--color-success-dark)' : 'var(--text-disabled)', fontWeight: 600, fontSize: 'var(--text-xs)' }}>
          {u.status === 'active' ? 'ACTIVE' : 'INACTIVE'}
        </span>
      ),
    },
    { id: 'created', header: 'Created', accessor: (u) => formatDate(u.inserted_at) },
  ]

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>Users</h2>
        {canManage && (
          <span style={{ marginLeft: 'auto' }} data-testid="admin-users-new">
            <Button variant="primary" size="sm" onClick={() => setCreating(true)}>
              + New User
            </Button>
          </span>
        )}
      </div>

      <div style={{ display: 'flex', gap: '.5rem', marginBottom: '1rem' }}>
        <input
          data-testid="admin-users-search"
          value={searchDraft}
          onChange={(e) => setSearchDraft(e.target.value)}
          placeholder="Search users"
          style={{ width: '20rem', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)', boxSizing: 'border-box' }}
        />
        <Button variant="primary" size="sm" onClick={() => setSearchApplied(searchDraft)}>
          Apply
        </Button>
      </div>

      {creating && (
        <div style={{ background: 'var(--surface-page)', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Create user</h3>
          {error && <p style={{ color: 'var(--color-error)', marginBottom: '.75rem', fontSize: 'var(--text-sm)' }}>{error}</p>}
          {([
            { key: 'username', label: 'Username', type: 'text' },
            { key: 'display_name', label: 'Display name', type: 'text' },
            { key: 'email', label: 'Email', type: 'email' },
            { key: 'password', label: 'Password', type: 'password' },
          ] as const).map((f) => (
            <div key={f.key} style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>{f.label}</label>
              <input
                type={f.type}
                aria-label={f.label}
                value={form[f.key]}
                onChange={(e) => setForm((p) => ({ ...p, [f.key]: e.target.value }))}
                style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)', boxSizing: 'border-box' }}
              />
            </div>
          ))}

          <div style={{ marginBottom: '.75rem' }}>
            <p style={{ margin: '0 0 .35rem', fontSize: '.875rem', fontWeight: 500 }}>Roles</p>
            {(roles?.items ?? []).map((role) => (
              <label key={role.id} style={{ display: 'flex', alignItems: 'center', gap: '.4rem', marginBottom: '.25rem' }}>
                <input
                  name="role_ids"
                  type="checkbox"
                  checked={createRoleIds.includes(role.id)}
                  onChange={() => toggleRole(role.id, createRoleIds, setCreateRoleIds)}
                />
                <span>{role.name}</span>
              </label>
            ))}
          </div>

          <div style={{ display: 'flex', gap: '.5rem' }}>
            <Button variant="primary" size="sm" loading={createUser.isPending} onClick={() => createUser.mutate()}>
              Create user
            </Button>
            <Button variant="secondary" size="sm" onClick={() => { setCreating(false); setError(null) }}>
              Cancel
            </Button>
          </div>
        </div>
      )}

      <QueryStateBoundary
        state={isLoading ? 'loading' : isError ? classifyError(queryError) : 'success' as RendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          isError && classifyError(queryError) === 'rate-limit'
            ? getRetryAfterSeconds(queryError)
            : undefined
        }
        columns={[{ widthPercent: 20 }, { widthPercent: 25 }, { widthPercent: 25 }, { widthPercent: 15 }, { widthPercent: 10 }, { widthPercent: 5 }]}
      >
      <div data-testid="admin-users-table">
        <DataTable
          columns={columns}
          data={data?.items ?? []}
          emptyMessage="No users found."
        />
      </div>
      </QueryStateBoundary>

    </div>
  )
}
