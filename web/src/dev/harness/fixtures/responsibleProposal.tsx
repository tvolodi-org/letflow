/** Harness fixtures of T-1528: the asset commission and stock receipt create forms with the signed-in user's linked
 *  employee proposed as the responsible. Invented data only. Own file (one registry line). */
import type { ReactElement } from 'react'
import { AccessStateProvider } from '@/auth/access/AccessContext'
import DocumentNewPage from '@/modules/assets/documents/DocumentNewPage'
import StockDocumentNewPage from '@/modules/stock/documents/DocumentNewPage'
import type { FixtureRoute, HarnessScreen } from '../types'
import { routes as assetRoutes, withAuth as assetsAuth } from './assetsDocuments'
import { routes as stockRoutes, withAuth as stockAuth } from './stockDocuments'

const USER = 'harness-user-1'
type Body = { items?: { record_id: string; field_values: Record<string, unknown> }[] }

/** Wraps the /entities/query route so employee e2 is linked to the signed-in user. */
const linked = (base: FixtureRoute[]): FixtureRoute[] =>
  base.map((r) =>
    r.match('/api/v1/entities/query', 'POST')
      ? {
          ...r,
          reply: (state, path, body) => {
            const res = r.reply(state, path, body)
            const b = res.body as Body
            if ((body as { entity_type?: string } | undefined)?.entity_type !== 'org_employee' || !b.items) return res
            return {
              ...res,
              body: { ...b, items: b.items.map((i) => (i.record_id === 'e2' || b.items?.length === 1 ? { ...i, field_values: { ...i.field_values, user_id: USER } } : i)) },
            }
          },
        }
      : r,
  )

const asUser = (permissions: string[], page: ReactElement): ReactElement => (
  <AccessStateProvider state={{ status: 'ready', info: { roles: [], platform_tenant: false, permissions, user_id: USER } }}>{page}</AccessStateProvider>
)

export const responsibleProposalScreens: HarnessScreen[] = [
  {
    name: 'asset-document-new-linked',
    routes: linked(assetRoutes),
    initialPath: '/new?kind=commission',
    routePattern: '/new',
    render: () => assetsAuth(asUser(['AssetsRead', 'AssetsPost'], <DocumentNewPage />)),
  },
  {
    name: 'stock-document-new-linked',
    routes: linked(stockRoutes),
    initialPath: '/?kind=receipt',
    render: () => stockAuth(asUser(['StockRead', 'StockPost'], <StockDocumentNewPage />)),
  },
]
