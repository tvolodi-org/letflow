import { useMemo, useState, type CSSProperties } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { tokensApi, usersApi } from '@/api/identity'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import type { ApiToken, ApiTokenStatus, IssuedToken, User } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { useToast } from '@/hooks/useToast'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDate as formatLocaleDate } from '@/i18n/format'

// NOTE: the pre-existing hand-rolled table rendered 5 <th> over 7 <td>
// per row (Name/Created/Expires/Status/Actions headers, but
// user/roles/expires/created/revoked/status/actions cells) -- a
// pre-existing header/cell mismatch bug, not introduced here. DataTable's
// column model is 1:1 (one header per accessor), so it cannot reproduce
// that mismatch; the column list below names all 7 cells with their
// correct headers as an unavoidable side effect of adopting the
// primitive, not a deliberate functional fix.

type TokenRow = ApiToken & {
  token_id?: string
  user_display_name?: string
  user_id?: string
  roles?: string[]
}

interface StatusPresentation {
  label: string
  color: string
}

// GH 2589: one label and one colour per effective status. Only `active` uses
// the success colour; a Record over ApiTokenStatus keeps this exhaustive.
const TOKEN_STATUS_PRESENTATION: Record<ApiTokenStatus, StatusPresentation> = {
  active: { label: 'Active', color: 'var(--color-success-dark)' },
  revoked: { label: 'Revoked', color: 'var(--text-disabled)' },
  expired: { label: 'Expired', color: 'var(--color-warning-text)' },
  owner_inactive: { label: 'Owner inactive', color: 'var(--color-error-dark)' },
}

const UNKNOWN_STATUS: StatusPresentation = { label: 'Unknown', color: 'var(--text-secondary)' }

/** The wire value is not trusted to be one of the four: anything else, or a
 *  missing status, is shown as a neutral "Unknown", never as active. */
function tokenStatusPresentation(status: string | undefined): StatusPresentation {
  if (status !== undefined && Object.hasOwn(TOKEN_STATUS_PRESENTATION, status)) {
    return TOKEN_STATUS_PRESENTATION[status as ApiTokenStatus]
  }
  return UNKNOWN_STATUS
}

function tokenId(token: TokenRow): string {
  return token.token_id ?? token.id ?? ''
}

/** Issuer display: the user's display name when the page's user list has
 *  them, else the raw id; a dash for legacy tokens with no issuer. */
function tokenIssuerLabel(token: TokenRow, usersById: Map<string, User>): string {
  const issuerId = token.issuer_user_id
  if (!issuerId) return '—'
  return usersById.get(issuerId)?.display_name ?? issuerId
}

function tokenUserLabel(token: TokenRow, usersById: Map<string, User>): string {
  const userId = token.user_id ?? ''
  if (token.user_display_name) return token.user_display_name
  const user = usersById.get(userId)
  if (user) return `${user.display_name} <${user.email}>`
  return userId || 'Unknown user'
}

function tokenRoleLabel(token: TokenRow): string {
  return (token.roles ?? []).join(', ')
}

function formatDate(value?: string | null): string {
  if (!value) return 'Never'
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? value : formatLocaleDate(parsed)
}

export default function TokensPage() {
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const toast = useToast()
  const [creating, setCreating] = useState(false)
  const [form, setForm] = useState({ user_id: '', roles: '', expires_at: '' })
  const [issuedToken, setIssuedToken] = useState<IssuedToken | null>(null)
  const [createError, setCreateError] = useState('')
  const [pendingRevoke, setPendingRevoke] = useState<TokenRow | null>(null)

  const { data: tokenList, isLoading, isError, error, refetch } = useQuery({
    queryKey: tenantKeys.admin.tokens(),
    queryFn: () => tokensApi.list(),
  })

  const { data: users } = useQuery({
    queryKey: tenantKeys.admin.users({ page_size: 200 }),
    queryFn: () => usersApi.list({ page_size: 200 }),
  })

  const tokenItems = useMemo(() => (tokenList?.items ?? []) as TokenRow[], [tokenList?.items])
  const usersById = useMemo(() => new Map((users?.items ?? []).map((user) => [user.id ?? user.user_id ?? '', user])), [users?.items])
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const createToken = useMutation({
    mutationFn: () => {
      const roles = form.roles.split(',').map((role) => role.trim()).filter(Boolean)
      if (!form.user_id) throw new Error('Select a target user')
      if (roles.length === 0) throw new Error('Enter at least one role')
      return tokensApi.create({
        user_id: form.user_id,
        roles,
        expires_at: form.expires_at || undefined,
      })
    },
    onSuccess: (res) => {
      qc.invalidateQueries({ queryKey: tenantKeys.admin.tokens() })
      setIssuedToken(res)
      setCreating(false)
      setCreateError('')
      setForm({ user_id: '', roles: '', expires_at: '' })
    },
    onError: (error) => setCreateError((error as Error).message),
  })

  const revokeToken = useMutation({
    mutationFn: (id: string) => tokensApi.revoke(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: tenantKeys.admin.tokens() }),
  })

  // DataTable has no per-row style hook, so the revoked-row strikethrough/
  // dimming that the old hand-rolled <tr style={...}> applied is
  // reconstructed per-cell here instead of at the row level.
  function revokedCellStyle(token: TokenRow): CSSProperties {
    const revoked = Boolean(token.revoked_at)
    return { textDecoration: revoked ? 'line-through' : 'none', opacity: revoked ? 0.75 : 1 }
  }

  const columns: DataTableColumn<TokenRow>[] = [
    { id: 'name', header: 'Name', accessor: (token) => <span style={revokedCellStyle(token)}>{tokenUserLabel(token, usersById)}</span> },
    {
      id: 'roles',
      header: 'Roles',
      accessor: (token) => <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', ...revokedCellStyle(token) }}>{tokenRoleLabel(token)}</span>,
    },
    {
      id: 'expires',
      header: 'Expires',
      accessor: (token) => <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', ...revokedCellStyle(token) }}>{formatDate(token.expires_at)}</span>,
    },
    {
      id: 'created',
      header: 'Created',
      accessor: (token) => <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', ...revokedCellStyle(token) }}>{formatDate(token.created_at)}</span>,
    },
    {
      id: 'issuer',
      header: 'Issued by',
      accessor: (token) => <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', ...revokedCellStyle(token) }}>{tokenIssuerLabel(token, usersById)}</span>,
    },
    {
      id: 'revoked',
      header: 'Revoked',
      accessor: (token) => <span style={{ fontSize: 'var(--text-xs)', color: 'var(--text-secondary)', ...revokedCellStyle(token) }}>{formatDate(token.revoked_at)}</span>,
    },
    {
      id: 'status',
      header: 'Status',
      accessor: (token) => {
        const { label, color } = tokenStatusPresentation(token.status)
        return (
          <span data-testid="token-status" style={{ color, fontWeight: 600, fontSize: 'var(--text-xs)' }}>
            {label}
          </span>
        )
      },
    },
    {
      id: 'actions',
      header: 'Actions',
      accessor: (token) => {
        const revoked = Boolean(token.revoked_at)
        return !revoked ? (
          <Button variant="danger" size="sm" onClick={() => setPendingRevoke(token)}>
            Revoke
          </Button>
        ) : null
      },
    },
  ]

  return (
    <div style={{ padding: '1.5rem' }}>
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: '1.25rem' }}>
        <h2 style={{ margin: 0 }}>API Tokens</h2>
        <span style={{ marginLeft: 'auto' }}>
          <Button variant="primary" size="sm" onClick={() => { setCreating(true); setIssuedToken(null); setCreateError('') }}>
            + Issue token
          </Button>
        </span>
      </div>

      {issuedToken && (
        <div role="dialog" aria-modal="true" aria-label="Issued token" style={{ background: 'var(--color-success-tint)', border: '1px solid var(--color-success-border)', borderRadius: 'var(--radius-sm)', padding: '1rem', marginBottom: '1.25rem' }}>
          <p style={{ fontWeight: 600, marginBottom: '.5rem', color: 'var(--color-success-dark)' }}>This value will not be shown again.</p>
          <code data-testid="issued-token-value" style={{ fontSize: '.85rem', wordBreak: 'break-all', display: 'block', marginBottom: '.75rem' }}>{issuedToken.token_value}</code>
          <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
            <Button
              variant="primary"
              size="sm"
              onClick={() => {
                void navigator.clipboard.writeText(issuedToken.token_value)
                toast.success('Copied')
              }}
            >
              Copy token
            </Button>
            <Button variant="secondary" size="sm" onClick={() => setIssuedToken(null)}>
              Close
            </Button>
          </div>
        </div>
      )}

      {creating && (
        <div style={{ background: 'var(--surface-page)', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', padding: '1.25rem', marginBottom: '1.25rem' }}>
          <h3 style={{ margin: '0 0 1rem' }}>Issue token</h3>
          {createError && <p role="alert" style={{ marginTop: 0, color: 'var(--color-error)', fontSize: '.875rem' }}>{createError}</p>}
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Target user</label>
            <select value={form.user_id} onChange={(e) => setForm((p) => ({ ...p, user_id: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)', boxSizing: 'border-box' }}>
              <option value="">Select a user</option>
              {(users?.items ?? []).map((user) => {
                const id = user.id ?? user.user_id ?? ''
                return <option key={id} value={id}>{user.display_name} ({user.email})</option>
              })}
            </select>
          </div>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Role set</label>
            <input value={form.roles} onChange={(e) => setForm((p) => ({ ...p, roles: e.target.value }))}
              placeholder="Comma-separated roles"
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)', boxSizing: 'border-box' }} />
          </div>
          <div style={{ marginBottom: '.75rem' }}>
            <label style={{ display: 'block', marginBottom: '.25rem', fontSize: '.875rem', fontWeight: 500 }}>Expiry date</label>
            <input type="datetime-local" value={form.expires_at} onChange={(e) => setForm((p) => ({ ...p, expires_at: e.target.value }))}
              style={{ width: '100%', padding: '.45rem .7rem', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-sm)', fontSize: 'var(--text-base)', boxSizing: 'border-box' }} />
          </div>
          <p style={{ marginTop: 0, color: 'var(--text-secondary)', fontSize: '.875rem' }}>The generated value is shown once and can be copied from the confirmation dialog.</p>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <Button variant="primary" size="sm" onClick={() => createToken.mutate()}>Issue token</Button>
            <Button variant="secondary" size="sm" onClick={() => { setCreating(false); setCreateError('') }}>Cancel</Button>
          </div>
        </div>
      )}

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(error) : undefined
        }
        columns={[{ widthPercent: 25 }, { widthPercent: 20 }, { widthPercent: 20 }, { widthPercent: 15 }, { widthPercent: 20 }]}
      >
      <DataTable
        columns={columns}
        data={tokenItems}
        emptyMessage="No API tokens found."
      />
      </QueryStateBoundary>

      {pendingRevoke && (
        <div role="dialog" aria-modal="true" aria-label="Revoke token" style={{ position: 'fixed', inset: 0, background: 'var(--surface-overlay-slate)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '1rem', zIndex: 40 }}>
          <div style={{ background: 'var(--surface-card)', width: 'min(520px, 100%)', borderRadius: '12px', padding: '1.25rem' }}>
            <h3 style={{ marginTop: 0 }}>Revoke token?</h3>
            <p style={{ color: 'var(--text-secondary)' }}>Revoking this API token immediately removes access for the associated user and roles.</p>
            <div style={{ display: 'flex', gap: '.5rem', justifyContent: 'flex-end' }}>
              <Button variant="secondary" size="md" onClick={() => setPendingRevoke(null)}>Cancel</Button>
              <Button
                variant="danger"
                size="md"
                onClick={() => {
                  revokeToken.mutate(tokenId(pendingRevoke))
                  setPendingRevoke(null)
                }}
              >
                Revoke token
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
