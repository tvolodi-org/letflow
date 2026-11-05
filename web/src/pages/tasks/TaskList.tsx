/** TaskList — T-1380. The rows of the task inbox: the action in words, the document (number and kind), org unit and
 *  location as "code - title", who issued it, the age and a one-line summary of the lines. Never an id. */
import type { Task } from '@/types/api'
import { StatusBadge } from '@/components/ui/StatusBadge'
import type { REFERENCE_MESSAGES } from '@/lib/references/referenceMessages'
import type { ReferenceType } from '@/lib/references/referenceLabel'
import { formatDateTime } from '@/i18n/format'
import { actionKind, ageText, fill } from './taskInboxModel'
import type { TaskContext } from './useTaskDocument'
import type { TaskMessages } from './taskMessages'

export interface TaskListProps {
  tasks: Task[]
  selectedId: string | null
  onSelect: (id: string) => void
  m: TaskMessages
  refMsg: (typeof REFERENCE_MESSAGES)['en']
  locale: string
  now: number
  userId: string | null
  subjectOf: (instanceId: string) => string
  contextOf: (instanceId: string) => TaskContext | null | undefined
  label: (type: ReferenceType, id: string | null | undefined) => string
  assigneeText: (t: Task) => string
}

/** "2 lines: first line" summary: item, quantity and unit of the first line, then how many more. */
function linesSummary(ctx: TaskContext | null | undefined, m: TaskMessages, label: TaskListProps['label']): string {
  const lines = ctx?.doc?.lines ?? []
  if (lines.length === 0) return ''
  const first = lines[0]
  const head = `${label('catalog_item', first.catalog_item_id)} × ${first.quantity} ${label('catalog_uom', first.catalog_uom_id)}`.trim()
  const count = lines.length === 1 ? m.linesOne : fill(m.linesMany, lines.length)
  return lines.length > 1 ? `${count}: ${head}, ${fill(m.moreLines, lines.length - 1)}` : `${count}: ${head}`
}

export function TaskList(p: TaskListProps) {
  const { m } = p
  return (
    <div className="lf-table-wrap">
      <table className="lf-table lf-table--compact" data-testid="task-inbox-list">
        <thead>
          <tr>
            <th scope="col">{m.colTask}</th>
            <th scope="col">{m.colDocument}</th>
          </tr>
        </thead>
        <tbody>
          {p.tasks.map((task) => {
            const kind = actionKind(task)
            const ctx = p.contextOf(task.instance_id)
            const doc = ctx?.doc ?? null
            const where = [p.label('org_unit', doc?.orgUnitId), p.label('location_node', doc?.locationId ?? doc?.fromLocationId ?? doc?.locationIds[0])]
              .filter((x) => x !== '')
              .join(' · ')
            const issuer = ctx?.issuerId ? (ctx.issuerId === p.userId ? p.refMsg.you : p.refMsg.anotherUser) : ''
            const selected = p.selectedId === task.id
            const summary = linesSummary(ctx, m, p.label)
            return (
              <tr
                key={task.id}
                data-testid="task-row"
                data-task-id={task.id}
                className={selected ? 'is-selected' : undefined}
                aria-current={selected ? 'true' : undefined}
                tabIndex={0}
                onClick={() => p.onSelect(task.id)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault()
                    p.onSelect(task.id)
                  }
                }}
              >
                <td>
                  <div data-testid="task-name">{kind === 'other' ? task.node_name : m.actions[kind]}</div>
                  <div data-testid="task-status">
                    <StatusBadge status={task.status} domain="task" />
                  </div>
                </td>
                <td>
                  <code className="mono" data-testid="task-instance-id" data-instance-id={task.instance_id}>
                    {p.subjectOf(task.instance_id)}
                  </code>
                  {where !== '' && <div className="lf-muted">{where}</div>}
                  {summary !== '' && <div className="lf-muted" data-testid="task-lines-summary">{summary}</div>}
                  {task.assignee_ref && (
                    <div className="lf-muted">
                      {p.refMsg.assignedTo}: <span data-testid="task-assignee">{p.assigneeText(task)}</span>
                    </div>
                  )}
                  {issuer !== '' && <div className="lf-muted" data-testid="task-issuer">{m.issuedBy}: {issuer}</div>}
                  <div className="lf-muted" data-testid="task-age" title={formatDateTime(task.created_at)}>
                    {ageText(task.created_at, p.now, p.locale)}
                  </div>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
