/** REQ-906: real task completion refused with the two posting refusals (plain entity write refusals, 409 with an `error` field). */
import { ToastContainer } from '@/components/ui/Toast'
import { taskInboxAssetsScreens } from './taskInboxAssets'
import { CompleteOnce } from './taskUpgrade'
import type { HarnessScreen } from '../types'

const base = taskInboxAssetsScreens.find((s) => s.name === 'tasks-assets-approve')!
const ME = '11111111-2222-4333-8444-555555555555'

function refused(name: string, error: string): HarnessScreen {
  return {
    ...base,
    name,
    routes: [
      { match: (path, method) => path.endsWith('/complete') && method === 'POST', reply: () => ({ status: 409, body: { error } }) },
      ...base.routes.map((route) => ({
        ...route,
        reply: (...args: Parameters<typeof route.reply>) => {
          const response = route.reply(...args)
          if (!args[1].startsWith('/api/v1/tasks/')) return response
          const own = (task: object) => ({ ...task, assignee_type: 'USER', assignee_ref: ME })
          if (args[1].endsWith('/inbox')) {
            const body = response.body as { items: object[] }
            return { ...response, body: { ...body, items: body.items.map(own) } }
          }
          return { ...response, body: own(response.body as object) }
        },
      })),
    ],
    render: (ctx) => <>{base.render(ctx)}<CompleteOnce /><ToastContainer /></>,
  }
}

export const taskRefusalScreens: HarnessScreen[] = [
  refused('tasks-refused-changed', 'record_version_conflict'),
  refused('tasks-refused-retired', 'master_inactive'),
]
