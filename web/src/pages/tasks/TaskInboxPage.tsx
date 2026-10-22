import { useState, useMemo } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTaskInbox, useCompleteTask, useTask, useClaimTask } from '@/hooks/useTasks'
import { useTaskCompletionAttachments } from '@/hooks/useAttachments'
import { P, useAccess } from '@/auth/access'
import { useAuth } from '@/auth/AuthContext'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { StatusBadge } from '@/components/ui/StatusBadge'
import {
  isSeparationOfDuties,
  SEPARATION_OF_DUTIES_MESSAGE,
  SEPARATION_OF_DUTIES_CLAIM_MESSAGE,
} from '@/api/client'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { formatDate, formatDateTime, formatTime } from '@/i18n/format'

// NOTE: the task list below keeps its hand-rolled card-row markup rather than
// DataTable (REQ-274) -- it was never a <table> to begin with (no header
// row/columns, no sorting), and each row's data-testid contract
// (`task-row`, `task-name`, `task-instance-id`, `task-status`,
// `task-assignee`) is asserted extensively by web/tests/e2e/f4-task-inbox.e2e.spec.ts
// and web/tests/e2e/a11y-gate.e2e.spec.ts. DataTable's column/accessor model
// has no way to attach those per-row testids, so swapping it in here would
// need a DataTable change out of this file's scope and would break those
// e2e suites. Colours are still fully tokenized and the status pill and all
// buttons now use the shared primitives.

type FilterType = 'me' | 'group' | 'all'
type SortOrder = 'created' | '-created'

// Decode JWT to extract user ID (sub claim)
function decodeJwtPayload(token: string): { sub?: string; preferred_username?: string; [key: string]: unknown } {
  try {
    const parts = token.split('.')
    if (parts.length !== 3) throw new Error('Invalid JWT token')
    const decoded = JSON.parse(atob(parts[1]))
    return decoded
  } catch {
    return {}
  }
}

export default function TaskInboxPage() {
  const { session } = useAuth()
  const [searchParams, setSearchParams] = useSearchParams()
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null)

  // Parse URL search params
  const filter = (searchParams.get('filter') ?? 'me') as FilterType
  const sort = (searchParams.get('sort') ?? '-created') as SortOrder
  const search = searchParams.get('search') ?? ''

  const { data: inboxData, isLoading: inboxLoading, isError: inboxError, error: inboxErr, refetch: refetchInbox } = useTaskInbox()

  // Extract user ID from JWT token
  const userId = useMemo(() => {
    if (!session?.token) return null
    const payload = decodeJwtPayload(session.token)
    return payload.sub || null
  }, [session?.token])

  const isOperatorRole = useAccess().can(P.TasksAssign)

  // Filter and sort tasks
  const filteredTasks = useMemo(() => {
    if (!inboxData?.items) return []

    let results = inboxData.items

    // Filter by type.
    // Operators see all tasks from the inbox endpoint — no client-side assignee filter.
    // Non-operators apply the assignee_ref filter to show only their own tasks in "me" view.
    if (filter === 'me' && !isOperatorRole) {
      results = results.filter(t => t.assignee_ref === userId)
    } else if (filter === 'group' && !isOperatorRole) {
      // TODO: filter by user's groups once implemented
    }

    // Filter by search query
    if (search) {
      const q = search.toLowerCase()
      results = results.filter(t =>
        t.node_name.toLowerCase().includes(q)
      )
    }

    // Sort
    if (sort === '-created') {
      results = [...results].sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
    } else {
      results = [...results].sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime())
    }

    return results
  }, [inboxData?.items, filter, sort, search, userId, isOperatorRole])

  const handleFilterChange = (newFilter: FilterType) => {
    const params = new URLSearchParams(searchParams)
    params.set('filter', newFilter)
    setSearchParams(params)
  }

  const handleSortChange = (newSort: SortOrder) => {
    const params = new URLSearchParams(searchParams)
    params.set('sort', newSort)
    setSearchParams(params)
  }

  const handleSearchChange = (newSearch: string) => {
    const params = new URLSearchParams(searchParams)
    if (newSearch) {
      params.set('search', newSearch)
    } else {
      params.delete('search')
    }
    setSearchParams(params)
  }

  const isOperator = isOperatorRole

  return (
    <div style={{ display: 'flex', height: 'calc(100vh - 60px)' }}>
      {/* Left panel: task list */}
      <div style={{ flex: 1, borderRight: '1px solid var(--border-default)', overflowY: 'auto' }}>
        <div style={{ padding: '1.5rem' }}>
          {/* Filter bar */}
          <div style={{ marginBottom: '1.5rem', display: 'flex', gap: '1rem', alignItems: 'center', flexWrap: 'wrap' }}>
            <div style={{ display: 'flex', gap: '.5rem' }}>
              {(['me', 'group', isOperator && 'all'].filter(Boolean) as FilterType[]).map(f => (
                <Button
                  key={f}
                  variant={filter === f ? 'primary' : 'secondary'}
                  size="sm"
                  data-testid={f === 'all' ? 'task-filter-all-tasks' : `task-filter-${f}`}
                  onClick={() => handleFilterChange(f)}
                >
                  {f === 'me' ? 'My Tasks' : f === 'group' ? 'Group Tasks' : 'All Tasks'}
                </Button>
              ))}
            </div>

            <select
              data-testid="task-sort-control"
              value={sort}
              onChange={e => handleSortChange(e.target.value as SortOrder)}
              style={{
                padding: '.5rem .75rem',
                border: '1px solid var(--border-default)',
                borderRadius: 'var(--radius-sm)',
                cursor: 'pointer',
                fontSize: '.9rem',
                color: 'var(--text-primary)',
                background: 'var(--surface-card)',
              }}
            >
              <option value="-created">Newest first</option>
              <option value="created">Oldest first</option>
            </select>

            <input
              type="text"
              data-testid="task-search-input"
              placeholder="Search tasks…"
              value={search}
              onChange={e => handleSearchChange(e.target.value)}
              style={{
                padding: '.5rem .75rem',
                border: '1px solid var(--border-default)',
                borderRadius: 'var(--radius-sm)',
                fontSize: '.9rem',
                flex: 1,
                minWidth: '200px',
                color: 'var(--text-primary)',
                background: 'var(--surface-card)',
              }}
            />
          </div>

          {/* Task list */}
          <h2 style={{ marginBottom: '1.25rem' }}>
            {filter === 'me' ? 'My Tasks' : filter === 'group' ? 'Group Tasks' : 'All Tasks'}
          </h2>

          <QueryStateBoundary
            state={(inboxLoading ? 'loading' : inboxError ? classifyError(inboxErr) : 'success') as RendererState}
            onRetry={() => { void refetchInbox() }}
            rateLimitRetryAfter={
              inboxError && classifyError(inboxErr) === 'rate-limit' ? getRetryAfterSeconds(inboxErr) : undefined
            }
            columns={[{ widthPercent: 40 }, { widthPercent: 30 }, { widthPercent: 30 }]}
          >
          {!inboxLoading && filteredTasks.length === 0 && (
            <p style={{ color: 'var(--text-secondary)' }}>No tasks found.</p>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', gap: '.75rem' }} data-testid="task-inbox-list">
            {filteredTasks.map((task) => (
              <div
                key={task.id}
                data-testid="task-row"
                data-task-id={task.id}
                role="button"
                tabIndex={0}
                onClick={() => setSelectedTaskId(task.id)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault()
                    setSelectedTaskId(task.id)
                  }
                }}
                style={{
                  background: selectedTaskId === task.id ? 'var(--color-info-tint)' : 'var(--surface-card)',
                  border: selectedTaskId === task.id ? '2px solid var(--interactive-primary)' : '1px solid var(--border-default)',
                  borderRadius: '6px',
                  padding: '1rem 1.25rem',
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '1rem',
                }}
              >
                <div style={{ flex: 1 }}>
                  <div data-testid="task-name" style={{ fontWeight: 600, marginBottom: '.25rem' }}>{task.node_name}</div>
                  <div style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
                    Instance: <code data-testid="task-instance-id" style={{ fontSize: '.8rem' }}>{task.instance_id.slice(0, 8)}…</code>
                    {task.assignee_ref && <> · Assigned to: <span data-testid="task-assignee">{task.assignee_ref}</span></>}
                  </div>
                  <div style={{ fontSize: '.8rem', color: 'var(--text-disabled)', marginTop: '.25rem' }}>
                    {formatDate(task.created_at)} {formatTime(task.created_at)}
                  </div>
                </div>
                <div data-testid="task-status">
                  <StatusBadge status={task.status} domain="task" />
                </div>
              </div>
            ))}
          </div>
          </QueryStateBoundary>
        </div>
      </div>

      {/* Right panel: task detail */}
      {selectedTaskId && (
        <TaskDetailPanel
          key={selectedTaskId}
          taskId={selectedTaskId}
          onClose={() => setSelectedTaskId(null)}
        />
      )}
    </div>
  )
}

function TaskDetailPanel({ taskId, onClose }: { taskId: string; onClose: () => void }) {
  const { data: task, isLoading } = useTask(taskId)
  const { session } = useAuth()
  const complete = useCompleteTask()
  const claim = useClaimTask()
  const canCompleteTask = useAccess().can(P.TasksComplete)
  // REQ-392 AC5 -- the reviewed attachment(s) named on the completed task's
  // TASK_COMPLETED event snapshot. Only fetched once the task is COMPLETED.
  const completionAttachments = useTaskCompletionAttachments(
    task?.instance_id ?? '',
    taskId,
    task?.status === 'COMPLETED',
  )

  // Form field values keyed by schema field name. Fed from each rendered
  // form-field-<name> input's onChange and sent as output_variables on
  // Complete Task -- previously these inputs were uncontrolled and every
  // value typed into them was silently discarded, always submitting `{}`
  // regardless of what the form showed (found during the swiftroute
  // shipment-high-value-happy GUI review, 2026-09-20).
  const [formValues, setFormValues] = useState<Record<string, unknown>>({})

  const setFieldValue = (fieldName: string, value: unknown) => {
    setFormValues(prev => ({ ...prev, [fieldName]: value }))
  }

  // Extract user ID from JWT token
  const userId = useMemo(() => {
    if (!session?.token) return null
    const payload = decodeJwtPayload(session.token)
    return payload.sub || null
  }, [session?.token])

  if (isLoading) {
    return (
      <div data-testid="task-detail-panel" style={{ width: '40%', borderLeft: '1px solid var(--border-default)', padding: '1.5rem' }}>
        <p>Loading task details…</p>
      </div>
    )
  }

  if (!task) {
    return (
      <div data-testid="task-detail-panel" style={{ width: '40%', borderLeft: '1px solid var(--border-default)', padding: '1.5rem' }}>
        <p style={{ color: 'var(--color-error-dark)' }}>Task not found</p>
        <Button variant="secondary" size="sm" onClick={onClose}>Back</Button>
      </div>
    )
  }

  const isAssignedToMe = task.assignee_ref === userId
  const isClaimable = task.assignee_type && ['GROUP', 'ROLE'].includes(task.assignee_type) && !isAssignedToMe

  return (
    <div data-testid="task-detail-panel" style={{ width: '40%', borderLeft: '1px solid var(--border-default)', padding: '1.5rem', overflowY: 'auto' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1.5rem' }}>
        <h2 data-testid="task-detail-title" style={{ margin: 0 }}>{task.node_name}</h2>
        <Button variant="ghost" size="sm" onClick={onClose} title="Close">
          ×
        </Button>
      </div>

      {/* Status badge */}
      <div style={{ marginBottom: '1.5rem' }}>
        <StatusBadge status={task.status} domain="task" />
      </div>

      {/* REQ-392 AC5 -- reviewed attachment(s), completed tasks only. No
          empty-state text for a zero-length snapshot (fetched successfully,
          nothing was attached at decision time) -- this section simply does
          not appear, matching this page's existing conditional-render
          convention (e.g. correlation_key above). */}
      {task.status === 'COMPLETED' && completionAttachments.data && completionAttachments.data.length > 0 && (
        <div data-testid="task-decision-attachments" style={{ marginBottom: '1.5rem', fontSize: '.85rem', color: 'var(--text-secondary)' }}>
          {completionAttachments.data.length === 1 ? 'Reviewed document: ' : 'Reviewed documents: '}
          {completionAttachments.data.map((a) => a.file_name).join(', ')}
        </div>
      )}

      {/* Instance context */}
      <div
        style={{
          background: 'var(--surface-page)',
          border: '1px solid var(--border-default)',
          borderRadius: '6px',
          padding: '1rem',
          marginBottom: '1.5rem',
        }}
      >
        <h3 style={{ margin: '0 0 0.75rem 0', fontSize: '.95rem', fontWeight: 600 }}>Instance Context</h3>
        <div style={{ fontSize: '.85rem', color: 'var(--text-secondary)' }}>
          <p style={{ margin: '.25rem 0' }}>
            <strong>Definition:</strong> <span data-testid="instance-definition-name">{task.definition_name ?? 'N/A'}</span>
          </p>
          <p style={{ margin: '.25rem 0' }}>
            <strong>Instance ID:</strong> <span data-testid="instance-id">{task.instance_id}</span>
          </p>
          {task.correlation_key && (
            <p style={{ margin: '.25rem 0' }}>
              <strong>Correlation Key:</strong> <span data-testid="instance-correlation-key">{task.correlation_key}</span>
            </p>
          )}
          <p style={{ margin: '.25rem 0' }}>
            <strong>Created:</strong> {formatDateTime(task.created_at)}
          </p>
        </div>
      </div>

      {/* Instance variables (TK-UI-02) */}
      <div data-testid="instance-variables" style={{ marginBottom: '1.5rem' }}>
        <h3 style={{ fontSize: '.95rem', fontWeight: 600, marginBottom: '.75rem' }}>Instance Variables</h3>
        <div style={{ background: 'var(--surface-page)', border: '1px solid var(--border-default)', borderRadius: '6px', padding: '1rem', fontSize: '.85rem', color: 'var(--text-secondary)' }}>
          {/* Variables will be populated from instance context - TK-UI-02 implementation pending */}
          <p style={{ margin: 0, color: 'var(--text-disabled)' }}>Variables display pending implementation</p>
        </div>
      </div>

      {/* Form if schema exists */}
      {task.form_schema && typeof task.form_schema === 'object' && (
        <div style={{ marginBottom: '1.5rem' }}>
          <h3 style={{ fontSize: '.95rem', fontWeight: 600, marginBottom: '.75rem' }}>Task Form</h3>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
            {Object.entries((task.form_schema as Record<string, unknown>).properties || {}).map(([fieldName, fieldDef]) => {
              const fieldDef_ = fieldDef as Record<string, unknown> | undefined
              const isRequired = Array.isArray((task.form_schema as Record<string, unknown>).required) &&
                ((task.form_schema as Record<string, unknown>).required as string[]).includes(fieldName)
              const fieldType = fieldDef_?.type as string || 'string'
              const fieldTitle = fieldDef_?.title as string || fieldName

              return (
                <div key={fieldName} style={{ display: 'flex', flexDirection: 'column', gap: '.5rem' }}>
                  <label style={{ fontSize: '.9rem', fontWeight: 500 }}>
                    {fieldTitle}
                    {isRequired && <span data-testid={`form-field-required-${fieldName}`} style={{ color: 'var(--color-error)', marginLeft: '.25rem' }}>*</span>}
                  </label>
                  <input
                    data-testid={`form-field-${fieldName}`}
                    type={fieldType === 'number' ? 'number' : fieldType === 'boolean' ? 'checkbox' : 'text'}
                    placeholder={fieldTitle}
                    checked={fieldType === 'boolean' ? Boolean(formValues[fieldName]) : undefined}
                    value={fieldType === 'boolean' ? undefined : (formValues[fieldName] as string | number | undefined) ?? ''}
                    onChange={(e) => {
                      if (fieldType === 'boolean') {
                        setFieldValue(fieldName, e.target.checked)
                      } else if (fieldType === 'number') {
                        setFieldValue(fieldName, e.target.value === '' ? undefined : Number(e.target.value))
                      } else {
                        setFieldValue(fieldName, e.target.value)
                      }
                    }}
                    style={{
                      padding: '.5rem .75rem',
                      border: '1px solid var(--border-default)',
                      borderRadius: 'var(--radius-sm)',
                      fontSize: '.9rem',
                      color: 'var(--text-primary)',
                      background: 'var(--surface-card)',
                    }}
                  />
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* GH 2355 -- separation-of-duties refusal (REQ-463) on complete/claim.
          Other errors render as before (not at all here). */}
      {(isSeparationOfDuties(complete.error) || isSeparationOfDuties(claim.error)) && (
        <p
          role="alert"
          data-testid="task-sod-error"
          style={{ color: 'var(--color-error-dark)', marginTop: '1rem', fontSize: '.9rem' }}
        >
          {isSeparationOfDuties(complete.error)
            ? SEPARATION_OF_DUTIES_MESSAGE
            : SEPARATION_OF_DUTIES_CLAIM_MESSAGE}
        </p>
      )}

      {/* Action buttons */}
      <div style={{ display: 'flex', gap: '.75rem', marginTop: '2rem' }}>
        {canCompleteTask && isClaimable && (
          <div style={{ flex: 1 }}>
            <Button
              variant="primary"
              size="md"
              data-testid="task-claim-button"
              onClick={() => claim.mutate(taskId)}
              loading={claim.isPending}
            >
              {claim.isPending ? 'Claiming…' : 'Claim Task'}
            </Button>
          </div>
        )}

        {canCompleteTask && isAssignedToMe && task.status === 'PENDING' && (
          <div style={{ flex: 1 }}>
            <Button
              variant="primary"
              size="md"
              data-testid="task-complete-button"
              onClick={() => complete.mutate({ id: taskId, body: { output_variables: formValues } })}
              loading={complete.isPending}
            >
              {complete.isPending ? 'Completing…' : 'Complete Task'}
            </Button>
          </div>
        )}
      </div>

      <div style={{ marginTop: '1rem' }}>
        <Button variant="secondary" size="sm" onClick={onClose}>
          Back to inbox
        </Button>
      </div>
    </div>
  )
}
