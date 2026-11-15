/** Harness fixture (T-2008): a draft handover whose Issue is refused with `not_linked` (the document's location is not
 *  linked to its org unit). The shot clicks Issue, then the confirm button, so the refusal shows in the dialog. */
import { useEffect, type ReactElement } from 'react'
import DocumentPage from '@/modules/assets/documents/DocumentPage'
import type { FixtureRoute, HarnessScreen } from '../types'
import { routes, withAuth } from './assetsDocuments'

const ISSUE_LABELS = ['Issue', 'Выпустить', 'Шығару']

const draft = {
  id: 'doc-draft-handover', kind: 'handover', state: 'draft', number: null,
  org_unit_id: 'u1', from_location_id: 'l1', from_material_responsible_id: 'e1', from_actual_user_id: null,
  to_org_unit_id: 'u2', to_location_id: null, to_material_responsible_id: 'e2', to_actual_user_id: 'e2',
  event_time: '2026-11-03T09:15:00Z', note: null,
  lines: [{ line_id: 'ln1', line_no: 1, asset_id: 'a1', quantity: '1.000000000' }],
}

const refusedRoutes: FixtureRoute[] = [
  {
    match: (path, method) => path.endsWith('/issue') && method === 'POST',
    reply: () => ({ status: 422, body: { title: 'Unprocessable', reason: 'not_linked', line_no: 1 } }),
  },
  {
    match: (path, method) => path.endsWith('/doc-draft-handover') && method === 'GET',
    reply: () => ({ status: 200, body: draft }),
  },
  ...routes,
]

/** Harness only: clicks Issue on the page, then the Issue button of the confirm dialog (a shot cannot click). */
function ClickIssueTwice({ children }: { children: ReactElement }): ReactElement {
  useEffect(() => {
    let step = 0
    const id = window.setInterval(() => {
      const scope = step === 0 ? document : document.querySelector('[role="dialog"]')
      if (!scope) return
      const btn = Array.from(scope.querySelectorAll('button')).find((b) => ISSUE_LABELS.includes(b.textContent?.trim() ?? ''))
      if (!btn) return
      btn.click()
      step += 1
      if (step === 2) window.clearInterval(id)
    }, 15)
    return () => window.clearInterval(id)
  }, [])
  return children
}

export const assetsIssueRefusedScreens: HarnessScreen[] = [
  {
    name: 'asset-document-issue-refused',
    routes: refusedRoutes,
    initialPath: '/doc-draft-handover',
    routePattern: '/:id',
    render: () => withAuth(<ClickIssueTwice><DocumentPage /></ClickIssueTwice>),
  },
]
