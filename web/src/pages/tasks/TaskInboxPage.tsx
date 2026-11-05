/** TaskInboxPage — T-1380 / GATE B R3. "My Tasks": the tasks a user has claimed or can claim, in a MasterDetail (list on
 *  the left, the task and its document on the right). The default view shows own tasks and the open ones (role, group or
 *  unassigned) — the server decides who may claim. Row data-testids are kept for the e2e suites (f4-task-inbox, a11y-gate). */
import { ChevronDown, Search } from 'lucide-react'
import { useCallback, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useTaskInbox } from '@/hooks/useTasks'
import { useTaskSubjects } from '@/hooks/useTaskSubjects'
import { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import { actorLabel } from '@/lib/references/actorLabel'
import { useReferenceLabels } from '@/lib/references/useReferenceLabels'
import { useUiLocale } from '@/i18n/uiLocaleStore'
import { P, useAccess } from '@/auth/access'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { Button } from '@/components/ui/Button'
import { Field } from '@/components/ui/Field'
import { EmptyState } from '@/components/ui/EmptyState'
import { MasterDetail } from '@/components/ui/MasterDetail'
import { PageHeader } from '@/components/ui/PageHeader'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { getRetryAfterSeconds } from '@/utils/getRetryAfterSeconds'
import { TaskDetail } from './TaskDetail'
import { TaskList } from './TaskList'
import { actionKind, counts, matchesFilter, type FilterType } from './taskInboxModel'
import { TASK_MESSAGES } from './taskMessages'
import { useTaskContexts } from './useTaskDocument'

type SortOrder = 'created' | '-created'

export default function TaskInboxPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(searchParams.get('task'))
  const locale = useUiLocale()
  const m = TASK_MESSAGES[locale]
  const refMsg = REFERENCE_MESSAGES[locale]
  const access = useAccess()
  const canAssign = access.can(P.TasksAssign)

  const requested = (searchParams.get('filter') ?? 'me') as FilterType
  const filter: FilterType = requested === 'all' && !canAssign ? 'me' : requested
  const sort = (searchParams.get('sort') ?? '-created') as SortOrder
  const search = searchParams.get('search') ?? ''

  const { data: inboxData, isLoading, isError, error, refetch } = useTaskInbox()
  const userId = access.userId
  const items = inboxData?.items

  const filterCounts = useMemo(() => counts(items ?? [], userId), [items, userId])
  const byFilter = useMemo(() => (items ?? []).filter((t) => matchesFilter(t, filter, userId)), [items, filter, userId])

  const subjectOf = useTaskSubjects(byFilter.map((t) => t.instance_id))
  const contextOf = useTaskContexts(byFilter.map((t) => t.instance_id))
  const labelPages = (() => {
    const org: string[] = []
    const loc: string[] = []
    const item: string[] = []
    const uom: string[] = []
    for (const t of byFilter) {
      const d = contextOf(t.instance_id)?.doc
      if (!d) continue
      if (d.orgUnitId) org.push(d.orgUnitId)
      for (const l of [d.locationId, d.fromLocationId, ...d.locationIds]) if (l) loc.push(l)
      const first = d.lines[0]
      if (first) {
        item.push(first.catalog_item_id)
        uom.push(first.catalog_uom_id)
      }
    }
    return [{ org_unit: org, location_node: loc, catalog_item: item, catalog_uom: uom }]
  })()
  const label = useReferenceLabels(labelPages)

  const tasks = useMemo(() => {
    let results = byFilter
    if (search) {
      const q = search.toLowerCase()
      results = results.filter((t) => {
        const kind = actionKind(t)
        const word = kind === 'other' ? '' : m.actions[kind]
        return `${t.node_name} ${word} ${subjectOf(t.instance_id)}`.toLowerCase().includes(q)
      })
    }
    const dir = sort === '-created' ? -1 : 1
    return [...results].sort((a, b) => dir * (new Date(a.created_at).getTime() - new Date(b.created_at).getTime()))
  }, [byFilter, search, sort, m, subjectOf])

  const setParam = (key: string, value: string) => {
    const params = new URLSearchParams(searchParams)
    if (value) params.set(key, value)
    else params.delete(key)
    setSearchParams(params)
  }
  const close = useCallback(() => setSelectedTaskId(null), [])
  const now = useMemo(() => Date.now(), [items]) // eslint-disable-line react-hooks/exhaustive-deps

  const filters: FilterType[] = canAssign ? ['me', 'group', 'all'] : ['me', 'group']
  const filterLabel = { me: m.filterMe, group: m.filterGroup, all: m.filterAll }

  const tools = (
    <>
      <div className="lf-btn-row" role="group" aria-label={m.title}>
        {filters.map((f) => (
          <Button
            key={f}
            variant={filter === f ? 'primary' : 'secondary'}
            size="sm"
            data-testid={f === 'all' ? 'task-filter-all-tasks' : `task-filter-${f}`}
            onClick={() => setParam('filter', f)}
          >
            {filterLabel[f]} <span className="lf-count" data-testid={`task-filter-count-${f}`}>{filterCounts[f]}</span>
          </Button>
        ))}
      </div>
      <div className="lf-btn-row">
        <Field label={m.searchPlaceholder} hideLabel leadingIcon={<Search className="lf-icon" aria-hidden="true" />}>
          <input
            type="search"
            data-testid="task-search-input"
            aria-label={m.searchPlaceholder}
            placeholder={m.searchPlaceholder}
            value={search}
            onChange={(e) => setParam('search', e.target.value)}
          />
        </Field>
        <Field label={m.newest} hideLabel trailing={<ChevronDown className="lf-icon lf-control__chev" aria-hidden="true" />}>
          <select data-testid="task-sort-control" aria-label={m.newest} value={sort} onChange={(e) => setParam('sort', e.target.value)}>
            <option value="-created">{m.newest}</option>
            <option value="created">{m.oldest}</option>
          </select>
        </Field>
      </div>
    </>
  )

  const state = (isLoading ? 'loading' : isError ? classifyError(error) : 'success') as RendererState
  const master = (
    <QueryStateBoundary
      state={state}
      onRetry={() => { void refetch() }}
      rateLimitRetryAfter={isError && classifyError(error) === 'rate-limit' ? getRetryAfterSeconds(error) : undefined}
      columns={[{ widthPercent: 40 }, { widthPercent: 30 }, { widthPercent: 30 }]}
    >
      {tasks.length === 0 ? (
        <EmptyState title={m.emptyTitle} text={m.emptyText} data-testid="task-inbox-empty" />
      ) : (
        <TaskList
          tasks={tasks}
          selectedId={selectedTaskId}
          onSelect={setSelectedTaskId}
          m={m}
          refMsg={refMsg}
          locale={locale}
          now={now}
          userId={userId}
          subjectOf={subjectOf}
          contextOf={contextOf}
          label={label}
          assigneeText={(t) => t.assignee_name || actorLabel(t.assignee_ref, userId, refMsg)}
        />
      )}
    </QueryStateBoundary>
  )

  return (
    <>
      <PageHeader eyebrow={m.eyebrow} title={m.title} lede={m.lede} />
      <MasterDetail
        tools={tools}
        master={master}
        detailOpen={selectedTaskId !== null}
        onBack={close}
        detail={
          selectedTaskId ? (
            <TaskDetail key={selectedTaskId} taskId={selectedTaskId} onClose={close} m={m} locale={locale} userId={userId} />
          ) : (
            <div className="lf-card__body">
              <EmptyState title={m.pickTask} data-testid="task-detail-empty" />
            </div>
          )
        }
      />
    </>
  )
}
