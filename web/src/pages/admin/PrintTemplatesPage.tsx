/** PrintTemplatesPage — REQ-614 (decision 0068 D8 S4): authoring screen for print-template overrides.
 *
 *  List, open, save-as-new-draft, activate and retire over the five REQ-579
 *  routes. The list never shows a layout; the opened row's layout fills the editor.
 *  Server errors go through describePrintOverrideError (safe text only).
 */
import React, { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError } from '@/utils/classifyError'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import {
  PRINT_OVERRIDE_LOCALES,
  REASON_CODE_MESSAGE,
  describePrintOverrideError,
  documentPrintOverridesApi,
  isValidReasonCode,
  type PrintOverrideMeta,
  type PrintOverrideSaveBody,
} from '@/api/documentPrintOverrides'
import { PrintLayoutEditor } from '@/components/admin/PrintLayoutEditor'

const th: React.CSSProperties = { textAlign: 'left', padding: '.5rem .75rem', borderBottom: '2px solid var(--border-default)' }
const td: React.CSSProperties = { padding: '.5rem .75rem', borderBottom: '1px solid var(--border-default)' }

type Transition = 'activate' | 'retire'

export default function PrintTemplatesPage(): React.ReactElement {
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [typeKeyFilter, setTypeKeyFilter] = useState('')
  const [localeFilter, setLocaleFilter] = useState('')
  const [openId, setOpenId] = useState<string | null>(null)
  const [transition, setTransition] = useState<Transition | null>(null)
  const [reasonCode, setReasonCode] = useState('')
  const [reasonError, setReasonError] = useState(false)
  const [errorLines, setErrorLines] = useState<string[]>([])

  const filters = { type_key: typeKeyFilter.trim(), locale: localeFilter }
  const listQuery = useQuery({
    queryKey: tenantKeys.printOverrides.list(filters),
    queryFn: () => documentPrintOverridesApi.list(filters),
  })
  const detailQuery = useQuery({
    queryKey: tenantKeys.printOverrides.detail(openId ?? ''),
    queryFn: () => documentPrintOverridesApi.get(openId as string),
    enabled: openId !== null,
  })

  const refresh = () => qc.invalidateQueries({ queryKey: tenantKeys.printOverrides.all() })
  const onError = (err: unknown) => setErrorLines(describePrintOverrideError(err))

  const saveMutation = useMutation({
    mutationFn: (body: PrintOverrideSaveBody) => documentPrintOverridesApi.save(body),
    onSuccess: (saved) => {
      setErrorLines([])
      setOpenId(saved.id)
      void refresh()
    },
    onError,
  })
  const transitionMutation = useMutation({
    mutationFn: (v: { kind: Transition; id: string; reason: string }) =>
      v.kind === 'activate'
        ? documentPrintOverridesApi.activate(v.id, v.reason)
        : documentPrintOverridesApi.retire(v.id, v.reason),
    onSuccess: () => {
      setErrorLines([])
      setTransition(null)
      setReasonCode('')
      void refresh()
    },
    onError,
  })

  const open = (id: string) => {
    setOpenId(id)
    setTransition(null)
    setReasonCode('')
    setReasonError(false)
    setErrorLines([])
  }

  const submitTransition = () => {
    if (transition === null || openId === null) return
    if (!isValidReasonCode(reasonCode)) {
      setReasonError(true)
      return
    }
    setReasonError(false)
    transitionMutation.mutate({ kind: transition, id: openId, reason: reasonCode })
  }

  const rows: PrintOverrideMeta[] = listQuery.data?.overrides ?? []
  const state = listQuery.isLoading ? 'loading' : listQuery.isError ? classifyError(listQuery.error) : 'success'
  const detail = detailQuery.data

  return (
    <PageLayout title="Print templates">
      <div style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
        <div style={{ display: 'flex', gap: '1rem', alignItems: 'center' }}>
          <label>
            Type key{' '}
            <input data-testid="filter-type-key" value={typeKeyFilter} onChange={(e) => setTypeKeyFilter(e.target.value)} />
          </label>
          <label>
            Locale{' '}
            <select data-testid="filter-locale" value={localeFilter} onChange={(e) => setLocaleFilter(e.target.value)}>
              <option value="">All</option>
              {PRINT_OVERRIDE_LOCALES.map((l) => (
                <option key={l} value={l}>
                  {l}
                </option>
              ))}
            </select>
          </label>
        </div>

        <QueryStateBoundary state={state} onRetry={() => void listQuery.refetch()}>
          <table data-testid="overrides-table" style={{ width: '100%', borderCollapse: 'collapse', fontSize: '.85rem' }}>
            <thead>
              <tr>
                {['Type key', 'Locale', 'Version', 'Status', 'Layout hash', 'Created by', 'Activated by', 'Activated at', 'Retired at'].map(
                  (h) => (
                    <th key={h} style={th}>
                      {h}
                    </th>
                  ),
                )}
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr
                  key={r.id}
                  data-testid={`override-row-${r.id}`}
                  onClick={() => open(r.id)}
                  style={{ cursor: 'pointer' }}
                >
                  <td style={td}>{r.type_key}</td>
                  <td style={td}>{r.locale}</td>
                  <td style={td}>{r.version_no}</td>
                  <td style={td}>{r.status}</td>
                  <td style={{ ...td, fontFamily: 'var(--font-mono)' }}>{r.layout_hash ?? '—'}</td>
                  <td style={td}>{r.created_by ?? '—'}</td>
                  <td style={td}>{r.activated_by ?? '—'}</td>
                  <td style={td}>{r.activated_at ?? '—'}</td>
                  <td style={td}>{r.retired_at ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </QueryStateBoundary>

        {openId !== null && detail && (
          <div data-testid="override-detail" style={{ display: 'flex', flexDirection: 'column', gap: '.75rem' }}>
            <h2 style={{ margin: 0 }}>
              {detail.type_key} / {detail.locale} / v{detail.version_no} ({detail.status})
            </h2>
            <div style={{ display: 'flex', gap: '.5rem' }}>
              {detail.status === 'draft' && (
                <Button variant="primary" size="sm" data-testid="activate-btn" onClick={() => setTransition('activate')}>
                  Activate
                </Button>
              )}
              {detail.status === 'active' && (
                <Button variant="danger" size="sm" data-testid="retire-btn" onClick={() => setTransition('retire')}>
                  Retire
                </Button>
              )}
            </div>
            {transition !== null && (
              <div style={{ display: 'flex', gap: '.5rem', alignItems: 'center' }}>
                <label>
                  Reason code{' '}
                  <input data-testid="reason-code" value={reasonCode} onChange={(e) => setReasonCode(e.target.value)} />
                </label>
                <Button
                  variant="primary"
                  size="sm"
                  data-testid="reason-submit"
                  loading={transitionMutation.isPending}
                  onClick={submitTransition}
                >
                  Confirm {transition}
                </Button>
                <Button variant="ghost" size="sm" onClick={() => setTransition(null)}>
                  Cancel
                </Button>
              </div>
            )}
            {reasonError && (
              <div role="alert" data-testid="reason-error">
                {REASON_CODE_MESSAGE}
              </div>
            )}
          </div>
        )}

        <PrintLayoutEditor
          key={detail && openId !== null ? detail.id : 'new'}
          initial={
            detail && openId !== null
              ? { type_key: detail.type_key, locale: detail.locale, layoutText: JSON.stringify(detail.layout, null, 2) }
              : undefined
          }
          onSave={(body) => saveMutation.mutate(body)}
          saving={saveMutation.isPending}
          errorLines={errorLines}
        />
      </div>
    </PageLayout>
  )
}
