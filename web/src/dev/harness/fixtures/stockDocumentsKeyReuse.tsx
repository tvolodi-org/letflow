/** REQ-848: harness fixture showing the key-reuse error (idempotency_key_reuse 409) on the issue dialog of a stock document. */
import { useEffect, type ReactElement } from 'react'
import DocumentPage from '@/modules/stock/documents/DocumentPage'
import { type FixtureRoute, type HarnessScreen } from '../types'
import { routes as baseRoutes, withAuth } from './stockDocuments'

const DOCS_API = '/api/v1/modules/stock/documents'
const DOC_ID = 'doc-draft'

/** Same routes as stockDocuments but intercepts issue with the idempotency_key_reuse 409. */
const keyReuseRoutes: FixtureRoute[] = [
  ...baseRoutes,
  {
    match: (path, method) => path === `${DOCS_API}/${DOC_ID}/issue` && method === 'POST',
    reply: () => ({
      status: 409,
      body: { reason: 'idempotency_key_reuse', title: 'Conflict', type: 'idempotency_key_reuse' },
    }),
  },
]

/** Programmatically clicks Issue → Confirm so the 409 error appears in the dialog for the screenshot. */
function OpenIssueDialog({ children }: { children: ReactElement }): ReactElement {
  useEffect(() => {
    const ISSUE_LABELS = ['Issue', 'Выпустить', 'Шығару']
    let stage = 0
    const started = Date.now()
    const id = window.setInterval(() => {
      if (Date.now() - started > 6000) return window.clearInterval(id)
      const buttons = Array.from(document.querySelectorAll('button'))
      if (stage === 0) {
        const btn = buttons.find((b) => ISSUE_LABELS.includes(b.textContent?.trim() ?? ''))
        if (btn) {
          btn.click()
          stage = 1
        }
      } else if (stage === 1) {
        const confirm = document.querySelector<HTMLButtonElement>('[data-testid="confirm-dialog-confirm"]')
        if (confirm) {
          confirm.click()
          stage = 2
          window.clearInterval(id)
        }
      }
    }, 50)
    return () => window.clearInterval(id)
  }, [])
  return children
}

export const stockDocumentsKeyReuseScreens: HarnessScreen[] = [
  {
    name: 'stock-document-key-reuse-error',
    routes: keyReuseRoutes,
    initialPath: `/${DOC_ID}`,
    routePattern: '/:id',
    render: (): ReactElement =>
      withAuth(
        <OpenIssueDialog>
          <DocumentPage />
        </OpenIssueDialog>,
      ),
  },
]
