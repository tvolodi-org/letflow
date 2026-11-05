/** taskInboxModel — T-1380 / GATE B R3. Pure functions of the task inbox: which tasks a user sees under each filter,
 *  the action a task asks for, counts and the age text. The client does not know the user's roles or groups, so a task
 *  that is open to a role, a group or nobody counts as "available"; the server decides who may claim it. */
import type { Task } from '@/types/api'

export type FilterType = 'me' | 'group' | 'all'
export type TaskClass = 'mine' | 'available' | 'other'
export type ActionKind = 'post' | 'approve' | 'reverse' | 'other'

export function classify(task: Pick<Task, 'status' | 'assignee_ref' | 'assignee_type'>, userId: string | null): TaskClass {
  if (userId !== null && task.assignee_ref === userId) return 'mine'
  if (task.status !== 'PENDING') return 'other'
  const type = (task.assignee_type ?? '').toUpperCase()
  if (!task.assignee_ref || type === '' || type === 'ROLE' || type === 'GROUP') return 'available'
  return 'other'
}

/** What the filter shows. `all` is the caller's (it needs TasksAssign); the filter itself never narrows it. */
export function matchesFilter(task: Pick<Task, 'status' | 'assignee_ref' | 'assignee_type'>, filter: FilterType, userId: string | null): boolean {
  if (filter === 'all') return true
  const c = classify(task, userId)
  if (filter === 'group') return c === 'available'
  return c === 'mine' || c === 'available'
}

export function counts(tasks: Pick<Task, 'status' | 'assignee_ref' | 'assignee_type'>[], userId: string | null): Record<FilterType, number> {
  return {
    me: tasks.filter((t) => matchesFilter(t, 'me', userId)).length,
    group: tasks.filter((t) => matchesFilter(t, 'group', userId)).length,
    all: tasks.length,
  }
}

/** The action a task stands for, from its node (`post`, `approve`, `reverse` in the stock flows). */
export function actionKind(task: Pick<Task, 'node_id' | 'node_name'>): ActionKind {
  const text = `${task.node_name} ${task.node_id}`.toLowerCase()
  if (text.includes('approv')) return 'approve'
  if (text.includes('revers')) return 'reverse'
  if (/\bpost/.test(text)) return 'post'
  return 'other'
}

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ['day', 86_400_000],
  ['hour', 3_600_000],
  ['minute', 60_000],
]

/** "3 minutes ago" in the UI language; "now" under a minute. */
export function ageText(iso: string | undefined, now: number, locale: string): string {
  if (!iso) return ''
  const t = new Date(iso).getTime()
  if (Number.isNaN(t)) return ''
  const diff = Math.max(0, now - t)
  const fmt = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' })
  for (const [unit, ms] of UNITS) {
    if (diff >= ms) return fmt.format(-Math.floor(diff / ms), unit)
  }
  return fmt.format(0, 'minute')
}

export function fill(template: string, n: number): string {
  return template.replace('{n}', String(n))
}
