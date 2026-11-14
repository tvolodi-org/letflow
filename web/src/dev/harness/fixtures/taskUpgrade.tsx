/** T-1969: real task completion refused by a mocked module-version gate, including its alert and toast. */
import { useEffect } from 'react'
import { ToastContainer } from '@/components/ui/Toast'
import { taskInboxAssetsScreens } from './taskInboxAssets'
import type { HarnessScreen } from '../types'

export const TASK_UPGRADE_PROBLEM = {
  type: 'https://letflow.dev/problems/module-upgrade-required',
  title: 'Module Upgrade Required',
  status: 409,
  detail: 'the installed module differs from the current version; upgrade it instead',
  code: 'upgrade_required',
}

function CompleteOnce() {
  useEffect(() => {
    const complete = () => {
      const button = document.querySelector<HTMLButtonElement>('[data-testid="task-complete-button"]')
      if (!button || button.disabled) return
      observer.disconnect()
      button.click()
    }
    const observer = new MutationObserver(complete)
    observer.observe(document.body, { childList: true, subtree: true, attributes: true })
    complete()
    return () => observer.disconnect()
  }, [])
  return null
}

const base = taskInboxAssetsScreens[0]!
export const taskUpgradeScreens: HarnessScreen[] = [{
  ...base,
  name: 'tasks-upgrade-required',
  routes: [
    {
      match: (path, method) => path.endsWith('/complete') && method === 'POST',
      reply: () => ({ status: 409, body: TASK_UPGRADE_PROBLEM }),
    },
    ...base.routes.map((route) => ({
      ...route,
      reply: (...args: Parameters<typeof route.reply>) => {
        const response = route.reply(...args)
        if (!args[1].startsWith('/api/v1/tasks/')) return response
        const own = (task: object) => ({ ...task, assignee_type: 'USER', assignee_ref: '11111111-2222-4333-8444-555555555555' })
        if (args[1].endsWith('/inbox')) {
          const body = response.body as { items: object[] }
          return { ...response, body: { ...body, items: body.items.map(own) } }
        }
        return { ...response, body: own(response.body as object) }
      },
    })),
  ],
  render: (ctx) => <>{base.render(ctx)}<CompleteOnce /><ToastContainer /></>,
}]
