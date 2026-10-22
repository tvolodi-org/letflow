import React, { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useDefinitions, useDefinitionVersions, useActivateDefinition, useArchiveDefinition, useCreateDefinition, useDefinitionSearch } from '@/hooks/useDefinitions'
import { useTenantScopedQueryKeys } from '@/api/useTenantScopedQueryKeys'
import { definitionsApi } from '@/api/definitions'
import { useDebounce } from '@/hooks/useDebounce'
import { highlightText } from '@/utils/highlightText'
import { deferClickState } from '@/utils/deferClickState'
import { P, useAccess } from '@/auth/access'
import type { DefinitionStatus, ProcessDefinition, DefinitionGraph } from '@/types/api'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDate } from '@/i18n/format'
import { PageLayout } from '@/components/ui/PageLayout'
import { FilterBar } from '@/components/ui/FilterBar'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { StatusBadge } from '@/components/ui/StatusBadge'


export default function DefinitionListPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const tenantKeys = useTenantScopedQueryKeys()
  const [status, setStatus] = useState<DefinitionStatus | undefined>()
  const [search, setSearch] = useState('')
  const [showCreate, setShowCreate] = useState(false)
  const [createName, setCreateName] = useState('')
  const [createVersion, setCreateVersion] = useState('')
  const [createDesc, setCreateDesc] = useState('')
  const [createError, setCreateError] = useState<string | null>(null)
  const [createValidationErrors, setCreateValidationErrors] = useState<{ name?: string; version?: string }>({})
  const [expandedDefId, setExpandedDefId] = useState<string | null>(null)
  const [expandedDefName, setExpandedDefName] = useState<string | null>(null)
  const [pendingNavId, setPendingNavId] = useState<string | null>(null)
  const [importError, setImportError] = useState<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  // ISS-0729: tracks the most recently scheduled (not-yet-flushed) deferred
  // `setSearch` timer — see the search input's `onChange` below for why this
  // coalescing is necessary, not just `deferClickState` called directly.
  const pendingSearchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const access = useAccess()
  const hasDesignerRole = access.can(P.DefinitionsWrite)
  // REQ-371 §6: rollback has its own permission (DefinitionsRollback), narrower than
  // DefinitionsWrite. See lib/letflow/design/req371-rollback-withdrawal-screen.md §6.
  const canRollback = access.can(P.DefinitionsRollback)

  // Debounce search query (300ms)
  const debouncedSearch = useDebounce(search, 300)

  // ISS-0729: clear any pending deferred setSearch flush on unmount, so a
  // late-firing timer never calls setState on an unmounted component.
  useEffect(() => {
    return () => {
      if (pendingSearchTimerRef.current !== null) {
        clearTimeout(pendingSearchTimerRef.current)
      }
    }
  }, [])

  // Navigate to the newly-created definition after React commits all state.
  // Using useEffect ensures this runs outside the mutation's async handler,
  // avoiding React 18 batching interactions with simultaneous query invalidations.
  useEffect(() => {
    if (pendingNavId) {
      navigate(`/definitions/${pendingNavId}`)
    }
  }, [pendingNavId, navigate])
  const { data, isLoading, isError, error, refetch } = useDefinitions({ status })
  const searchQuery = useDefinitionSearch(debouncedSearch, { page_size: 20 })
  const versionsQuery = useDefinitionVersions(expandedDefName ?? '')
  const activate = useActivateDefinition()
  const archive = useArchiveDefinition()
  const createDef = useCreateDefinition()

  const isSearching = debouncedSearch.trim().length > 0
  const searchResults = searchQuery.data as { items?: { definition: ProcessDefinition; rank: number }[] } | undefined
  const items: ProcessDefinition[] = isSearching
    ? (searchResults?.items?.map((r) => r.definition) ?? [])
    : ((data as { items?: ProcessDefinition[] } | undefined)?.items ?? [])
  const isLoadingItems = isSearching ? searchQuery.isLoading : isLoading
  const rendererState: RendererState = isLoading ? 'loading' : isError ? classifyError(error) : 'success'

  const validateCreate = (): boolean => {
    const errors: { name?: string; version?: string } = {}
    if (!createName.trim()) errors.name = 'Name is required'
    if (!createVersion.trim()) errors.version = 'Version is required'
    setCreateValidationErrors(errors)
    return Object.keys(errors).length === 0
  }

  const handleCreate = async () => {
    if (!validateCreate()) return
    setCreateError(null)
    try {
      const result = await createDef.mutateAsync({
        name: createName.trim(),
        version: createVersion.trim(),
        description: createDesc.trim(),
        graph: {
          nodes: [
            { id: 'start', node_type: 'START' as string, label: null },
            { id: 'end', node_type: 'END' as string, label: null },
          ],
          edges: [
            { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
          ],
        } as unknown as DefinitionGraph,
      })
      setShowCreate(false)
      setCreateName('')
      setCreateVersion('')
      setCreateDesc('')
      setCreateValidationErrors({})
      setPendingNavId(result.id)
    } catch (err: unknown) {
      setCreateError(err instanceof Error ? err.message : 'Failed to create definition')
    }
  }

  const handleImport = async () => {
    fileInputRef.current?.click()
  }

  const handleFileSelected = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    setImportError(null)

    try {
      const text = await file.text()
      const parsed = JSON.parse(text)

      const result = await definitionsApi.importJson(parsed)
      setImportError(null)
      qc.invalidateQueries({ queryKey: tenantKeys.definitions.all() })
      navigate(`/definitions/${result.id}`)
    } catch (err: unknown) {
      const apiErr = err as { status?: number; message?: string }
      if (apiErr.status === 422) {
        setImportError(apiErr.message ?? 'Invalid file — expected a BPM export JSON file')
      } else if (apiErr.status === 409) {
        setImportError('A definition with this name and version already exists.')
      } else if (err instanceof SyntaxError) {
        setImportError('Invalid file — expected a BPM export JSON file')
      } else {
        setImportError(apiErr.message ?? 'Could not read file')
      }
    } finally {
      // Reset file input so the same file can be selected again
      if (fileInputRef.current) fileInputRef.current.value = ''
    }
  }

  const columns: DataTableColumn<ProcessDefinition>[] = [
    {
      id: 'name',
      header: 'Name',
      sortable: true,
      sortValue: (def) => def.name,
      accessor: (def) => (
        <div>
          <span
            data-testid={`def-name-${def.id}`}
            onClick={() => {
              // ISS-0737: deferred by one macrotask — see web/src/utils/deferClickState.ts.
              deferClickState(() => {
                if (expandedDefId === def.id) {
                  setExpandedDefId(null)
                  setExpandedDefName(null)
                } else {
                  setExpandedDefId(def.id)
                  setExpandedDefName(def.name)
                }
              })
            }}
            style={{ color: 'var(--interactive-primary)', textDecoration: 'none', cursor: 'pointer' }}
          >
            {isSearching ? highlightText(def.name, debouncedSearch) : def.name}
          </span>
          {isSearching && def.description && (
            <div style={{ fontSize: '.8rem', color: 'var(--text-secondary)', marginTop: '2px' }}>
              {highlightText(def.description ?? '', debouncedSearch)}
            </div>
          )}
        </div>
      ),
    },
    {
      id: 'version',
      header: 'Version',
      sortable: true,
      sortValue: (def) => def.version,
      accessor: (def) => def.version,
    },
    {
      id: 'status',
      header: 'Status',
      sortable: true,
      sortValue: (def) => def.status,
      accessor: (def) => <StatusBadge status={def.status} domain="definition" />,
    },
    {
      id: 'updated_at',
      header: 'Updated',
      sortable: true,
      sortValue: (def) => def.updated_at,
      accessor: (def) => formatDate(def.updated_at),
    },
    {
      id: 'actions',
      header: 'Actions',
      accessor: (def) => (
        <div style={{ display: 'flex', gap: '.5rem' }}>
          {hasDesignerRole && def.status === 'DRAFT' && (
            <Button variant="primary" size="sm" onClick={() => activate.mutate(def.id)} loading={activate.isPending}>
              Activate
            </Button>
          )}
          {hasDesignerRole && (def.status === 'ACTIVE' || def.status === 'DEPRECATED') && (
            <Button variant="secondary" size="sm" onClick={() => archive.mutate(def.id)} loading={archive.isPending}>
              Archive
            </Button>
          )}
          {def.status === 'ACTIVE' && canRollback && (
            <Button
              variant="danger"
              size="sm"
              data-testid={`btn-rollback-${def.id}`}
              onClick={() => navigate(`/definitions/${def.id}/rollback`)}
            >
              Rollback…
            </Button>
          )}
        </div>
      ),
    },
  ]

  return (
    <PageLayout
      title="Process Definitions"
      actions={
        <div style={{ display: 'flex', gap: '.5rem' }}>
          {hasDesignerRole && (
            <>
              <Button variant="secondary" size="sm" data-testid="btn-import-definition" onClick={handleImport}>
                Import
              </Button>
              <input
                ref={fileInputRef}
                type="file"
                accept=".json"
                style={{ display: 'none' }}
                onChange={handleFileSelected}
                data-testid="import-file-input"
              />
            </>
          )}
          {hasDesignerRole && (
            <Button variant="primary" size="sm" data-testid="btn-new-definition" onClick={() => setShowCreate(true)}>
              + New Definition
            </Button>
          )}
        </div>
      }
    >
      <FilterBar activeCount={status ? 1 : 0} onClear={() => setStatus(undefined)}>
        <input
          data-testid="definition-search"
          type="text"
          placeholder="Search definitions..."
          defaultValue=""
          onChange={(e) => {
            // ISS-0729 §3 Step 1 (H1, confirmed empirically — see this
            // requirement's design doc and the e2e regression test's own
            // comment): deferring `setSearch` by one macrotask (the same
            // `setTimeout(fn, 0)` mechanism as web/src/utils/deferClickState.ts)
            // so it never runs synchronously inside the native `input`
            // event's own trusted dispatch turn eliminated a CPU-pegged
            // main-thread freeze confirmed at 20/20 (100%) reproduction in
            // this investigation, down to 0/20.
            //
            // This input is deliberately UNCONTROLLED (no `value={search}`,
            // just `defaultValue`): an earlier version kept it controlled and
            // deferred `setSearch` per keystroke via `deferClickState`
            // directly, which empirically dropped characters under rapid real
            // typing (Playwright `pressSequentially`) — React re-syncing the
            // DOM to an earlier, shorter `search` value once a deferred flush
            // finally landed could stomp on characters the user had already
            // typed live in the DOM in the meantime. Coalescing the deferred
            // flushes (clearing any not-yet-fired timer before scheduling the
            // next) reduced but did not eliminate this, because a fast-typing
            // burst's individual keystrokes are usually further apart than a
            // single macrotask, so most flushes still fire mid-burst. Making
            // the input uncontrolled removes the hazard at its root: nothing
            // ever writes a stale value back into this DOM node, so the
            // browser's own native buffering is the sole source of truth for
            // what's displayed, and `search` (used only to derive
            // `debouncedSearch` for the query below, never fed back into this
            // input's own display) can be updated on whatever delayed
            // schedule is needed without any risk of corrupting live typing.
            // Nothing else in this component reads or resets `search` for
            // display purposes, so there is no functional loss in dropping
            // the controlled binding. React 18 does not pool SyntheticEvents,
            // so capturing `value` synchronously here is a clarity measure,
            // not a correctness requirement.
            const value = e.target.value
            if (pendingSearchTimerRef.current !== null) {
              clearTimeout(pendingSearchTimerRef.current)
            }
            pendingSearchTimerRef.current = setTimeout(() => {
              pendingSearchTimerRef.current = null
              setSearch(value)
            }, 0)
          }}
          style={{ padding: '.35rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)', fontSize: '.85rem', flex: 1, maxWidth: '280px' }}
        />
        {isSearching && searchQuery.isFetching && (
          <span style={{ fontSize: '.75rem', color: 'var(--text-secondary)' }}>Searching…</span>
        )}
        <div data-testid="status-filter" style={{ display: 'inline-flex', alignItems: 'center', gap: '.35rem' }}>
          <span style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>Status</span>
          <select
            data-testid="status-filter-select"
            value={status ?? ''}
            onChange={(e) => setStatus((e.target.value as DefinitionStatus) || undefined)}
            style={{ padding: '.35rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)', fontSize: '.85rem' }}
          >
            <option value="">All</option>
            <option value="DRAFT">Draft</option>
            <option value="ACTIVE">Active</option>
            <option value="DEPRECATED">Deprecated</option>
            <option value="ARCHIVED">Archived</option>
          </select>
        </div>
      </FilterBar>

      <QueryStateBoundary
        state={rendererState}
        onRetry={() => { void refetch() }}
        rateLimitRetryAfter={
          rendererState === 'rate-limit' ? getRetryAfterSeconds(error) : undefined
        }
        columns={[{ widthPercent: 35 }, { widthPercent: 15 }, { widthPercent: 15 }, { widthPercent: 20 }, { widthPercent: 15 }]}
      >
      {!isLoadingItems && items.length === 0 && (
        <p data-testid="empty-state" style={{ textAlign: 'center', color: 'var(--text-secondary)', padding: '2rem' }}>
          {isSearching ? `No results found for "${debouncedSearch}"` : 'No definitions found'}
        </p>
      )}

      {importError && (
        <div
          data-testid="import-error-dialog"
          style={{
            padding: '8px 16px',
            background: 'var(--color-error-light)',
            color: 'var(--color-error-dark)',
            fontSize: '.85rem',
            borderBottom: '1px solid var(--interactive-danger)',
            marginBottom: '.5rem',
          }}
        >
          {importError}
        </div>
      )}

      {items.length > 0 && (
        <DataTable<ProcessDefinition>
          columns={columns}
          data={items}
          emptyMessage="No definitions found"
        />
      )}

      {items.map((def: ProcessDefinition) =>
        expandedDefId === def.id ? (
          <div key={`${def.id}-versions`} data-testid="version-history-row" style={{ background: 'var(--surface-page)', padding: '1rem 1.5rem', borderBottom: '1px solid var(--border-default)' }}>
            <strong style={{ fontSize: '.85rem', color: 'var(--text-primary)' }}>
              Version history: {def.name}
            </strong>
            {versionsQuery.isLoading && (
              <p style={{ fontSize: '.8rem', color: 'var(--text-secondary)', margin: '.5rem 0 0' }}>Loading versions...</p>
            )}
            {versionsQuery.data && (
              <div style={{ marginTop: '.5rem' }}>
                {(versionsQuery.data as { items?: ProcessDefinition[] }).items?.map((v) => (
                  <div key={v.id} style={{ display: 'flex', gap: '1rem', alignItems: 'center', padding: '.3rem 0', fontSize: '.85rem', color: 'var(--text-secondary)', borderBottom: '1px solid var(--border-default)' }}>
                    <span style={{ fontWeight: 600 }}>{v.version}</span>
                    <StatusBadge status={v.status} domain="definition" size="sm" />
                    <span style={{ color: 'var(--text-secondary)' }}>{formatDate(v.updated_at)}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : null
      )}
      </QueryStateBoundary>

      {/* Create Definition Dialog */}
      {showCreate && (
        <div
          data-testid="create-definition-dialog"
          style={{
            position: 'fixed', top: 0, left: 0, right: 0, bottom: 0,
            background: 'var(--surface-overlay)', display: 'flex',
            alignItems: 'center', justifyContent: 'center', zIndex: 1000,
          }}
          onClick={() => setShowCreate(false)}
        >
          <div
            style={{
              background: 'var(--surface-card)', borderRadius: '8px', padding: '1.5rem',
              width: '420px', maxWidth: '90vw', boxShadow: 'var(--shadow-modal-compact)',
            }}
            onClick={(e) => e.stopPropagation()}
          >
            <h3 style={{ margin: '0 0 1rem' }}>Create New Definition</h3>

            {createError && (
              <p style={{ color: 'var(--color-error-dark)', fontSize: '.85rem', marginBottom: '.75rem' }}>{createError}</p>
            )}

            <div style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', fontSize: '.85rem', fontWeight: 600, marginBottom: '.25rem', color: 'var(--text-primary)' }}>
                Name <span style={{ color: 'var(--color-error-dark)' }}>*</span>
              </label>
              <input
                data-testid="create-name-input"
                type="text"
                value={createName}
                onChange={(e) => { setCreateName(e.target.value); setCreateValidationErrors((prev) => ({ ...prev, name: undefined })) }}
                style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)', fontSize: '.85rem', boxSizing: 'border-box' }}
                placeholder="My Process"
              />
              {createValidationErrors.name && (
                <p style={{ color: 'var(--color-error-dark)', fontSize: '.8rem', margin: '.25rem 0 0' }}>{createValidationErrors.name}</p>
              )}
            </div>

            <div style={{ marginBottom: '.75rem' }}>
              <label style={{ display: 'block', fontSize: '.85rem', fontWeight: 600, marginBottom: '.25rem', color: 'var(--text-primary)' }}>
                Version <span style={{ color: 'var(--color-error-dark)' }}>*</span>
              </label>
              <input
                data-testid="create-version-input"
                type="text"
                value={createVersion}
                onChange={(e) => { setCreateVersion(e.target.value); setCreateValidationErrors((prev) => ({ ...prev, version: undefined })) }}
                style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)', fontSize: '.85rem', boxSizing: 'border-box' }}
                placeholder="1.0.0"
              />
              {createValidationErrors.version && (
                <p style={{ color: 'var(--color-error-dark)', fontSize: '.8rem', margin: '.25rem 0 0' }}>{createValidationErrors.version}</p>
              )}
            </div>

            <div style={{ marginBottom: '1rem' }}>
              <label style={{ display: 'block', fontSize: '.85rem', fontWeight: 600, marginBottom: '.25rem', color: 'var(--text-primary)' }}>
                Description
              </label>
              <textarea
                data-testid="create-description-input"
                value={createDesc}
                onChange={(e) => setCreateDesc(e.target.value)}
                style={{ width: '100%', padding: '.4rem .6rem', borderRadius: '4px', border: '1px solid var(--border-default)', fontSize: '.85rem', boxSizing: 'border-box', minHeight: '60px' }}
                placeholder="Optional description"
              />
            </div>

            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '.5rem' }}>
              <Button variant="secondary" size="sm" data-testid="create-cancel" onClick={() => { setShowCreate(false); setCreateError(null); setCreateValidationErrors({}) }}>
                Cancel
              </Button>
              <Button variant="primary" size="sm" data-testid="create-submit" onClick={handleCreate} loading={createDef.isPending} disabled={createDef.isPending}>
                {createDef.isPending ? 'Creating...' : 'Create'}
              </Button>
            </div>
          </div>
        </div>
      )}
    </PageLayout>
  )
}
